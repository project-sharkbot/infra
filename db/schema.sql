\restrict dbmate

-- Dumped from database version 16.15
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: message_reaction; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.message_reaction AS ENUM (
    'delete',
    'nothing'
);


--
-- Name: platform_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.platform_type AS ENUM (
    'discord',
    'twitch'
);


--
-- Name: punishment_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.punishment_type AS ENUM (
    'timed_ban',
    'perma_ban',
    'kick',
    'warn'
);


--
-- Name: rule_types; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.rule_types AS ENUM (
    'caps',
    'spoilers',
    'emojis',
    'spam_messages',
    'repeated_text'
);


--
-- Name: transaction_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.transaction_type AS ENUM (
    'daily_reward',
    'gamble_transaction',
    'user_transfer',
    'game_transaction',
    'admin_adjust'
);


--
-- Name: add_guild_to_community(character varying, public.platform_type, uuid, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_guild_to_community(p_guild_id character varying, p_platform public.platform_type, p_target_community_id uuid, p_foreign_guild_id character varying, p_owner_user_id character varying) RETURNS TABLE(error_number integer, error_message text)
    LANGUAGE plpgsql
    SET "sharkbot.owner_change" TO 'on'
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


--
-- Name: create_community(character varying, public.platform_type, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_community(guild_id character varying, platform public.platform_type, p_user_id character varying, community_str_name text) RETURNS TABLE(error_number integer, error_message text, community_id uuid)
    LANGUAGE plpgsql
    SET "sharkbot.owner_change" TO 'on'
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


--
-- Name: get_active_ruleset_for_context(character varying, character varying, character varying, text[], public.platform_type); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_active_ruleset_for_context(p_server_fk character varying, p_channel_id character varying, p_user_id character varying, p_role_ids text[], p_platform public.platform_type) RETURNS TABLE(ruleset_id uuid, ruleset_name character varying, is_server_wide boolean, override_priority integer)
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


--
-- Name: get_current_strikes(character varying, character varying, public.platform_type); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_strikes(p_user_id character varying, p_server_fk character varying, p_platform public.platform_type) RETURNS integer
    LANGUAGE sql
    AS $_$
    SELECT COALESCE(SUM(COALESCE(br.strike_count, 1)), 0) AS strikes
    FROM moderation_logs ml
    LEFT JOIN breaking_reactions br ON ml.breaking_reaction_id = br.id
    WHERE ml.user_id = $1
      AND ml.server_fk = $2
      AND ml.platform = $3
      AND (ml.valid_until IS NULL OR ml.valid_until > NOW());
$_$;


--
-- Name: get_effective_mod_permissions(public.platform_type, character varying, character varying, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_effective_mod_permissions(p_platform public.platform_type, p_platform_guild_id character varying, p_platform_user_id character varying, p_role_ids text[]) RETURNS TABLE(delete_user_messages boolean, create_rulesets boolean, edit_rulesets boolean, delete_rulesets boolean, create_roles boolean, edit_roles boolean, delete_roles boolean, change_active_ruleset boolean)
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


--
-- Name: guild_exists(character varying, public.platform_type); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guild_exists(guild_id character varying, platform public.platform_type) RETURNS boolean
    LANGUAGE sql
    AS $_$
    SELECT EXISTS(
        SELECT 1
        FROM community_guilds
        WHERE platform_guild_id = $1
            AND platform = $2
    );
$_$;


--
-- Name: lock_owner_bundle(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lock_owner_bundle() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'The built-in owner bundle cannot be changed or deleted';
END;
$$;


--
-- Name: lock_owner_rows(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lock_owner_rows() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF current_setting('sharkbot.owner_change', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Ownership cannot be changed outside of ownership functions';
    end if;
    RETURN COALESCE(NEW, OLD);
end;
$$;


--
-- Name: owner_rules_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.owner_rules_id() RETURNS uuid
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT '00000000-0000-0000-0000-000000000001'::uuid $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: breaking_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.breaking_reactions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    ruleset_id uuid NOT NULL,
    rule_type public.rule_types NOT NULL,
    message_action public.message_reaction DEFAULT 'delete'::public.message_reaction NOT NULL,
    offender_reaction public.punishment_type DEFAULT 'warn'::public.punishment_type NOT NULL,
    duration_sec integer,
    strike_count integer DEFAULT 1,
    expiry_duration integer,
    CONSTRAINT breaking_reactions_duration_sec_check CHECK (((duration_sec IS NULL) OR (duration_sec > 0))),
    CONSTRAINT breaking_reactions_expiry_duration_check CHECK ((expiry_duration > 0)),
    CONSTRAINT breaking_reactions_strike_count_check CHECK ((strike_count > 0)),
    CONSTRAINT punishment_match_duration CHECK ((((offender_reaction = 'timed_ban'::public.punishment_type) AND (duration_sec IS NOT NULL)) OR ((offender_reaction = ANY (ARRAY['perma_ban'::public.punishment_type, 'kick'::public.punishment_type, 'warn'::public.punishment_type])) AND (duration_sec IS NULL))))
);


--
-- Name: community; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.community (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    community_name character varying(255),
    created_by_user_id character varying(255),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: community_guilds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.community_guilds (
    community_id uuid NOT NULL,
    platform_guild_id character varying(255) NOT NULL,
    platform public.platform_type NOT NULL
);


--
-- Name: economy_connection_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.economy_connection_codes (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    requesting_player_id uuid,
    requesting_platform public.platform_type NOT NULL,
    target_platform public.platform_type NOT NULL,
    token character varying(100) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '00:10:00'::interval) NOT NULL,
    CONSTRAINT economy_connection_codes_check CHECK ((target_platform IS DISTINCT FROM requesting_platform))
);


--
-- Name: economy_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.economy_connections (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    player_id uuid NOT NULL,
    platform public.platform_type NOT NULL,
    platform_user_id character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: economy_players; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.economy_players (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    balance bigint DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    last_daily_reward timestamp with time zone
);


--
-- Name: economy_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.economy_transactions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    player_id uuid NOT NULL,
    amount bigint NOT NULL,
    transaction_type public.transaction_type NOT NULL,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: guild_active_ruleset; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guild_active_ruleset (
    community_id uuid NOT NULL,
    ruleset_id uuid NOT NULL,
    platform public.platform_type NOT NULL,
    platform_guild_id character varying(255) NOT NULL
);


--
-- Name: mod_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mod_rules (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    rules_name character varying(255) NOT NULL,
    platform public.platform_type,
    platform_guild_id character varying(255),
    delete_user_messages boolean DEFAULT false,
    create_rulesets boolean DEFAULT false,
    edit_rulesets boolean DEFAULT false,
    delete_rulesets boolean DEFAULT false,
    create_roles boolean DEFAULT false,
    edit_roles boolean DEFAULT false,
    delete_roles boolean DEFAULT false,
    change_active_ruleset boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT chk_builtin CHECK (((id = public.owner_rules_id()) OR ((platform IS NOT NULL) AND (platform_guild_id IS NOT NULL))))
);


--
-- Name: moderation_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.moderation_logs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    platform public.platform_type NOT NULL,
    server_fk character varying(255) NOT NULL,
    channel_id character varying(255),
    user_id character varying(255) NOT NULL,
    moderator_id character varying(255),
    breaking_reaction_id uuid,
    message_content_snapshot text,
    created_at timestamp with time zone DEFAULT now(),
    valid_until timestamp with time zone,
    CONSTRAINT offence_validity CHECK (((valid_until IS NULL) OR (valid_until > created_at)))
);


--
-- Name: moderator_platform_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.moderator_platform_role (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    platform public.platform_type NOT NULL,
    platform_guild_id character varying(255) NOT NULL,
    platform_role_id character varying(255) NOT NULL,
    rules_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: moderator_user; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.moderator_user (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    platform public.platform_type NOT NULL,
    platform_guild_id character varying(255) NOT NULL,
    platform_user_id character varying(255) NOT NULL,
    mod_rules_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    granted_by_user_id character varying(255)
);


--
-- Name: rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rules (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    ruleset_id uuid NOT NULL,
    rule_type public.rule_types NOT NULL,
    is_enabled boolean DEFAULT true,
    threshold_value integer NOT NULL,
    threshold_window_sec integer
);


--
-- Name: ruleset_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ruleset_overrides (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    ruleset_id uuid,
    server_fk character varying(255) NOT NULL,
    channel_id character varying(255),
    role_id character varying(255),
    user_id character varying(255),
    priority integer DEFAULT 0,
    override_threshold_value integer,
    override_window_sec integer,
    override_enabled boolean DEFAULT true,
    CONSTRAINT check_scope_validity CHECK (((channel_id IS NOT NULL) OR (role_id IS NOT NULL) OR (user_id IS NOT NULL)))
);


--
-- Name: rulesets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rulesets (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    ruleset_name character varying(100) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    belongs_to uuid NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: breaking_reactions breaking_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.breaking_reactions
    ADD CONSTRAINT breaking_reactions_pkey PRIMARY KEY (id);


--
-- Name: breaking_reactions breaking_reactions_ruleset_id_rule_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.breaking_reactions
    ADD CONSTRAINT breaking_reactions_ruleset_id_rule_type_key UNIQUE (ruleset_id, rule_type);


--
-- Name: community_guilds community_guilds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_guilds
    ADD CONSTRAINT community_guilds_pkey PRIMARY KEY (community_id, platform_guild_id, platform);


--
-- Name: community_guilds community_guilds_platform_guild_id_platform_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_guilds
    ADD CONSTRAINT community_guilds_platform_guild_id_platform_key UNIQUE (platform_guild_id, platform);


--
-- Name: community community_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community
    ADD CONSTRAINT community_pkey PRIMARY KEY (id);


--
-- Name: economy_connection_codes economy_connection_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_connection_codes
    ADD CONSTRAINT economy_connection_codes_pkey PRIMARY KEY (id);


--
-- Name: economy_connection_codes economy_connection_codes_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_connection_codes
    ADD CONSTRAINT economy_connection_codes_token_key UNIQUE (token);


--
-- Name: economy_connections economy_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_connections
    ADD CONSTRAINT economy_connections_pkey PRIMARY KEY (id);


--
-- Name: economy_connections economy_connections_platform_platform_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_connections
    ADD CONSTRAINT economy_connections_platform_platform_user_id_key UNIQUE (platform, platform_user_id);


--
-- Name: economy_connections economy_connections_player_id_platform_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_connections
    ADD CONSTRAINT economy_connections_player_id_platform_key UNIQUE (player_id, platform);


--
-- Name: economy_players economy_players_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_players
    ADD CONSTRAINT economy_players_pkey PRIMARY KEY (id);


--
-- Name: economy_transactions economy_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_transactions
    ADD CONSTRAINT economy_transactions_pkey PRIMARY KEY (id);


--
-- Name: guild_active_ruleset guild_active_ruleset_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guild_active_ruleset
    ADD CONSTRAINT guild_active_ruleset_pkey PRIMARY KEY (platform, platform_guild_id);


--
-- Name: mod_rules mod_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mod_rules
    ADD CONSTRAINT mod_rules_pkey PRIMARY KEY (id);


--
-- Name: mod_rules mod_rules_platform_platform_guild_id_rules_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mod_rules
    ADD CONSTRAINT mod_rules_platform_platform_guild_id_rules_name_key UNIQUE (platform, platform_guild_id, rules_name);


--
-- Name: moderation_logs moderation_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_logs
    ADD CONSTRAINT moderation_logs_pkey PRIMARY KEY (id);


--
-- Name: moderator_platform_role moderator_platform_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_platform_role
    ADD CONSTRAINT moderator_platform_role_pkey PRIMARY KEY (id);


--
-- Name: moderator_platform_role moderator_platform_role_platform_platform_role_id_platform__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_platform_role
    ADD CONSTRAINT moderator_platform_role_platform_platform_role_id_platform__key UNIQUE (platform, platform_role_id, platform_guild_id);


--
-- Name: moderator_user moderator_user_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_user
    ADD CONSTRAINT moderator_user_pkey PRIMARY KEY (id);


--
-- Name: moderator_user moderator_user_platform_platform_guild_id_platform_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_user
    ADD CONSTRAINT moderator_user_platform_platform_guild_id_platform_user_id_key UNIQUE (platform, platform_guild_id, platform_user_id);


--
-- Name: rules rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rules
    ADD CONSTRAINT rules_pkey PRIMARY KEY (id);


--
-- Name: rules rules_ruleset_id_rule_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rules
    ADD CONSTRAINT rules_ruleset_id_rule_type_key UNIQUE (ruleset_id, rule_type);


--
-- Name: ruleset_overrides ruleset_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ruleset_overrides
    ADD CONSTRAINT ruleset_overrides_pkey PRIMARY KEY (id);


--
-- Name: ruleset_overrides ruleset_overrides_server_fk_channel_id_role_id_user_id_rule_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ruleset_overrides
    ADD CONSTRAINT ruleset_overrides_server_fk_channel_id_role_id_user_id_rule_key UNIQUE (server_fk, channel_id, role_id, user_id, ruleset_id);


--
-- Name: rulesets rulesets_belongs_to_ruleset_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rulesets
    ADD CONSTRAINT rulesets_belongs_to_ruleset_name_key UNIQUE (belongs_to, ruleset_name);


--
-- Name: rulesets rulesets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rulesets
    ADD CONSTRAINT rulesets_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: idx_breaking_reactions_ruleset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_breaking_reactions_ruleset ON public.breaking_reactions USING btree (ruleset_id);


--
-- Name: idx_connection_codes_player; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_connection_codes_player ON public.economy_connection_codes USING btree (requesting_player_id);


--
-- Name: idx_connections_platform; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_connections_platform ON public.economy_connections USING btree (platform, platform_user_id);


--
-- Name: idx_logs_breaking_reaction; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_logs_breaking_reaction ON public.moderation_logs USING btree (breaking_reaction_id);


--
-- Name: idx_logs_guild; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_logs_guild ON public.moderation_logs USING btree (server_fk, created_at);


--
-- Name: idx_logs_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_logs_user ON public.moderation_logs USING btree (user_id, created_at);


--
-- Name: idx_moderator_platform_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_moderator_platform_role_id ON public.moderator_platform_role USING btree (platform_role_id, platform_guild_id, platform);


--
-- Name: idx_moderator_user_platform_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_moderator_user_platform_user_id ON public.moderator_user USING btree (platform_user_id);


--
-- Name: idx_ruleset_overrides_server_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ruleset_overrides_server_priority ON public.ruleset_overrides USING btree (server_fk, priority);


--
-- Name: moderator_user_one_owner_per_guild; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX moderator_user_one_owner_per_guild ON public.moderator_user USING btree (platform, platform_guild_id) WHERE (mod_rules_id = public.owner_rules_id());


--
-- Name: mod_rules lock_owner_bundle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER lock_owner_bundle BEFORE DELETE OR UPDATE ON public.mod_rules FOR EACH ROW WHEN ((old.id = public.owner_rules_id())) EXECUTE FUNCTION public.lock_owner_bundle();


--
-- Name: moderator_user lock_owner_new; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER lock_owner_new BEFORE INSERT OR UPDATE ON public.moderator_user FOR EACH ROW WHEN ((new.mod_rules_id = public.owner_rules_id())) EXECUTE FUNCTION public.lock_owner_rows();


--
-- Name: moderator_user lock_owner_old; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER lock_owner_old BEFORE DELETE OR UPDATE ON public.moderator_user FOR EACH ROW WHEN ((old.mod_rules_id = public.owner_rules_id())) EXECUTE FUNCTION public.lock_owner_rows();


--
-- Name: breaking_reactions breaking_reactions_ruleset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.breaking_reactions
    ADD CONSTRAINT breaking_reactions_ruleset_id_fkey FOREIGN KEY (ruleset_id) REFERENCES public.rulesets(id) ON DELETE CASCADE;


--
-- Name: community_guilds community_guilds_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_guilds
    ADD CONSTRAINT community_guilds_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON DELETE CASCADE;


--
-- Name: economy_connection_codes economy_connection_codes_requesting_player_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_connection_codes
    ADD CONSTRAINT economy_connection_codes_requesting_player_id_fkey FOREIGN KEY (requesting_player_id) REFERENCES public.economy_players(id) ON DELETE CASCADE;


--
-- Name: economy_connections economy_connections_player_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_connections
    ADD CONSTRAINT economy_connections_player_id_fkey FOREIGN KEY (player_id) REFERENCES public.economy_players(id) ON DELETE CASCADE;


--
-- Name: economy_transactions economy_transactions_player_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_transactions
    ADD CONSTRAINT economy_transactions_player_id_fkey FOREIGN KEY (player_id) REFERENCES public.economy_players(id);


--
-- Name: guild_active_ruleset guild_active_ruleset_community_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guild_active_ruleset
    ADD CONSTRAINT guild_active_ruleset_community_id_fkey FOREIGN KEY (community_id) REFERENCES public.community(id) ON DELETE CASCADE;


--
-- Name: guild_active_ruleset guild_active_ruleset_community_id_platform_guild_id_platfo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guild_active_ruleset
    ADD CONSTRAINT guild_active_ruleset_community_id_platform_guild_id_platfo_fkey FOREIGN KEY (community_id, platform_guild_id, platform) REFERENCES public.community_guilds(community_id, platform_guild_id, platform) ON DELETE CASCADE;


--
-- Name: guild_active_ruleset guild_active_ruleset_ruleset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guild_active_ruleset
    ADD CONSTRAINT guild_active_ruleset_ruleset_id_fkey FOREIGN KEY (ruleset_id) REFERENCES public.rulesets(id) ON DELETE RESTRICT;


--
-- Name: moderation_logs moderation_logs_breaking_reaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_logs
    ADD CONSTRAINT moderation_logs_breaking_reaction_id_fkey FOREIGN KEY (breaking_reaction_id) REFERENCES public.breaking_reactions(id) ON DELETE SET NULL;


--
-- Name: moderator_platform_role moderator_platform_role_rules_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_platform_role
    ADD CONSTRAINT moderator_platform_role_rules_id_fkey FOREIGN KEY (rules_id) REFERENCES public.mod_rules(id) ON DELETE CASCADE;


--
-- Name: moderator_user moderator_user_mod_rules_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderator_user
    ADD CONSTRAINT moderator_user_mod_rules_id_fkey FOREIGN KEY (mod_rules_id) REFERENCES public.mod_rules(id) ON DELETE CASCADE;


--
-- Name: rules rules_ruleset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rules
    ADD CONSTRAINT rules_ruleset_id_fkey FOREIGN KEY (ruleset_id) REFERENCES public.rulesets(id) ON DELETE CASCADE;


--
-- Name: ruleset_overrides ruleset_overrides_ruleset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ruleset_overrides
    ADD CONSTRAINT ruleset_overrides_ruleset_id_fkey FOREIGN KEY (ruleset_id) REFERENCES public.rulesets(id) ON DELETE CASCADE;


--
-- Name: rulesets rulesets_belongs_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rulesets
    ADD CONSTRAINT rulesets_belongs_to_fkey FOREIGN KEY (belongs_to) REFERENCES public.community(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20260927000001'),
    ('20260927152814'),
    ('20260927175128'),
    ('20260927175145'),
    ('20260927185611');
