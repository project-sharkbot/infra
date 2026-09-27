-- Baseline: schema as it stood before dbmate (former db/00-types.sql … db/03-indexes.sql, unchanged).

-- migrate:up

-- 00-types.sql
-- Ensure uuid extension present and create enum types conditionally
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- this file defines the key enum types used across the schema 
-- platform_type, transaction_type, rule_types,punishment_type, message_reaction
-- blocks are intentionally idempotent so re-running container init is safe.
-- also enums are useful since you can run alter to add values

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'platform_type') THEN
    CREATE TYPE platform_type AS ENUM ('discord', 'twitch');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'transaction_type') THEN
    CREATE TYPE transaction_type AS ENUM ('daily_reward', 'gamble_transaction', 'user_transfer', 'game_transaction', 'admin_adjust');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'rule_types') THEN
    CREATE TYPE rule_types AS ENUM ('caps', 'spoilers', 'emojis', 'spam_messages', 'repeated_text');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'punishment_type') THEN
    CREATE TYPE punishment_type AS ENUM ('timed_ban', 'perma_ban', 'kick', 'warn');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'message_reaction') THEN
    CREATE TYPE message_reaction AS ENUM ('delete', 'nothing');
  END IF;
END$$;


-- 01-tables.sql
-- create in dependency order

-- ============================================================================
-- 1. CORE: Communities and Guilds
-- ============================================================================

CREATE TABLE IF NOT EXISTS community (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    community_name VARCHAR(255),
    created_by_user_id VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS community_guilds (
    community_id UUID NOT NULL REFERENCES community (id) ON DELETE CASCADE,
    platform_guild_id VARCHAR(255) NOT NULL,
    platform platform_type NOT NULL,
    PRIMARY KEY (community_id, platform_guild_id, platform),
    UNIQUE (platform_guild_id, platform)
);

-- ============================================================================
-- 2. RULESETS & ACTIVE MAPPINGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS rulesets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ruleset_name VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    belongs_to UUID NOT NULL REFERENCES community (id) ON DELETE CASCADE,
    UNIQUE (belongs_to, ruleset_name)
);

CREATE TABLE IF NOT EXISTS guild_active_ruleset (
    community_id UUID NOT NULL REFERENCES community(id) ON DELETE CASCADE,
    ruleset_id UUID NOT NULL REFERENCES rulesets (id) ON DELETE SET NULL,
    platform platform_type NOT NULL,
    platform_guild_id VARCHAR(255) NOT NULL,
    PRIMARY KEY (platform, platform_guild_id),
    FOREIGN KEY (community_id, platform_guild_id, platform) REFERENCES community_guilds(community_id, platform_guild_id, platform) ON DELETE CASCADE
);

-- ============================================================================
-- 3. RULES and OVERRIDES
-- ============================================================================

CREATE TABLE IF NOT EXISTS rules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ruleset_id UUID NOT NULL REFERENCES rulesets(id) ON DELETE CASCADE,
    rule_type rule_types NOT NULL,
    is_enabled BOOLEAN DEFAULT TRUE,
    threshold_value INT NOT NULL,
    threshold_window_sec INT,
    UNIQUE(ruleset_id, rule_type)
);

CREATE TABLE IF NOT EXISTS ruleset_overrides (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ruleset_id UUID REFERENCES rulesets(id) ON DELETE CASCADE,
    server_fk VARCHAR(255) NOT NULL,
    channel_id VARCHAR(255),
    role_id VARCHAR(255),
    user_id VARCHAR(255),
    priority INT DEFAULT 0,
    override_threshold_value INT,
    override_window_sec INT,
    override_enabled BOOLEAN DEFAULT TRUE,
    CONSTRAINT check_scope_validity CHECK (channel_id IS NOT NULL OR role_id IS NOT NULL OR user_id IS NOT NULL),
    UNIQUE(server_fk, channel_id, role_id, user_id, ruleset_id)
);

-- ============================================================================
-- 4. MODERATION ACTIONS & LOGGING
-- ============================================================================

CREATE TABLE IF NOT EXISTS breaking_reactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ruleset_id UUID NOT NULL REFERENCES rulesets(id) ON DELETE CASCADE,
    rule_type rule_types NOT NULL,
    message_action message_reaction NOT NULL DEFAULT 'delete',
    offender_reaction punishment_type NOT NULL DEFAULT 'warn',
    duration_sec INT CHECK (duration_sec IS NULL OR duration_sec > 0),
    strike_count INT DEFAULT 1 CHECK (strike_count > 0),
    expiry_duration INT DEFAULT NULL CHECK (expiry_duration > 0),
    CONSTRAINT punishment_match_duration CHECK (
        (offender_reaction = 'timed_ban' AND duration_sec IS NOT NULL) OR
        (offender_reaction IN ('perma_ban', 'kick', 'warn') AND duration_sec IS NULL)
    ),
    UNIQUE(ruleset_id, rule_type)
);

CREATE TABLE IF NOT EXISTS moderation_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    platform platform_type NOT NULL,
    server_fk VARCHAR(255) NOT NULL,
    channel_id VARCHAR(255),
    user_id VARCHAR(255) NOT NULL,
    moderator_id VARCHAR(255),
    breaking_reaction_id UUID REFERENCES breaking_reactions(id) ON DELETE SET NULL,
    message_content_snapshot TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    valid_until TIMESTAMPTZ,
    CONSTRAINT offence_validity CHECK (valid_until IS NULL OR valid_until > created_at)
);

