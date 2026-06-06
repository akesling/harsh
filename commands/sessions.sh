#!/usr/bin/env sh
# sessions — list existing sessions, newest first:  NAME<TAB>"<turns> turns · <topic>".
set -u
[ "${1:-}" = --describe ] && { printf 'sessions\tList existing sessions (newest first) as NAME<TAB>LABEL.\n'; exit 0; }
d=$HARSH_SESSIONS_DIR
[ -d "$d" ] || exit 0
for m in "$d"/*/manifest.csv; do
  [ -f "$m" ] || continue
  sdir=$(dirname "$m"); name=$(basename "$sdir")
  # Count non-empty manifest lines (turns). grep -c exits 1 on no match.
  turns=$(grep -c . "$m" 2>/dev/null); turns=${turns:-0}
  # First user entry's file → the session "topic" (pure shell, no awk).
  tf=""
  # shellcheck disable=SC2034
  while IFS=, read -r seq role type tname file ts status; do
    [ "$role" = user ] && { tf=$file; break; }
  done < "$m"
  topic=""
  if [ -n "$tf" ] && [ -f "$sdir/$tf" ]; then
    topic=$(jq -r '.block.text // ""' "$sdir/$tf" 2>/dev/null \
              | tr '\n\t' '  ' | sed 's/^ *//; s/ *$//' | cut -c1-80)
  fi
  [ -n "$topic" ] || topic="(empty)"
  printf '%s\t%s turns · %s\n' "$name" "$turns" "$topic"
done | sort -r
