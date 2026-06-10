#!/usr/bin/env sh
# read tool — print a file with line numbers, optionally sliced.
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"read","description":"Read a text file and return its contents with line numbers. Supports optional offset (1-based start line) and limit (max lines).","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file."},"offset":{"type":"integer","description":"1-based line to start at (default 1)."},"limit":{"type":"integer","description":"Maximum number of lines (default: all)."}},"required":["path"]}}
EOF
  exit 0
fi
_input=$(cat)
_path=$(printf '%s' "${_input}" | jq -r '.path // empty')
[ -n "${_path}" ] || { echo "error: missing 'path'"; exit 1; }
[ -f "${_path}" ] || { echo "error: no such file: ${_path}"; exit 1; }
_off=$(printf '%s' "${_input}" | jq -r '.offset // 1')
_lim=$(printf '%s' "${_input}" | jq -r '.limit // 0')
# A bad offset/limit must be an error, not a silent empty read.
case "${_off}" in ''|*[!0-9]*) echo "error: offset must be a non-negative integer"; exit 1 ;; esac
case "${_lim}" in ''|*[!0-9]*) echo "error: limit must be a non-negative integer"; exit 1 ;; esac
[ "${_off}" -ge 1 ] || _off=1
# Number and slice in plain shell (no awk — see STYLE.md). `|| [ -n "$_l" ]`
# keeps a final line that lacks a trailing newline.
_n=0; _shown=0
while IFS= read -r _l || [ -n "${_l}" ]; do
  _n=$((_n + 1))
  [ "${_n}" -lt "${_off}" ] && continue
  printf '%6d\t%s\n' "${_n}" "${_l}"
  _shown=$((_shown + 1))
  if [ "${_lim}" -gt 0 ] && [ "${_shown}" -ge "${_lim}" ]; then
    break
  fi
done < "${_path}"
exit 0
