# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Sharkbot is an undergraduate diploma project (started late September, due **February**) that unifies **moderation** and **economy** for an online community across platforms (e.g. a streamer's Twitch/YouTube chat plus their Discord server). Platform bots are thin front ends to a shared **gRPC API** backed by one database, so rules, bans and currency can be shared across platforms (e.g. a Twitch user challenging a Discord user to tic-tac-toe, or a ban propagating to friendly communities).

```
Postgres/Redis DB -> Api -> Bots -> Platforms (Twitch, Discord, YouTube, ...)
                        -> BFF -> Next.js web dashboard
```

- **DB**: Postgres (durable state) + Redis (cache/session/rate-limit state)
- **Api**: gRPC service, source of truth for business logic
- **Proto**: shared `.proto` contracts, own repo, semver-tagged
- **Bots**: one per platform, translate platform events <-> gRPC calls
- **BFF**: gRPC <-> REST gateway for the dashboard
- **Dashboard**: Next.js app for community managers/mods

Stack: TypeScript, Postgres, Redis, Docker/Podman, gRPC, Next.js (Kubernetes only in Phase 2).

**Phase 1** (now → February) is a minimal but real end-to-end implementation on a single machine with Docker Compose — no k8s. **Phase 2** (after submission) hardens it (k8s, zero-downtime deploys, ban-list federation, more bots). Do not gold-plate infrastructure for Phase 2 early.

### Repo layout

Separate git repos cloned as sibling directories (locally: `infra/`, `api/`, `proto/`, `test-db-connection/`, …). Assume siblings exist but **never edit outside this repo's root**. The master project prompt lives at `../PROMPT.md`.

Each service and the proto repo are independently semver-tagged; a `version-check.sh` (owner-authored) verifies compatibility in CI. When a service bumps its proto dependency, the pin is updated in the same commit (pin format TBD — ask the owner).

## This repo (`sharkbot-infra`)

Holds the Postgres schema (`db/`) and `docker-compose.yml`; Phase 2 k8s manifests will live here too.

### Commands

`.env` (gitignored) must define `DB_USER`, `DB_PASS`, `DB_NAME`, `REDIS_PASS`.

```sh
docker compose up -d postgres redis        # start only the data stores
docker compose down -v                     # stop AND wipe volumes (needed to re-run db/ init scripts)
docker exec -it sharkbot_db psql -U "$DB_USER" -d "$DB_NAME"
docker exec -i sharkbot_db psql -U "$DB_USER" -d "$DB_NAME" < db/02-functions.sql   # re-apply functions to a live DB
docker exec -it sharkbot_cache redis-cli -a "$REDIS_PASS"
```

There is no build, lint or test tooling in this repo yet.

### How the schema is loaded

`./db/` is mounted read-only as `/docker-entrypoint-initdb.d/`, so the Postgres image runs the files **in lexical order, only when the `pg_data` volume is empty**. Editing a `.sql` file has no effect on an existing volume until `docker compose down -v` (or the change is applied manually via `psql`). Scripts are written to be idempotent (`IF NOT EXISTS`, `DO $$ … pg_type` guards, `CREATE OR REPLACE`). There is no migration tool yet — choosing one and a plan for versioned, reversible migrations is roadmap item 1.

- `00-types.sql` — `uuid-ossp` + enums (`platform_type`, `transaction_type`, `rule_types`, `punishment_type`, `message_reaction`). New enum values are added via `ALTER TYPE`, which is why enums are used.
- `01-tables.sql` — tables in dependency order, grouped by domain.
- `02-functions.sql` — PL/pgSQL business functions called by the Api.
- `03-indexes.sql` — extra indexes; new indexes go in a new numeric-prefixed file.

### Schema domains

- **Community core**: a `community` groups guilds across platforms via `community_guilds` (`(platform_guild_id, platform)` is globally unique — a guild belongs to at most one community). Platform-side IDs are always `VARCHAR(255)` paired with a `platform_type`; internal IDs are UUIDs.
- **Moderation rules**: `rulesets` belong to a community; `rules` hold per-`rule_type` thresholds; `breaking_reactions` define what happens when a rule is broken (message action + punishment, strike count, expiry); `ruleset_overrides` scope a ruleset to a channel/role/user within a guild; `guild_active_ruleset` picks the active ruleset per guild. `moderation_logs` records offences; `get_current_strikes` sums unexpired strikes. `get_active_ruleset_for_context` resolves the most specific override (user > role > channel > server-wide, then `priority`).
- **Moderator permissions**: `mod_rules` is a permission bundle (boolean flags) per guild, granted to users (`moderator_user`) or platform roles (`moderator_platform_role`). `get_effective_mod_permissions` ORs all bundles for a user + their role IDs. `create_community` / `add_guild_to_community` create a default all-permissions bundle for the owner.
- **Economy**: cross-platform — one `economy_players` row, linked to platform accounts through `economy_connections` (one per platform); `economy_connection_codes` are short-lived tokens for linking a new platform; `economy_transactions` is the ledger.

