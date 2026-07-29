-- Enable UUID extension for robust primary keys
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- 0. Custom types
-- ============================================================================

-- Enum type for the platforms that we support 
CREATE TYPE platform_type AS ENUM ('discord', 'twitch');
-- can be edited with the following statement (i.e. adding youtube)
-- ALTER TYPE platform_type ADD VALUE 'youtube'; 
-- !! can't remove values from enum by default afaik

-- Enum type for kind of transactions in case more get added in the future
-- i.e. a new game is made
CREATE TYPE transaction_type AS ENUM (
        'daily_reward', 'gamble_transaction',  
        'user_transfer', 'game_transaction', 'admin_adjust'
);

CREATE TYPE rule_types AS ENUM (
        'caps', 'spoilers', 'emojis', 'spam_messages', 'repeated_text'
);

-- What the reaction of the offender should be
CREATE TYPE punishment_type AS ENUM (
    'timed_ban', 'perma_ban', 'kick', 'warn'
);

-- What to do with offending message
CREATE TYPE message_reaction AS ENUM (
    -- possibly adding 'censor' in the future
    'delete', 'nothing'
);

-- ============================================================================
-- 1. CORE CONFIGURATION & RULESETS
-- ============================================================================

-- Defines a collection of rules (e.g., "Strict Gaming", "Casual Chat")
CREATE TABLE rulesets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL,
    platform platform_type NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Individual rules belonging to a ruleset
CREATE TABLE rules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ruleset_id UUID NOT NULL REFERENCES rulesets(id) ON DELETE CASCADE,
    rule_type rule_types NOT NULL,
    
    is_enabled BOOLEAN DEFAULT TRUE,
    threshold_value INT NOT NULL, -- e.g., max caps %, max emojis count, spam window size
    threshold_window_sec INT,     -- Optional: time window for spam/repetition (NULL means instant)
    UNIQUE(ruleset_id, rule_type)
);

-- ============================================================================
-- 2. HIERARCHICAL OVERRIDES (Server > Channel > Role/User)
-- ============================================================================
-- This table resolves the "Per server/channel/role" requirement.
-- Logic: 
-- 1. If channel_id IS NULL and role_id IS NULL -> Server Wide
-- 2. If channel_id IS NOT NULL and role_id IS NULL -> Channel Specific
-- 3. If role_id IS NOT NULL -> Role Specific (applies to users with this role)
-- 4. If user_id IS NOT NULL -> Specific User Override

CREATE TABLE ruleset_overrides (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ruleset_id UUID REFERENCES rulesets(id) ON DELETE CASCADE, -- Nullable: NULL = Regardless of ruleset i.e. spam channel
    
    -- Context Identifiers
    server_fk VARCHAR(255) NOT NULL, -- Discord Guild ID or Twitch Channel ID
    channel_id VARCHAR(255),         -- Nullable: NULL = All channels, duplicate for Twitch Channel ID (server_fk above)
    role_id VARCHAR(255),            -- Nullable: NULL = No role filter
    user_id VARCHAR(255),            -- Nullable: NULL = All users
    
    -- Priority: Higher number overrides lower (e.g., Role override > Server default)
    priority INT DEFAULT 0, 
    
    -- Specific rule adjustments for this override (optional, else inherits ruleset)
    -- If NULL, it simply enables the parent ruleset for this scope.
    -- If populated, these values override the parent 'rules' table for this scope.
    override_threshold_value INT,
    override_window_sec INT,

    override_enabled BOOLEAN DEFAULT TRUE,

    CONSTRAINT check_scope_validity CHECK (
        -- "At least one must be non-null" beyond server_fk is handled by logic, 
        -- but strictly: server_fk is always present. 
        -- We ensure we don't have meaningless rows (e.g. all nulls except server) if needed.
        channel_id IS NOT NULL OR role_id IS NOT NULL OR user_id IS NOT NULL
    ),
    
    -- Ensure no duplicate overrides for the exact same scope
    UNIQUE(server_fk, channel_id, role_id, user_id, ruleset_id)
);

-- ============================================================================
-- 3. MODERATION ACTIONS & LOGGING
-- ============================================================================

-- Defines what happens when a rule is broken (Configurable per ruleset or global)
CREATE TABLE breaking_reactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ruleset_id UUID NOT NULL REFERENCES rulesets(id) ON DELETE CASCADE,
    rule_type VARCHAR(50) NOT NULL, -- Links to rules.rule_type
    
    -- Actions depend on bot perms and platform abilities 
    message_action message_reaction NOT NULL DEFAULT 'delete', 
    offender_reaction punishment_type NOT NULL DEFAULT 'warn',

    duration_sec INT CHECK (duration_sec is NULL OR duration_sec > 0),  -- punishment duraction in seconds 
                                                                        -- not null only for timed bans
                                                                        -- managed by constraint

    strike_count INT DEFAULT 1 CHECK (strike_count > 0),                -- How many strikes this action adds
    
    CONSTRAINT punishment_match_duration CHECK (
        (offender_reaction = 'timed_ban' AND duration_sec IS NOT NULL)
        OR (offender_reaction IN ('perma_ban', 'kick', 'warn') AND duration_sec IS NULL)
    ),

    -- When to no longer count as a strike (forgive/forget timer)
    -- value -> current_time + value = valid_until timestamp
    -- NULL -> valid_until = NULL -> never forgive/always valid
    expiry_duration INT DEFAULT NULL CHECK (expiry_duration > 0)
);

