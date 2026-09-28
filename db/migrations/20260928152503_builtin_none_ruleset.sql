-- migrate:up
CREATE FUNCTION none_ruleset_id() RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT '00000000-0000-0000-0000-000000000002'::uuid $$;

ALTER TABLE rulesets ALTER COLUMN belongs_to DROP NOT NULL,
    ADD CONSTRAINT chk_builtin_none_ruleset CHECK (belongs_to IS NOT NULL OR id = none_ruleset_id());

INSERT INTO rulesets (id, ruleset_name, belongs_to)
    VALUES (none_ruleset_id(), 'None', NULL);

INSERT INTO guild_active_ruleset (community_id, ruleset_id, platform, platform_guild_id)
SELECT cg.community_id, none_ruleset_id(), cg.platform, cg.platform_guild_id
FROM community_guilds cg
WHERE NOT EXISTS (SELECT 1 FROM guild_active_ruleset g
                  WHERE g.platform = cg.platform AND g.platform_guild_id =
                                                     cg.platform_guild_id);

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

    INSERT INTO guild_active_ruleset (community_id, ruleset_id, platform, platform_guild_id)
    VALUES (p_target_community_id, none_ruleset_id(), p_platform, p_guild_id);

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

    INSERT INTO guild_active_ruleset (community_id, ruleset_id, platform, platform_guild_id)
    VALUES (new_community_id, none_ruleset_id(), platform, guild_id);

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

CREATE FUNCTION lock_builtin_none_ruleset() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Cannot modify the built-in None ruleset';
END;
$$;

CREATE TRIGGER lock_builtin_none_ruleset_trigger
    BEFORE UPDATE OR DELETE ON rulesets
    FOR EACH ROW
    WHEN (OLD.id = none_ruleset_id())
    EXECUTE FUNCTION lock_builtin_none_ruleset();

CREATE TRIGGER lock_builtin_none_no_rules_added_trigger
    BEFORE INSERT OR UPDATE ON rules
    FOR EACH ROW
    WHEN (NEW.ruleset_id = none_ruleset_id())
    EXECUTE FUNCTION lock_builtin_none_ruleset();

-- migrate:down

DROP TRIGGER lock_builtin_none_ruleset_trigger ON rulesets;
DROP TRIGGER lock_builtin_none_no_rules_added_trigger ON rules;
DROP FUNCTION lock_builtin_none_ruleset;

INSERT INTO rulesets (ruleset_name, belongs_to)
    SELECT format('none ruleset %s %s', platform_guild_id, platform), community_id
    FROM guild_active_ruleset
    WHERE ruleset_id = none_ruleset_id();

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


UPDATE guild_active_ruleset
SET ruleset_id = (SELECT rulesets.id
                  FROM rulesets
                  WHERE ruleset_name = format('none ruleset %s %s', platform_guild_id, platform)
                    AND belongs_to = community_id)
WHERE ruleset_id = none_ruleset_id();

DELETE FROM rulesets WHERE id = none_ruleset_id();

ALTER TABLE rulesets DROP CONSTRAINT chk_builtin_none_ruleset,
    ALTER COLUMN belongs_to SET NOT NULL;

DROP FUNCTION none_ruleset_id;
