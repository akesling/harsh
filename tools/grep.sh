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
if command -v rg >/dev/null 2>&1; then
  rg -n --color=never -- "${_pat}" "${_path}" 2>&1 | head -n 200
else
  grep -rn -- "${_pat}" "${_path}" 2>&1 | head -n 200
fi
