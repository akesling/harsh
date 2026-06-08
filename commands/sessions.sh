#!/usr/bin/env sh
# sessions — list existing sessions, newest first, one per line:
#
#     NAME<TAB>LABEL
#
# NAME is the resume key (field 1). LABEL is a ready-to-display string —
# "MM-DD HH:MM   <turns>t   <topic>" — already aligned, so both consumers (the
# REPL /sessions view and the TUI fzf picker, which shows fields 2..) render the
# same thing. The REPL only adds a left margin and a marker for the current one.
set -u
[ "${1:-}" = --describe ] && { printf 'sessions\tList existing sessions (newest first) as NAME<TAB>LABEL.\n'; exit 0; }
_d=${HARSH_SESSIONS_DIR}
[ -d "${_d}" ] || exit 0
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
  # NAME<TAB> then a single, aligned, ready-to-show label.
  _label=$(printf '%-11s %3st  %s' "${_when}" "${_turns}" "${_topic}")
  printf '%s\t%s\n' "${_name}" "${_label}"
done | sort -r
