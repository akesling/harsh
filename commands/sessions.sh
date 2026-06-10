#!/usr/bin/env sh
# sessions — list existing sessions, newest first.
#
# Two faces, one command: a human table when shown on a terminal (with the
# current session — HARSH_CURRENT_SESSION, set by the REPL — marked with ▸),
# and raw rows when piped:
#
#     NAME<TAB>LABEL
#
# NAME is the resume key (field 1). LABEL is a ready-to-display string —
# "MM-DD HH:MM   <turns>t   <topic>" — already aligned. Scripts read the piped
# rows; the REPL shows the table.
set -u
[ "${1:-}" = --describe ] && { printf 'sessions\tList existing sessions (newest first).\n'; exit 0; }
_d=${HARSH_SESSIONS_DIR}
[ -d "${_d}" ] || exit 0

# Emit NAME<TAB>LABEL rows, newest first. (A function so the case/glob below does
# not sit inside a command substitution, where the pattern ')' misparses.)
emit_rows() {
  for _m in "${_d}"/*/manifest.csv; do
    [ -f "${_m}" ] || continue
    _sdir=$(dirname "${_m}"); _name=$(basename "${_sdir}")
    # Count non-empty manifest lines (turns). grep -c exits 1 on no match.
    _turns=$(grep -c . "${_m}" 2>/dev/null); _turns=${_turns:-0}
    # The session "topic" is the first *typed* user message: walk user/text
    # entries and skip any injected SessionStart context (meta.context set).
    _tf=""
    # shellcheck disable=SC2034
    while IFS=, read -r _seq _role _type _tname _file _ts _status; do
      { [ "${_role}" = user ] && [ "${_type}" = text ]; } || continue
      [ -f "${_sdir}/${_file}" ] || continue
      _ctx=$(jq -r '.meta.context // ""' "${_sdir}/${_file}" 2>/dev/null)
      [ -n "${_ctx}" ] && continue
      _tf=${_file}; break
    done < "${_m}"
    _topic=""
    if [ -n "${_tf}" ] && [ -f "${_sdir}/${_tf}" ]; then
      _topic=$(jq -r '.block.text // ""' "${_sdir}/${_tf}" 2>/dev/null \
                | tr '\n\t' '  ' | sed 's/^ *//; s/ *$//' | cut -c1-56)
    fi
    [ -n "${_topic}" ] || _topic="(no prompt yet)"
    # Compact start time from the session name (sess-YYYYMMDD-HHMMSS): drop the
    # year — the NAME still carries the full timestamp for anyone who needs it.
    _when="${_name}"
    case "${_name}" in
      *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*)
        _hms=${_name##*-}                   # HHMMSS
        _ymd=${_name%-*}; _ymd=${_ymd##*-}  # YYYYMMDD
        _when=$(printf '%s-%s %s:%s' \
          "$(echo "${_ymd}" | cut -c5-6)" "$(echo "${_ymd}" | cut -c7-8)" \
          "$(echo "${_hms}" | cut -c1-2)" "$(echo "${_hms}" | cut -c3-4)") ;;
    esac
    _label=$(printf '%-11s %3st  %s' "${_when}" "${_turns}" "${_topic}")
    printf '%s\t%s\n' "${_name}" "${_label}"
  done | sort -r
}

_all=$(emit_rows)
if [ -t 1 ]; then
  [ -n "${_all}" ] || { printf '(no sessions yet)\n'; exit 0; }
  _cur=""; [ -n "${HARSH_CURRENT_SESSION:-}" ] && _cur=$(basename "${HARSH_CURRENT_SESSION}")
  printf '  %-11s %3s  %s\n' 'STARTED' 'TRN' 'TOPIC / SESSION'
  printf '%s\n' "${_all}" | while IFS='	' read -r _name _label; do
    if [ "${_name}" = "${_cur}" ]; then _mark='▸'; else _mark=' '; fi
    printf '%s %s  %s\n' "${_mark}" "${_label}" "${_name}"
  done
else
  printf '%s\n' "${_all}"
fi
