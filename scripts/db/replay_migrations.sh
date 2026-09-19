#!/usr/bin/env bash
# Replays supabase/migrations from zero into a throwaway PostGIS container and
# fails if any migration errors. Keeps the recovered history reproducible.
#
# Usage: scripts/db/replay_migrations.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATIONS="$ROOT/supabase/migrations"
BOOTSTRAP="$ROOT/supabase/tests/local_bootstrap.sql"
CONTAINER="${TC_REPLAY_CONTAINER:-tc-migration-replay}"
IMAGE="${TC_REPLAY_IMAGE:-postgis/postgis:15-3.4}"
DB=tcreplay

cleanup() {
  if [ "${TC_KEEP_CONTAINER:-0}" != "1" ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres "$IMAGE" >/dev/null

# The image's entrypoint runs a temporary server during initdb, so wait for the
# real server: "ready to accept connections" must appear after the init restart.
for _ in $(seq 1 90); do
  if docker logs "$CONTAINER" 2>&1 | grep -q "database system is ready to accept connections" &&
     docker logs "$CONTAINER" 2>&1 | grep -q "PostgreSQL init process complete"; then
    break
  fi
  sleep 1
done
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -q && break
  sleep 1
done

psql_db() { docker exec -i -u postgres "$CONTAINER" psql -v ON_ERROR_STOP=1 -q -d "$1"; }

docker exec -u postgres "$CONTAINER" psql -q -c "CREATE DATABASE $DB" >/dev/null
psql_db "$DB" < "$BOOTSTRAP"

failed=0
for migration in "$MIGRATIONS"/2*.sql; do
  if ! output=$(psql_db "$DB" < "$migration" 2>&1); then
    failed=$((failed + 1))
    echo "FAIL $(basename "$migration")"
    echo "$output" | grep -E "^(psql:|ERROR|DETAIL|HINT)" | head -5 | sed 's/^/      /'
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "migraciones fallidas: $failed"
  exit 1
fi
echo "OK: $(ls "$MIGRATIONS"/2*.sql | wc -l) migraciones aplicadas desde cero"

psql_db "$DB" < "$ROOT/supabase/tests/security_invariants.sql"
echo "OK: invariantes de seguridad (search_path, RLS, fail-closed, RPC no recuperadas)"
