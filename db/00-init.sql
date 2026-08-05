-- Enable UUID extension for robust primary keys
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- 0. Custom types
-- ============================================================================

-- Enum type for the platforms that we support 
CREATE TYPE IF NOT EXISTS platform_type AS ENUM (
    'discord', 'twitch'
);

CREATE TYPE IF NOT EXISTS transaction_type AS ENUM (
        'daily_reward', 'gamble_transaction',  
        'user_transfer', 'game_transaction', 'admin_adjust'
);

CREATE TYPE IF NOT EXISTS rule_types AS ENUM (
        'caps', 'spoilers', 'emojis', 'spam_messages', 'repeated_text'
);

CREATE TYPE IF NOT EXISTS punishment_type AS ENUM (
    'timed_ban', 'perma_ban', 'kick', 'warn'
);

CREATE TYPE IF NOT EXISTS message_reaction AS ENUM (
    'delete', 'nothing'
);

-- ============================================================================
-- 1. CORE: Communities and Guilds
-- ============================================================================

CREATE TABLE IF NOT EXISTS comunity (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    community_name VARCHAR(255),
    created_by_user_id VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS comunity_guilds ( 
    comunity_id UUID NOT NULL REFERENCES comunity (id) ON DELETE CASCADE, 
    platform_guild_id VARCHAR(255) NOT NULL, 
    platform platform_type NOT NULL,

    PRIMARY KEY (comunity_id, platform_guild_id, platform),
    UNIQUE (platform_guild_id, platform)
);

-- ============================================================================
-- 2. RULESETS & ACTIVE MAPPINGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS rulesets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ruleset_name VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    belongs_to UUID REFERENCES comunity (id) NOT NULL ON DELETE CASCADE,
    UNIQUE (belongs_to, ruleset_name)
);

CREATE TABLE IF NOT EXISTS guild_active_ruleset ( 
    comunity_id UUID NOT NULL REFERENCES comunity(id) ON DELETE CASCADE,
    ruleset_id UUID NOT NULL REFERENCES rulesets (id) ON DELETE SET NULL,
    platform platform_type NOT NULL,
    platform_guild_id VARCHAR(255) NOT NULL,

    PRIMARY KEY (platform, platform_guild_id),
    FOREIGN KEY (comunity_id, platform_guild_id, platform) REFERENCES comunity_guilds(comunity_id, platform_guild_id, platform) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_guild_active_ruleset_comunity ON guild_active_ruleset(comunity_id);
CREATE INDEX IF NOT EXISTS idx_guild_active_ruleset_platform_guild ON guild_active_ruleset(platform_guild_id);

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
    CONSTRAINT check_scope_validity CHECK (
        channel_id IS NOT NULL OR role_id IS NOT NULL OR user_id IS NOT NULL
    ),
    UNIQUE(server_fk, channel_id, role_id, user_id, ruleset_id)
);

CREATE INDEX IF NOT EXISTS idx_ruleset_overrides_server_priority ON ruleset_overrides(server_fk, priority);

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
        (offender_reaction = 'timed_ban' AND duration_sec IS NOT NULL)
        OR (offender_reaction IN ('perma_ban', 'kick', 'warn') AND duration_sec IS NULL)
    ),
    UNIQUE(ruleset_id, rule_type)
);

CREATE INDEX IF NOT EXISTS idx_breaking_reactions_ruleset ON breaking_reactions(ruleset_id);

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

CREATE INDEX IF NOT EXISTS idx_logs_user ON moderation_logs(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_logs_guild ON moderation_logs(server_fk, created_at);
CREATE INDEX IF NOT EXISTS idx_logs_breaking_reaction ON moderation_logs(breaking_reaction_id);

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

CREATE INDEX IF NOT EXISTS idx_connection_codes_player ON economy_connection_codes(requesting_player_id);
CREATE INDEX IF NOT EXISTS idx_connections_platform ON economy_connections(platform, platform_user_id);

CREATE TABLE IF NOT EXISTS economy_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    player_id UUID NOT NULL REFERENCES economy_players(id),
    amount BIGINT NOT NULL,
    transaction_type transaction_type NOT NULL,
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 6. GAME STATE (kept in Redis; optional Postgres table commented)
-- ============================================================================

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

CREATE INDEX IF NOT EXISTS idx_moderator_platform_role_id ON moderator_platform_role(platform_role_id, platform_guild_id, platform);

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

CREATE INDEX IF NOT EXISTS idx_moderator_user_platform_user_id ON moderator_user(platform_user_id);

-- ============================================================================
-- Optional helper functions will be added in separate function scripts
-- ============================================================================
