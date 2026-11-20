#!/bin/bash
# Applies the migrations listed in a file (paths relative to the checkout), in
# order, one psql call per file, stopping at the first error. The SQL is not
# idempotent: never re-run a file that already succeeded.
#
# Usage: apply-migrations.sh <db-container> <list-file> <log-file> [checkout]
#   checkout defaults to /opt/accounted and must be at the NEW commit.
set -euo pipefail
C="$1"; LIST="$2"; LOG="$3"; DIR="${4:-/opt/accounted}"
total=$(grep -c . "$LIST" || true); n=0
while read -r f; do
  [ -n "$f" ] || continue
  n=$((n+1)); echo "=== [$n/$total] $f" >>"$LOG"
  if ! docker exec -i "$C" psql -U supabase_admin -d postgres -X -q -v ON_ERROR_STOP=1 < "$DIR/$f" >>"$LOG" 2>&1; then
    echo "FAILED at [$n/$total] $f (see $LOG; earlier files ARE applied)" | tee -a "$LOG"; exit 1
  fi
done < "$LIST"
echo "DONE: $n migrations applied OK" | tee -a "$LOG"
