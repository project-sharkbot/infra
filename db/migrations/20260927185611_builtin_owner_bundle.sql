-- migrate:up
CREATE FUNCTION owner_rules_id() RETURNS UUID LANGUAGE sql IMMUTABLE AS $$ SELECT '00000000-0000-0000-0000-000000000001'::uuid $$;
ALTER TABLE mod_rules
    ALTER COLUMN platform DROP NOT NULL,
    ALTER COLUMN platform_guild_id DROP NOT NULL,
    ADD CONSTRAINT chk_builtin CHECK(id = owner_rules_id() OR (platform IS NOT NULL AND platform_guild_id IS NOT NULL));

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM moderator_user mu JOIN mod_rules r ON r.id = mu.mod_rules_id
               WHERE r.rules_name = format('default_mod_rules_%s_%s', r.platform, r.platform_guild_id)
               GROUP BY r.id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'A default bundle has several holders; give the extra ones their own bundle first';
    END IF;
END $$;

INSERT INTO mod_rules (id, rules_name, platform, platform_guild_id, delete_user_messages, create_rulesets, edit_rulesets, delete_rulesets, create_roles, edit_roles, delete_roles, change_active_ruleset)
VALUES (owner_rules_id(), 'Owner', null, null,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true
);

CREATE UNIQUE INDEX moderator_user_one_owner_per_guild
    ON moderator_user (platform, platform_guild_id)
    WHERE mod_rules_id = owner_rules_id();

UPDATE moderator_user
    SET mod_rules_id = owner_rules_id()
    WHERE mod_rules_id IN (SELECT r.id FROM mod_rules r JOIN moderator_user mu ON mu.mod_rules_id = r.id WHERE rules_name = format('default_mod_rules_%s_%s', r.platform, r.platform_guild_id));

-- Delete default mod rules that no longer belong to anyone
DELETE FROM mod_rules WHERE rules_name = format('default_mod_rules_%s_%s', platform, platform_guild_id) AND id NOT IN (SELECT moderator_user.mod_rules_id FROM moderator_user);

CREATE FUNCTION lock_owner_bundle() RETURNS trigger
    LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'The built-in owner bundle cannot be changed or deleted';
END;
$$;