-- Audit log of all actions taken by the bot
CREATE TABLE moderation_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    platform platform_type NOT NULL, 

    server_fk VARCHAR(255) NOT NULL,
    channel_id VARCHAR(255),       -- Duplicate/Null if on Twitch Channel ID

    user_id VARCHAR(255) NOT NULL, -- The offender
    moderator_id VARCHAR(255),     -- The bot or human who triggered it
    
    rule_violated VARCHAR(50),
    action_taken VARCHAR(50) NOT NULL,

    message_content_snapshot TEXT, -- Store snippet of offending message
    created_at TIMESTAMPTZ DEFAULT NOW(),

    valid_until TIMESTAMPTZ, -- NULL == forever, otherwise expiry_duration + created_at

    CONSTRAINT offence_validity CHECK (valid_until IS NULL OR valid_until > created_at)

);

-- Index for fast lookup of user history
CREATE INDEX idx_logs_user ON moderation_logs(user_id, created_at);

-- ============================================================================
-- 4. ECONOMY SYSTEM (Unified Multiplatform)
-- ============================================================================

-- The internal ledger. Independent of Discord/Twitch IDs.
CREATE TABLE economy_players (
    -- Other tables reference this as the interal id of the player
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    balance BIGINT DEFAULT 0, -- Use BIGINT for currency to avoid float precision issues
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_daily_reward TIMESTAMPTZ
);

-- Links external platform IDs to the internal economy player
CREATE TABLE economy_connections (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    player_id UUID NOT NULL REFERENCES economy_players(id) ON DELETE CASCADE,
    
    platform platform_type NOT NULL,
    platform_user_id VARCHAR(255) NOT NULL, -- The raw ID from Discord/Twitch
    -- connection_code VARCHAR(50), -- For manual linking via dashboard
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(platform, platform_user_id), -- One platform account per player
    UNIQUE(player_id, platform)         -- One link per platform type per player
);

CREATE TABLE economy_connection_codes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    target_platform platform_type NOT NULL,
    
    requesting_platform platform_type NOT NULL,
    requesting_platform_user_id VARCHAR(255) NOT NULL, 

    token VARCHAR(100) UNIQUE NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '10 minutes')
);

-- Index for fast lookup: "Find player by Discord ID"
CREATE INDEX idx_connections_platform ON economy_connections(platform, platform_user_id);

-- Transaction history for the economy
CREATE TABLE economy_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    player_id UUID NOT NULL REFERENCES economy_players(id),
    amount BIGINT NOT NULL, -- Negative for spend, positive for gain
    transaction_type transaction_type NOT NULL,
    metadata JSONB, -- Store game details 
    -- (e.g., {"guess": 500, "target": 499})
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- 5. GAME STATE -- TODO: move to Redis instead
-- ============================================================================

-- CREATE TABLE active_games (
--     id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
--     game_type VARCHAR(20) NOT NULL CHECK (game_type IN ('tictactoe', 'connect4')),
    
--     player_1_id UUID NOT NULL REFERENCES economy_players(id),
--     player_2_id UUID NOT NULL REFERENCES economy_players(id),
    
--     board_state JSONB NOT NULL, -- Store grid as JSON: [[0,1,2],[3,4,5]...]
--     current_turn_id UUID NOT NULL REFERENCES economy_players(id),
    
--     bet_amount BIGINT DEFAULT 0,
--     status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'completed', 'aborted')),
--     winner_id UUID REFERENCES economy_players(id),
    
--     created_at TIMESTAMPTZ DEFAULT NOW(),
--     updated_at TIMESTAMPTZ DEFAULT NOW()
-- );

-- ============================================================================
-- 6. Moderation roles - not dependant on the platform
-- ============================================================================

CREATE TABLE mod_rules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    rules_name VARCHAR(255) NOT NULL UNIQUE,

    -- platform specific
    platform platform_type NOT NULL,
    platform_guild_id VARCHAR(255) NOT NULL, -- channel or server ID

    -- use commands like delete 50 and similar
    delete_user_messages BOOLEAN DEFAULT false,

    -- edit and manipulate rulesets
    create_rulesets BOOLEAN DEFAULT false,
    edit_rulesets BOOLEAN DEFAULT false,
    delete_rulesets BOOLEAN DEFAULT false,

    -- edit and manipulate api side roles
    create_roles BOOLEAN DEFAULT false,
    edit_roles BOOLEAN DEFAULT false,
    delete_roles BOOLEAN DEFAULT false,

    -- For example being able to set to 'strict' without being able to edit or change them
    -- useful for moderation where the user shouldn't have full access 
    change_active_ruleset BOOLEAN DEFAULT false
);

-- Any moderator with the given role 
-- will have permisions of said role 
-- This is so that not all moderators 
-- need to  be on the database
CREATE TABLE moderator_platform_role (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    platform platform_type NOT NULL,
    platform_guild_id VARCHAR(255) NOT NULL,    -- i.e. discord server id or twitch channel username
    platform_role_id VARCHAR(255) NOT NULL,     -- i.e. discord role id, 'moderator'...

    rules_id UUID NOT NULL,

    FOREIGN KEY (rules_id) REFERENCES mod_rules(id) ON DELETE CASCADE,
    UNIQUE (platform, platform_role_id, platform_guild_id)
);

CREATE INDEX idx_moderator_platform_role_id ON moderator_platform_role(platform_role_id, platform_guild_id, platform);

-- Admin adds a new moderator manually
-- They have given perms seperately from platform roles
CREATE TABLE moderator_user (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    platform platform_type NOT NULL,
    platform_guild_id VARCHAR(255) NOT NULL,    -- twitch channel name or discord server ID 
    platform_user_id VARCHAR(255) NOT NULL,     -- how the user is referenced by the platform

    mod_rules_id UUID NOT NULL,

    FOREIGN KEY (mod_rules_id) REFERENCES mod_rules(id)
);

CREATE INDEX idx_moderator_user_platform_user_id ON moderator_user(platform_user_id);
