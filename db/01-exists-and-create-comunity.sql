-- Bool function to check if a guild is in the database under a comunity
CREATE OR REPLACE FUNCTION guild_exists (IN guild_id VARCHAR(255), IN platform platform_type) RETURNS BOOLEAN
LANGUAGE SQL 
AS $$
    SELECT EXISTS(
        SELECT 1
        FROM comunity_guilds
        WHERE platform_guild_id = $1 
            AND platform = $2
    );
$$;

-- creates a new community for a given guild and platform
-- also creates default admin/mod rules
-- and assigns them to user platform id given in parameters
CREATE OR REPLACE FUNCTION create_comunity (
    IN guild_id VARCHAR(255), 
    IN platform platform_type,
    IN p_user_id VARCHAR(255)
) RETURNS TABLE(
    error_number INT,
    error_message TEXT,
    comunity_id UUID
)
LANGUAGE plpgsql
AS $$
DECLARE
    new_comunity_id UUID;
    new_mod_rules_id UUID;
    default_rules_name TEXT;
BEGIN
    IF guild_exists(guild_id, platform) THEN
        RETURN QUERY SELECT 1, 'Comunity with this platform already exists', NULL::UUID;
        RETURN;
    END IF;

    INSERT INTO comunity DEFAULT VALUES
    RETURNING id INTO new_comunity_id;

    INSERT INTO comunity_guilds (comunity_id, platform_guild_id, platform)
    VALUES (new_comunity_id, guild_id, platform);

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

    -- Add owner (expected p_user_id) as default god-tier mod
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
        NULL -- Granted by system - no users
    );

    RETURN QUERY SELECT 0, 'ok', new_comunity_id;
    RETURN;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 1, SQLERRM, NULL::UUID;
    RETURN;
END;
$$;