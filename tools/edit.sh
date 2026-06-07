#!/usr/bin/env sh
# edit tool — literal string replacement in a file.
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"edit","description":"Replace an exact string in a file. By default the old string must be unique; set all=true to replace every occurrence.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file."},"old":{"type":"string","description":"Exact text to find."},"new":{"type":"string","description":"Replacement text."},"all":{"type":"boolean","description":"Replace all occurrences (default false)."}},"required":["path","old","new"]}}
EOF
  exit 0
fi
_input=$(cat)
_path=$(printf '%s' "${_input}" | jq -r '.path // empty')
[ -n "${_path}" ] || { echo "error: missing 'path'"; exit 1; }
[ -f "${_path}" ] || { echo "error: no such file: ${_path}"; exit 1; }

_errf=$(mktemp 2>/dev/null || echo /tmp/harsh_edit.$$)
# Read the file raw (-Rs), split on the literal old string, rejoin. jq's
# split/join are literal (not regex), which keeps this safe for any content.
_result=$(jq -Rsr --argjson in "${_input}" '
  ($in.old) as $old | ($in.new) as $new | ($in.all // false) as $all |
  (split($old)) as $p | ($p | length - 1) as $count |
  if $count == 0 then error("old string not found in file")
  elif ($all | not) and $count > 1
    then error("old string is not unique (" + ($count|tostring) + " matches); set all=true or add context")
  elif $all then ($p | join($new))
  else ($p[0] + $new + ($p[1:] | join($old))) end
' "${_path}" 2>"${_errf}")
_rc=$?
if [ "${_rc}" -ne 0 ]; then
  echo "error: $(sed 's/^jq: error.*: //' "${_errf}")"
  rm -f "${_errf}"
  exit 1
fi
rm -f "${_errf}"
printf '%s' "${_result}" > "${_path}"
echo "edited ${_path}"
