-- 02-functions.sql
-- Plpgsql functions: community management, moderator permissions, strike counting, ruleset resolution
--
-- Functions come from db/old/*.sql and are written as CREATE OR REPLACE
-- so they can be maintained in-place. These implement business rules
-- used by services: create_community, add_guild_to_community,
-- get_effective_mod_permissions, get_current_strikes, get_active_ruleset_for_context.
-- Keep signatures and error-number return conventions intact to avoid
-- breaking callers in the services workspace.

CREATE OR REPLACE FUNCTION guild_exists (IN guild_id VARCHAR(255), IN platform platform_type) RETURNS BOOLEAN
LANGUAGE SQL 
AS $$
    SELECT EXISTS(
        SELECT 1
        FROM community_guilds
        WHERE platform_guild_id = $1 
            AND platform = $2
    );
$$;

CREATE OR REPLACE FUNCTION create_community (
    IN guild_id VARCHAR(255), 
    IN platform platform_type,
    IN p_user_id VARCHAR(255),
    IN community_str_name TEXT
) RETURNS TABLE(
    error_number INT,
    error_message TEXT,
    community_id UUID
)
LANGUAGE plpgsql
AS $$
DECLARE
    new_community_id UUID;
    new_mod_rules_id UUID;
    default_rules_name TEXT;
BEGIN
    IF guild_exists(guild_id, platform) THEN
        RETURN QUERY SELECT 1, 'Community with this platform already exists', NULL::UUID;
        RETURN;
    END IF;

    INSERT INTO community (community_name, created_by_user_id) 
    VALUES (community_str_name, p_user_id)
    RETURNING id INTO new_community_id;

    INSERT INTO community_guilds (community_id, platform_guild_id, platform)
    VALUES (new_community_id, guild_id, platform);

    default_rules_name := format('default_mod_rules_%s_%s', platform, guild_id);

    -- god-tier permissions (everything)
    INSERT INTO mod_rules (
        rules_name,
        platform,
        platform_guild_id,
        delete_user_messages,
        create_rulesets,
        edit_rulesets,
        delete_rulesets,
        create_roles,
        edit_roles,
        delete_roles,
        change_active_ruleset
    ) VALUES (
        default_rules_name,
        platform,
        guild_id,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true
    )
    RETURNING id INTO new_mod_rules_id;

    -- Adds owner as god-tier mod
    INSERT INTO moderator_user (
        platform,
        platform_guild_id,
        platform_user_id,
        mod_rules_id,
        granted_by_user_id
    ) VALUES (
        platform,
        guild_id,
        p_user_id,
        new_mod_rules_id,
        NULL
    );

    RETURN QUERY SELECT 0, 'ok', new_community_id;
    RETURN;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 1, SQLERRM, NULL::UUID;
    RETURN;
END;
$$;

CREATE OR REPLACE FUNCTION add_guild_to_community(
    IN guild_id VARCHAR(255),
    IN platform platform_type,
    IN target_community_id UUID,
    IN add_moderators BOOLEAN, -- optionally add all community mods
    IN owner_user_id VARCHAR(255)
) RETURNS TABLE (
    error_number INT,
    error_message TEXT
) 
LANGUAGE plpgsql
AS $$
DECLARE
    new_mod_rules_id UUID;
    default_rules_name TEXT;
BEGIN
    IF guild_exists(guild_id, platform) THEN 
        RETURN QUERY SELECT 1, 'Guild already in a community';
        RETURN;
    END IF;

    INSERT INTO community_guilds (community_id, platform_guild_id, platform)
    VALUES (target_community_id, guild_id, platform);

    default_rules_name := format('default_mod_rules_%s_%s', platform, guild_id);

    INSERT INTO mod_rules (
        rules_name,
        platform,
        platform_guild_id,
        delete_user_messages,
        create_rulesets,
        edit_rulesets,
        delete_rulesets,
        create_roles,
        edit_roles,
        delete_roles,
        change_active_ruleset
    ) VALUES (
        default_rules_name,
        platform,
        guild_id,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true
    )
    RETURNING id INTO new_mod_rules_id;

    INSERT INTO moderator_user (
        platform,
        platform_guild_id,
        platform_user_id,
        mod_rules_id,
        granted_by_user_id
    ) VALUES (
        platform,
        guild_id,
        owner_user_id,
        new_mod_rules_id,
        NULL
    );

    IF add_moderators THEN 
        INSERT INTO moderator_user (platform, platform_guild_id, platform_user_id, mod_rules_id, granted_by_user_id)
        SELECT m.platform, guild_id, m.platform_user_id, m.mod_rules_id, m.granted_by_user_id
        FROM moderator_user m
        JOIN community_guilds cg ON m.platform = cg.platform AND m.platform_guild_id = cg.platform_guild_id
        WHERE cg.community_id = target_community_id
          AND m.platform = platform
          AND m.platform_user_id != owner_user_id
        ON CONFLICT (platform, platform_guild_id, platform_user_id) DO NOTHING;
    END IF;

    RETURN QUERY SELECT 0, 'ok';
    RETURN;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 1, SQLERRM;
    RETURN;
END
$$;

-- Returns merged moderator permissions for a platform user given explicit role ids.
CREATE OR REPLACE FUNCTION get_effective_mod_permissions(
    IN p_platform platform_type,
    IN p_platform_guild_id VARCHAR(255),
    IN p_platform_user_id VARCHAR(255),
    IN p_role_ids TEXT[]  -- array of role ids as strings
) RETURNS TABLE(
    delete_user_messages BOOLEAN,
    create_rulesets BOOLEAN,
    edit_rulesets BOOLEAN,
    delete_rulesets BOOLEAN,
    create_roles BOOLEAN,
    edit_roles BOOLEAN,
    delete_roles BOOLEAN,
    change_active_ruleset BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        bool_or(mr.delete_user_messages) AS delete_user_messages,
        bool_or(mr.create_rulesets) AS create_rulesets,
        bool_or(mr.edit_rulesets) AS edit_rulesets,
        bool_or(mr.delete_rulesets) AS delete_rulesets,
        bool_or(mr.create_roles) AS create_roles,
        bool_or(mr.edit_roles) AS edit_roles,
        bool_or(mr.delete_roles) AS delete_roles,
        bool_or(mr.change_active_ruleset) AS change_active_ruleset
    FROM (
        -- Rules assigned directly to the user
        SELECT r.* FROM mod_rules r
        JOIN moderator_user mu ON mu.mod_rules_id = r.id
        WHERE mu.platform = p_platform
          AND mu.platform_guild_id = p_platform_guild_id
          AND mu.platform_user_id = p_platform_user_id

        UNION ALL

        -- Rules assigned to any role the user has
        SELECT r2.* FROM mod_rules r2
        JOIN moderator_platform_role mpr ON mpr.rules_id = r2.id
        WHERE mpr.platform = p_platform
          AND mpr.platform_guild_id = p_platform_guild_id
          AND (p_role_ids IS NOT NULL AND mpr.platform_role_id = ANY(p_role_ids))
    ) mr;
END;
$$;

-- Returns the number of currently active strikes for a user in a guild (excludes expired)
CREATE OR REPLACE FUNCTION get_current_strikes(
    IN p_user_id VARCHAR(255),
    IN p_server_fk VARCHAR(255),
    IN p_platform platform_type
) RETURNS INT
LANGUAGE SQL
AS $$
    SELECT COALESCE(SUM(COALESCE(br.strike_count, 1)), 0) AS strikes
    FROM moderation_logs ml
    LEFT JOIN breaking_reactions br ON ml.breaking_reaction_id = br.id
    WHERE ml.user_id = $1
      AND ml.server_fk = $2
      AND ml.platform = $3
      AND (ml.valid_until IS NULL OR ml.valid_until > NOW());
$$;

-- get_active_ruleset_for_context: resolve best matching override/ruleset for a message context
CREATE OR REPLACE FUNCTION get_active_ruleset_for_context(
    IN p_server_fk VARCHAR(255),
    IN p_channel_id VARCHAR(255),
    IN p_user_id VARCHAR(255),
    IN p_role_ids TEXT[],
    IN p_platform platform_type
) RETURNS TABLE(
    ruleset_id UUID,
    ruleset_name VARCHAR,
    is_server_wide BOOLEAN,
    override_priority INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        r.id,
        r.ruleset_name,
        (ro.channel_id IS NULL AND ro.role_id IS NULL AND ro.user_id IS NULL) as is_server_wide,
        COALESCE(ro.priority, 0) as override_priority
    FROM ruleset_overrides ro
    INNER JOIN rulesets r ON ro.ruleset_id = r.id
    WHERE 
        ro.server_fk = p_server_fk
        AND ro.override_enabled = true
        AND (
            (ro.user_id IS NOT NULL AND ro.user_id = p_user_id)
            OR (ro.user_id IS NULL AND ro.role_id IS NULL AND ro.channel_id IS NOT NULL AND ro.channel_id = p_channel_id)
            OR (ro.user_id IS NULL AND ro.role_id IS NOT NULL AND p_role_ids IS NOT NULL AND ro.role_id = ANY(p_role_ids))
            OR (ro.user_id IS NULL AND ro.role_id IS NULL AND ro.channel_id IS NULL)
        )
    ORDER BY 
        CASE 
            WHEN ro.user_id IS NOT NULL THEN 4
            WHEN ro.role_id IS NOT NULL THEN 3
            WHEN ro.channel_id IS NOT NULL THEN 2
            ELSE 1
        END DESC,
        COALESCE(ro.priority, 0) DESC
    LIMIT 1;
END;
$$;
