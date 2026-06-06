#!/usr/bin/env sh
# ls tool — list a directory.
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"ls","description":"List the contents of a directory (long format).","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default current directory)."}},"required":[]}}
EOF
  exit 0
fi
input=$(cat)
path=$(printf '%s' "$input" | jq -r '.path // "."')
ls -la "$path" 2>&1
