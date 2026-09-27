#!/usr/bin/env bash
# For every migration, in order: its down must restore exactly the schema that
# existed before its up, and re-applying it must reproduce the same schema.
# Finally, db/schema.sql must match the fully migrated database.
set -euo pipefail

if [ "${MIGRATIONS_TEST_DESTRUCTIVE:-}" != "true" ]; then
  echo "Refusing to run without MIGRATIONS_TEST_DESTRUCTIVE=true: this rolls back every migration and destroys data." >&2
  exit 1
fi

cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a

existing=$(docker compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -tA -c \
  "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")
if [ "$existing" != "0" ]; then
  echo "Refusing to run: database $DB_NAME is not empty ($existing tables)." >&2
  exit 1
fi

steps=$(mktemp -d)
work=$(mktemp -d)
trap 'rm -rf "$steps" "$work"' EXIT

migrate() {
  docker compose run --rm -T \
    -v "$steps:/steps:ro" \
    -e DBMATE_MIGRATIONS_DIR=/steps \
    -e DBMATE_NO_DUMP_SCHEMA=true \
    migrate "$@"
}

schema() {
  docker compose exec -T postgres pg_dump --schema-only --restrict-key=ci \
    --exclude-table=public.schema_migrations -U "$DB_USER" -d "$DB_NAME" > "$work/$1"
}

fail() {
  echo "::error file=$1::$2"
  exit 1
}

for file in db/migrations/*.sql; do
  echo "::group::$(basename "$file")"
  cp "$file" "$steps/"
  schema before
  migrate --wait up
  schema applied
  migrate rollback
  schema rolled_back
  diff -u "$work/before" "$work/rolled_back" || fail "$file" "down does not exactly reverse up"
  migrate up
  schema reapplied
  diff -u "$work/applied" "$work/reapplied" || fail "$file" "up gives a different schema after a rollback"
  echo "::endgroup::"
done

docker compose run --rm -T migrate dump
git diff --exit-code db/schema.sql || fail db/schema.sql "not regenerated: run 'docker compose run --rm migrate dump' and commit it"