CREATE FUNCTION lock_owner_rows() RETURNS trigger
    LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('sharkbot.owner_change', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Ownership cannot be changed outside of ownership functions';
    end if;
    RETURN COALESCE(NEW, OLD);
end;
$$;

CREATE TRIGGER lock_owner_new
    BEFORE UPDATE OR INSERT ON moderator_user
    FOR EACH ROW
    WHEN (NEW.mod_rules_id = owner_rules_id())
          EXECUTE FUNCTION lock_owner_rows();

CREATE TRIGGER lock_owner_old
    BEFORE UPDATE OR DELETE ON moderator_user
    FOR EACH ROW
    WHEN (OLD.mod_rules_id = owner_rules_id())
          EXECUTE FUNCTION lock_owner_rows();

CREATE TRIGGER lock_owner_bundle
    BEFORE UPDATE OR DELETE ON mod_rules
    FOR EACH ROW
    WHEN (OLD.id = owner_rules_id())
        EXECUTE FUNCTION lock_owner_bundle();

-- Function change
DROP FUNCTION add_guild_to_community;
CREATE FUNCTION add_guild_to_community(p_guild_id character varying, p_platform public.platform_type, p_target_community_id uuid, p_foreign_guild_id character varying, p_owner_user_id character varying) RETURNS TABLE(error_number integer, error_message text)
    LANGUAGE plpgsql
    SET sharkbot.owner_change = 'on'
AS $$
BEGIN
    IF guild_exists(p_guild_id, p_platform) THEN
        RETURN QUERY SELECT 1, 'Guild already in a community';
        RETURN;
    END IF;

    INSERT INTO community_guilds (community_id, platform_guild_id, platform)
    VALUES (p_target_community_id, p_guild_id, p_platform);

    INSERT INTO moderator_user (
        platform,
        platform_guild_id,
        platform_user_id,
        mod_rules_id,
        granted_by_user_id
    ) VALUES (
                 p_platform,
                 p_guild_id,
                 p_owner_user_id,
                 owner_rules_id(),
                 NULL
             );

    IF p_foreign_guild_id IS NOT NULL AND p_foreign_guild_id <> '' AND p_foreign_guild_id <> p_guild_id THEN
        -- Add other mod rules with from guild suffix
        IF NOT EXISTS (
            SELECT 1
            FROM community_guilds
            WHERE platform = p_platform AND
                platform_guild_id = p_foreign_guild_id AND
                community_id = p_target_community_id
        ) THEN
            RAISE EXCEPTION 'Foreign guild % is not in this community', p_foreign_guild_id;
        END IF;

        -- Add rules from other guild
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
        ) SELECT
              format('%s_from_%s', r.rules_name, p_foreign_guild_id),
              p_platform,
              p_guild_id,
              r.delete_user_messages,
              r.create_rulesets,
              r.edit_rulesets,
              r.delete_rulesets,
              r.create_roles,
              r.edit_roles,
              r.delete_roles,
              r.change_active_ruleset
        FROM mod_rules r
        WHERE r.platform = p_platform AND
            r.platform_guild_id = p_foreign_guild_id;

        -- Copy users - replace with new mod rules ids
        INSERT INTO moderator_user (
            platform,
            platform_guild_id,
            platform_user_id,
            mod_rules_id,
            granted_by_user_id)
        SELECT
            p_platform,
            p_guild_id,
            m.platform_user_id,
            r.id,
            m.granted_by_user_id
        FROM moderator_user m
                 JOIN mod_rules o ON o.id = m.mod_rules_id
                 JOIN mod_rules r ON r.platform = p_platform AND
                                     r.platform_guild_id = p_guild_id AND
                                     r.rules_name = format('%s_from_%s', o.rules_name, p_foreign_guild_id)
        WHERE m.platform = p_platform AND
            m.platform_guild_id = p_foreign_guild_id AND
            m.platform_user_id <> p_owner_user_id
        ON CONFLICT (platform, platform_guild_id, platform_user_id) DO NOTHING;
    END IF;

    RETURN QUERY SELECT 0, 'ok';
    RETURN;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 1, SQLERRM;
    RETURN;
END
$$;

-- CREATE COMMUNITY FUNCTION CHANGE
DROP FUNCTION create_community;
CREATE FUNCTION public.create_community(guild_id character varying, platform public.platform_type, p_user_id character varying, community_str_name text) RETURNS TABLE(error_number integer, error_message text, community_id uuid)
    LANGUAGE plpgsql
    SET sharkbot.owner_change = 'on'
AS $$
DECLARE
    new_community_id UUID;
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
                 owner_rules_id(),
                 NULL
             );

    RETURN QUERY SELECT 0, 'ok', new_community_id;
    RETURN;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 1, SQLERRM, NULL::UUID;
    RETURN;
END;
$$;



-- migrate:down

DROP TRIGGER lock_owner_bundle ON mod_rules;
DROP FUNCTION lock_owner_bundle;

DROP TRIGGER lock_owner_new ON moderator_user;
DROP TRIGGER  lock_owner_old ON moderator_user;
DROP FUNCTION lock_owner_rows;

-- Recreate the default owner permissions
INSERT INTO mod_rules (rules_name, platform, platform_guild_id,
                       delete_user_messages, create_rulesets, edit_rulesets, delete_rulesets,
                       create_roles, edit_roles, delete_roles, change_active_ruleset,
                       created_at, updated_at)
SELECT format('default_mod_rules_%s_%s', mu.platform, mu.platform_guild_id),
       mu.platform, mu.platform_guild_id,
       true, true, true, true, true, true, true, true,
       mu.created_at, mu.created_at
FROM moderator_user mu
WHERE mu.mod_rules_id = owner_rules_id();

