#!/usr/bin/env sh
# skills — list available skills as "/NAME<TAB>description" (also slash commands).
set -u
[ "${1:-}" = --describe ] && { printf 'skills\tList available skills / slash commands.\n'; exit 0; }
_d=${HARSH_SKILLS_DIR}
[ -d "${_d}" ] || { echo "(no skills directory: ${_d})"; exit 0; }
_base=$(basename "${_d}")
for _s in "${_d}"/*/SKILL.md "${_d}"/*.md; do
  [ -e "${_s}" ] || continue
  _name=$(basename "$(dirname "${_s}")")
  [ "${_name}" = "${_base}" ] && _name=$(basename "${_s}" .md)
  _desc=$(sed -n 's/^description:[[:space:]]*//p' "${_s}" | head -n1)
  printf '/%s\t%s\n' "${_name}" "${_desc}"
done
