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
