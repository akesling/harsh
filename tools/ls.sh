#!/usr/bin/env sh
# ls tool — list a directory.
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"ls","description":"List the contents of a directory (long format).","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default current directory)."}},"required":[]}}
EOF
  exit 0
fi
_input=$(cat)
_path=$(printf '%s' "${_input}" | jq -r '.path // "."')
ls -la "${_path}" 2>&1