UPDATE moderator_user mu
SET mod_rules_id = r.id
FROM mod_rules r
WHERE mu.mod_rules_id = owner_rules_id()
  AND r.platform = mu.platform
  AND r.platform_guild_id = mu.platform_guild_id
  AND r.rules_name = format('default_mod_rules_%s_%s', mu.platform, mu.platform_guild_id);

DROP INDEX moderator_user_one_owner_per_guild;

ALTER TABLE mod_rules
    DROP CONSTRAINT chk_builtin;

-- Drop the mod rules
DELETE FROM mod_rules
    WHERE id = owner_rules_id();

ALTER TABLE mod_rules
    ALTER COLUMN platform SET NOT NULL,
    ALTER COLUMN platform_guild_id SET NOT NULL;



DROP FUNCTION add_guild_to_community;
CREATE FUNCTION add_guild_to_community(    
    IN p_guild_id VARCHAR(255),
    IN p_platform platform_type,
    IN p_target_community_id UUID,
    IN p_foreign_guild_id VARCHAR(255), -- optionally copy mods from a guild in the community
    IN p_owner_user_id VARCHAR(255)
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
    IF guild_exists(p_guild_id, p_platform) THEN 
        RETURN QUERY SELECT 1, 'Guild already in a community';
        RETURN;
    END IF;

    INSERT INTO community_guilds (community_id, platform_guild_id, platform)
    VALUES (p_target_community_id, p_guild_id, p_platform);

    default_rules_name := format('default_mod_rules_%s_%s', p_platform, p_guild_id);

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
        p_platform,
        p_guild_id,
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
        p_platform,
        p_guild_id,
        p_owner_user_id,
        new_mod_rules_id,
        NULL
    );

    IF p_foreign_guild_id IS NOT NULL AND p_foreign_guild_id <> '' AND p_foreign_guild_id <> p_guild_id THEN 
        -- Add other mod rules with from guild suffix
        IF NOT EXISTS (
            SELECT 1 
            FROM community_guilds 
            WHERE platform = p_platform AND  
                platform_guild_id = p_foreign_guild_id AND 
                community_id = p_target_community_id
        ) THEN 
            RAISE EXCEPTION 'Foreign guild % is not in this community', p_foreign_guild_id;
        END IF;
        
        -- Add rules from other guild
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
        ) SELECT 
            format('%s_from_%s', r.rules_name, p_foreign_guild_id), 
            p_platform, 
            p_guild_id, 
            r.delete_user_messages,
            r.create_rulesets,
            r.edit_rulesets,
            r.delete_rulesets,
            r.create_roles,
            r.edit_roles,
            r.delete_roles,
            r.change_active_ruleset
        FROM mod_rules r
        WHERE r.platform = p_platform AND
            r.platform_guild_id = p_foreign_guild_id AND 
            r.rules_name <> format('default_mod_rules_%s_%s', p_platform, p_foreign_guild_id);

        -- Copy users - replace with new mod rules ids
        INSERT INTO moderator_user (
            platform, 
            platform_guild_id, 
            platform_user_id, 
            mod_rules_id, 
            granted_by_user_id)
        SELECT 
            p_platform, 
            p_guild_id, 
            m.platform_user_id, 
            r.id,
            m.granted_by_user_id
        FROM moderator_user m 
            JOIN mod_rules o ON o.id = m.mod_rules_id 
            JOIN mod_rules r ON r.platform = p_platform AND 
                r.platform_guild_id = p_guild_id AND 
                r.rules_name = format('%s_from_%s', o.rules_name, p_foreign_guild_id) 
        WHERE m.platform = p_platform AND 
        m.platform_guild_id = p_foreign_guild_id AND 
        m.platform_user_id <> p_owner_user_id
        ON CONFLICT (platform, platform_guild_id, platform_user_id) DO NOTHING;
    END IF;

    RETURN QUERY SELECT 0, 'ok';
    RETURN;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 1, SQLERRM;
    RETURN;
END
$$;

DROP FUNCTION create_community;
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

DROP FUNCTION owner_rules_id;