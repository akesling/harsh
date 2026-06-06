#!/usr/bin/env sh
# skills — list available skills as "/NAME<TAB>description" (also slash commands).
set -u
[ "${1:-}" = --describe ] && { printf 'skills\tList available skills / slash commands.\n'; exit 0; }
d=$HARSH_SKILLS_DIR
[ -d "$d" ] || { echo "(no skills directory: $d)"; exit 0; }
base=$(basename "$d")
for s in "$d"/*/SKILL.md "$d"/*.md; do
  [ -e "$s" ] || continue
  name=$(basename "$(dirname "$s")")
  [ "$name" = "$base" ] && name=$(basename "$s" .md)
  desc=$(sed -n 's/^description:[[:space:]]*//p' "$s" | head -n1)
  printf '/%s\t%s\n' "$name" "$desc"
done
