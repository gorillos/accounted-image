#!/bin/bash
# Rehearses a migration list on a throwaway copy of the live database:
# a fresh supabase/postgres container (same image as supabase-db, no network),
# the live roles (without passwords), the given dump restored into "postgres",
# then apply-migrations.sh against it. Row counts of a few key tables are
# compared before/after. The container is removed at the end.
# The live database is only read (pg_dumpall --roles-only).
#
# Usage: dry-run-migrations.sh <list-file> <dump-file> [checkout]
set -euo pipefail
LIST="$1"; DUMP="$2"; DIR="${3:-/opt/accounted}"
HERE="$(cd "$(dirname "$0")" && pwd)"
C=accounted-migtest
WORK=$(mktemp -d); trap 'docker rm -f -v "$C" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
IMG=$(docker inspect supabase-db --format '{{.Config.Image}}')

docker rm -f -v "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" --network none -m 2g -e POSTGRES_PASSWORD="$(openssl rand -hex 16)" "$IMG" >/dev/null
for i in $(seq 60); do docker exec "$C" pg_isready -U postgres -h localhost >/dev/null 2>&1 && break; sleep 2; done; sleep 8

docker exec supabase-db pg_dumpall -U supabase_admin --roles-only --no-role-passwords > "$WORK/roles.sql"
docker exec -i "$C" psql -U supabase_admin -d postgres -X -q < "$WORK/roles.sql" > "$WORK/roles.log" 2>&1 || true
docker exec -i "$C" pg_restore -U supabase_admin -d postgres --clean --if-exists < "$DUMP" > "$WORK/restore.log" 2>&1 \
  || { echo "restore had errors:"; grep '^pg_restore: error' "$WORK/restore.log" | sort | uniq -c | head; exit 1; }

Q="select (select count(*) from public.companies),(select count(*) from public.journal_entries),(select count(*) from public.invoices),(select count(*) from auth.users),(select count(*) from storage.objects)"
before=$(docker exec "$C" psql -U supabase_admin -d postgres -Atc "$Q")
echo "copy before: $before (companies|journal_entries|invoices|auth.users|storage.objects)"

LOG="${DRYRUN_LOG:-$PWD/dryrun-$(date +%Y%m%d-%H%M%S).log}"; S=$(date +%s)
"$HERE/apply-migrations.sh" "$C" "$LIST" "$LOG" "$DIR"
after=$(docker exec "$C" psql -U supabase_admin -d postgres -Atc "$Q")
echo "copy after:  $after   ($(( $(date +%s)-S ))s, log: $LOG)"
[ "$before" = "$after" ] && echo "row counts unchanged" || echo "WARNING: row counts changed, review before going live"
