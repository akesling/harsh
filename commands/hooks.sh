#!/usr/bin/env sh
# hooks — list installed hooks grouped by event:  EVENT<TAB>relative/path.sh.
set -u
[ "${1:-}" = --describe ] && { printf 'hooks\tList installed hooks, grouped by event.\n'; exit 0; }
_d=${HARSH_HOOKS_DIR}
[ -d "${_d}" ] || { echo "(no hooks directory: ${_d})"; exit 0; }
_found=0
for _evt in SessionStart UserPromptSubmit PreToolUse PostToolUse PreCompact Stop; do
  for _h in "${_d}/${_evt}"/*.sh "${_d}/${_evt}"/*/*.sh; do
    [ -f "${_h}" ] || continue
    _found=1
    printf '%s\t%s\n' "${_evt}" "${_h#"${_d}/"}"
  done
done
[ "${_found}" = 0 ] && echo "(no hooks installed in ${_d})"
exit 0
