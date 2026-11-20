#!/bin/bash
# Lists the Supabase migrations added between two Accounted commits, in the
# order they must run, and refuses if any is dated before the newest migration
# of the OLD commit (that one would be skipped by an in-order replay).
#
# Usage: new-migrations.sh <old-commit> <new-commit> [checkout] > new-migrations.txt
#   checkout defaults to /opt/accounted (must already have <new-commit> fetched).
set -euo pipefail
OLD="$1"; NEW="$2"; REPO="${3:-/opt/accounted}"
g() { git -C "$REPO" "$@"; }
g cat-file -e "$OLD^{commit}" && g cat-file -e "$NEW^{commit}"

last_old=$(g ls-tree --name-only "$OLD" supabase/migrations/ | grep -E '\.sql$' | sort | tail -1 | xargs -n1 basename)
added=$(g diff --name-only --diff-filter=A "$OLD" "$NEW" -- 'supabase/migrations/*.sql' | grep -v __tests__ | sort || true)

backdated=$(printf '%s\n' "$added" | awk -F/ -v last="$last_old" 'NF && $3 <= last')
if [ -n "$backdated" ]; then
  echo "REFUSING: these new migrations sort before $last_old (newest in $OLD):" >&2
  printf '%s\n' "$backdated" >&2; exit 1
fi

changed=$(g diff --name-only --diff-filter=MDR "$OLD" "$NEW" -- 'supabase/migrations/*.sql' | grep -v __tests__ || true)
if [ -n "$changed" ]; then
  echo "NOTE: already-applied migrations were edited or removed upstream (not re-run; review the diff):" >&2
  printf '  %s\n' $changed >&2
fi

printf '%s\n' "$added" | sed '/^$/d'
echo "$(printf '%s\n' "$added" | sed '/^$/d' | wc -l) new migrations after $last_old" >&2
