-- Add a guild to an existing community; 
-- optionally copy moderators from existing guilds in the community
CREATE OR REPLACE FUNCTION add_guild_to_comunity(
    IN guild_id VARCHAR(255),
    IN platform platform_type,
    IN target_comunity_id UUID,
    IN add_moderators BOOLEAN,
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
        RETURN QUERY SELECT 1, 'Guild already in a comunity';
        RETURN;
    END IF;

    INSERT INTO comunity_guilds (comunity_id, platform_guild_id, platform)
    VALUES (target_comunity_id, guild_id, platform);

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

    -- Add owner as default god-tier mod
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
        -- Copy moderators from other guilds in the same community (same platform)
        INSERT INTO moderator_user (platform, platform_guild_id, platform_user_id, mod_rules_id, granted_by_user_id)
        SELECT m.platform, guild_id, m.platform_user_id, m.mod_rules_id, m.granted_by_user_id
        FROM moderator_user m
        JOIN comunity_guilds cg ON m.platform = cg.platform AND m.platform_guild_id = cg.platform_guild_id
        WHERE cg.comunity_id = target_comunity_id
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