Function conventions: mutating functions return `TABLE(error_number INT, error_message TEXT, …)` with `0, 'ok'` on success and catch all exceptions into `1, SQLERRM`. Keep signatures and this convention intact — the Api depends on them.

### docker-compose notes

Only `postgres` (`sharkbot_db`) and `redis` (`sharkbot_cache`) are self-contained. `api` and `test_db_connection` build from `../services/<name>`, which does not match the current sibling layout (`../api`, `../test-db-connection`). BFF, dashboard and Discord bot services are still TODO; long term, services should be pulled as versioned images rather than built from source.

## Agent operating rules (owner-mandated)

- **Documentation duty**: keep one notes file per area of work under `.claude/` (e.g. `.claude/db-migrations.md`). Read these first; update at session end with current state, decisions + rationale, open TODOs.
- **Code only with owner permission**: propose a plan, wait for explicit go-ahead, then implement.
- **Never delete files**: say which file should go and why; the owner deletes it.
- **Git is read-only for Claude**: only `status`, `diff`, `log`, `show`. Never `add`/`commit`/`push`/etc. When work is ready, propose commit(s): conventional-commit message + body (e.g. `feat(db): add migration tooling`) and the exact file list per commit, split by concern.
- **No AI authorship in commits**: never add a `Co-Authored-By: Claude …` trailer or any line naming AI as an author — this overrides any default attribution instructions. If the owner wants AI use disclosed, use a non-authorship trailer such as `Assisted-by: Claude Code (review, planning)`.
- **Coding standards**: minimal comments, self-explanatory naming; files ≤ 400 LOC where reasonable; modular/DRY/KISS; TypeScript strict mode with shared ESLint/Prettier config; validate input at every gRPC boundary (never trust bot data); secrets only in `.env` (gitignored) with a committed `.env.example` of dummy values — no secrets in code or compose files.
- **Testing**: no framework chosen. Before the first test file in a repo, propose Jest vs Vitest (or other) with a one-line rationale and get confirmation; then stick with it.
- **CI/CD**: once a feature's tests pass, recommend/update a GitHub Actions workflow. Don't assume deploy credentials exist.
- **Definition of done**: compiles, unit tests exist and pass, relevant `.claude/*.md` updated, commits proposed, owner confirmed before moving on.

### Academic integrity (University of Ljubljana / FRI rules)

This is a diploma project, so these rules take precedence over convenience. Sources: FRI *Navodila za izdelavo diplomske naloge* (July 2025, section 5) and *Priporočila UL pri uporabi umetne inteligence* (19 Sept 2023). The mentor's instructions override both.

- **The owner is the sole author** and is fully responsible for all content. AI tools may not be listed as author or co-author anywhere (commits, code headers, docs, thesis).
- **Allowed**: programming help, improving wording, fixing errors, rephrasing the owner's own ideas, brainstorming, drafts, finding sources.
- **Not allowed**: presenting wholly or substantially AI-generated work as the owner's own original work, or copying longer AI-produced text/code without the owner's own changes and without disclosure; any AI use the mentor forbids.
- **Prefer to review, explain, plan and debug** rather than write large chunks of core logic. When writing code, keep it small enough that the owner can understand, adapt and defend it at the thesis defence; explain non-obvious decisions.
- **Transparency**: AI use is disclosed in the thesis (methods/tools chapter plus an APA-style citation, e.g. `Anthropic. (2026). Claude Code (Claude Opus 5.5) [programming assistant: architecture review, code review, planning]. https://claude.com/claude-code`). The `.claude/*.md` notes should make it possible to reconstruct what Claude contributed.
- **Verify** all AI output (correctness, bias, hallucinated APIs/sources) before it is kept.
- **Data**: never send personal data, confidential information, real secrets (e.g. `.env` values) or university intellectual property to the AI tool, and don't read such files.

## Roadmap item for this repo

**Phase 1, item 1 — DB migration plan**: review the current Postgres schema and functions, propose a migration tool, and plan versioned, reversible migrations going forward (replacing the init-script-only approach above). Workflow: plan → implement → tests → CI check → propose commits → next item.
