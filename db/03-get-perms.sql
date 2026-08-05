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