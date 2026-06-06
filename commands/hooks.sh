#!/usr/bin/env sh
# hooks — list installed hooks grouped by event:  EVENT<TAB>relative/path.sh.
set -u
[ "${1:-}" = --describe ] && { printf 'hooks\tList installed hooks, grouped by event.\n'; exit 0; }
d=$HARSH_HOOKS_DIR
[ -d "$d" ] || { echo "(no hooks directory: $d)"; exit 0; }
found=0
for evt in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do
  for h in "$d/$evt"/*.sh "$d/$evt"/*/*.sh; do
    [ -f "$h" ] || continue
    found=1
    printf '%s\t%s\n' "$evt" "${h#"$d/"}"
  done
done
[ "$found" = 0 ] && echo "(no hooks installed in $d)"
exit 0
