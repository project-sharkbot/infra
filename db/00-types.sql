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
