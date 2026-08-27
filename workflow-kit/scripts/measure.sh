#!/usr/bin/env bash
# Measure total tokens + cost for an opencode session from the sqlite store.
# Usage: measure.sh <session_id>
set -uo pipefail
DB="$HOME/.local/share/opencode/opencode.db"
sid="${1:?session_id required}"
sqlite3 "$DB" "
SELECT
  'inputs='   || SUM(json_extract(data,'$.tokens.input')),
  'outputs='  || SUM(json_extract(data,'$.tokens.output')),
  'reasoning='|| COALESCE(SUM(json_extract(data,'$.tokens.reasoning')),0),
  'cache_read='|| COALESCE(SUM(json_extract(data,'$.tokens.cache.read')),0),
  'cost='     || printf('%.6f', COALESCE(SUM(json_extract(data,'$.cost')),0)),
  'msgs='     || COUNT(*)
FROM message
WHERE session_id='$sid';
" 2>&1