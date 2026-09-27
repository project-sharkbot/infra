-- migrate:up
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

-- migrate:down

DROP FUNCTION add_guild_to_community;
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
