#!/usr/bin/env sh
# grep tool — search files for a pattern (ripgrep if available, else grep).
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"grep","description":"Search files recursively for a regular-expression pattern. Returns matching lines with file:line prefixes.","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for."},"path":{"type":"string","description":"File or directory to search (default current directory)."}},"required":["pattern"]}}
EOF
  exit 0
fi
_input=$(cat)
_pat=$(printf '%s' "${_input}" | jq -r '.pattern // empty')
[ -n "${_pat}" ] || { echo "error: missing 'pattern'"; exit 1; }
_path=$(printf '%s' "${_input}" | jq -r '.path // "."')
# Cap output, but say so when the cap bites — a silent cut would let the model
# believe it saw every match.
_cap=200
if command -v rg >/dev/null 2>&1; then
  _res=$(rg -n --color=never -- "${_pat}" "${_path}" 2>&1 | head -n $((_cap + 1)))
else
  _res=$(grep -rn -- "${_pat}" "${_path}" 2>&1 | head -n $((_cap + 1)))
fi
[ -n "${_res}" ] || exit 0
_n=$(printf '%s\n' "${_res}" | wc -l | tr -d ' ')
if [ "${_n}" -gt "${_cap}" ]; then
  printf '%s\n' "${_res}" | head -n "${_cap}"
  printf '... (truncated at %s lines; narrow the pattern or path)\n' "${_cap}"
else
  printf '%s\n' "${_res}"
fi