-- ============================================================================
-- 5. ECONOMY SYSTEM (Unified Multiplatform)
-- ============================================================================

CREATE TABLE IF NOT EXISTS economy_players (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    balance BIGINT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_daily_reward TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS economy_connections (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    player_id UUID NOT NULL REFERENCES economy_players(id) ON DELETE CASCADE,
    platform platform_type NOT NULL,
    platform_user_id VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(platform, platform_user_id),
    UNIQUE(player_id, platform)
);

CREATE TABLE IF NOT EXISTS economy_connection_codes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    requesting_player_id UUID REFERENCES economy_players(id) ON DELETE CASCADE,
    requesting_platform platform_type NOT NULL,
    target_platform platform_type NOT NULL,
    token VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '10 minutes'),
    CHECK (target_platform IS DISTINCT FROM requesting_platform)
);

CREATE TABLE IF NOT EXISTS economy_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    player_id UUID NOT NULL REFERENCES economy_players(id),
    amount BIGINT NOT NULL,
    transaction_type transaction_type NOT NULL,
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 7. Moderation roles
-- ============================================================================

CREATE TABLE IF NOT EXISTS mod_rules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    rules_name VARCHAR(255) NOT NULL,
    platform platform_type NOT NULL,
    platform_guild_id VARCHAR(255) NOT NULL,
    delete_user_messages BOOLEAN DEFAULT false,
    create_rulesets BOOLEAN DEFAULT false,
    edit_rulesets BOOLEAN DEFAULT false,
    delete_rulesets BOOLEAN DEFAULT false,
    create_roles BOOLEAN DEFAULT false,
    edit_roles BOOLEAN DEFAULT false,
    delete_roles BOOLEAN DEFAULT false,
    change_active_ruleset BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(platform, platform_guild_id, rules_name)
);

CREATE TABLE IF NOT EXISTS moderator_platform_role (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    platform platform_type NOT NULL,
    platform_guild_id VARCHAR(255) NOT NULL,
    platform_role_id VARCHAR(255) NOT NULL,
    rules_id UUID NOT NULL REFERENCES mod_rules(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (platform, platform_role_id, platform_guild_id)
);

CREATE TABLE IF NOT EXISTS moderator_user (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    platform platform_type NOT NULL,
    platform_guild_id VARCHAR(255) NOT NULL,
    platform_user_id VARCHAR(255) NOT NULL,
    mod_rules_id UUID NOT NULL REFERENCES mod_rules (id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    granted_by_user_id VARCHAR(255),
    UNIQUE(platform, platform_guild_id, platform_user_id)
);

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


-- 03-indexes.sql
-- Additional indexes and safety guards
--
-- See 01-tables.sql for the tables these indexes reference. Adding new
-- indexes should follow a performance review and be included in a new
-- numeric-prefixed migration file.

CREATE INDEX IF NOT EXISTS idx_ruleset_overrides_server_priority ON ruleset_overrides(server_fk, priority);

CREATE INDEX IF NOT EXISTS idx_breaking_reactions_ruleset ON breaking_reactions(ruleset_id);

CREATE INDEX IF NOT EXISTS idx_logs_user ON moderation_logs(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_logs_guild ON moderation_logs(server_fk, created_at);
CREATE INDEX IF NOT EXISTS idx_logs_breaking_reaction ON moderation_logs(breaking_reaction_id);

CREATE INDEX IF NOT EXISTS idx_connection_codes_player ON economy_connection_codes(requesting_player_id);

CREATE INDEX IF NOT EXISTS idx_connections_platform ON economy_connections(platform, platform_user_id);

CREATE INDEX IF NOT EXISTS idx_moderator_platform_role_id ON moderator_platform_role(platform_role_id, platform_guild_id, platform);

CREATE INDEX IF NOT EXISTS idx_moderator_user_platform_user_id ON moderator_user(platform_user_id);


-- migrate:down

DROP FUNCTION get_active_ruleset_for_context(VARCHAR, VARCHAR, VARCHAR, TEXT[], platform_type);
DROP FUNCTION get_current_strikes(VARCHAR, VARCHAR, platform_type);
DROP FUNCTION get_effective_mod_permissions(platform_type, VARCHAR, VARCHAR, TEXT[]);
DROP FUNCTION add_guild_to_community(VARCHAR, platform_type, UUID, BOOLEAN, VARCHAR);
DROP FUNCTION create_community(VARCHAR, platform_type, VARCHAR, TEXT);
DROP FUNCTION guild_exists(VARCHAR, platform_type);

DROP TABLE moderator_user;
DROP TABLE moderator_platform_role;
DROP TABLE mod_rules;
DROP TABLE economy_transactions;
DROP TABLE economy_connection_codes;
DROP TABLE economy_connections;
DROP TABLE economy_players;
DROP TABLE moderation_logs;
DROP TABLE breaking_reactions;
DROP TABLE ruleset_overrides;
DROP TABLE rules;
DROP TABLE guild_active_ruleset;
DROP TABLE rulesets;
DROP TABLE community_guilds;
DROP TABLE community;

DROP TYPE message_reaction;
DROP TYPE punishment_type;
DROP TYPE rule_types;
DROP TYPE transaction_type;
DROP TYPE platform_type;

DROP EXTENSION "uuid-ossp";
