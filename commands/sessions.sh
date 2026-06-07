#!/usr/bin/env sh
# sessions — list existing sessions, newest first:  NAME<TAB>"<turns> turns · <topic>".
set -u
[ "${1:-}" = --describe ] && { printf 'sessions\tList existing sessions (newest first) as NAME<TAB>LABEL.\n'; exit 0; }
_d=${HARSH_SESSIONS_DIR}
[ -d "${_d}" ] || exit 0
for _m in "${_d}"/*/manifest.csv; do
  [ -f "${_m}" ] || continue
  _sdir=$(dirname "${_m}"); _name=$(basename "${_sdir}")
  # Count non-empty manifest lines (turns). grep -c exits 1 on no match.
  _turns=$(grep -c . "${_m}" 2>/dev/null); _turns=${_turns:-0}
  # First user entry's file → the session "topic" (pure shell, no awk).
  _tf=""
  # shellcheck disable=SC2034
  while IFS=, read -r _seq _role _type _tname _file _ts _status; do
    [ "${_role}" = user ] && { _tf=${_file}; break; }
  done < "${_m}"
  _topic=""
  if [ -n "${_tf}" ] && [ -f "${_sdir}/${_tf}" ]; then
    _topic=$(jq -r '.block.text // ""' "${_sdir}/${_tf}" 2>/dev/null \
              | tr '\n\t' '  ' | sed 's/^ *//; s/ *$//' | cut -c1-80)
  fi
  [ -n "${_topic}" ] || _topic="(empty)"
  printf '%s\t%s turns · %s\n' "${_name}" "${_turns}" "${_topic}"
done | sort -r
