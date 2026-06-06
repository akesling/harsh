#!/usr/bin/env sh
# grep tool — search files for a pattern (ripgrep if available, else grep).
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"grep","description":"Search files recursively for a regular-expression pattern. Returns matching lines with file:line prefixes.","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for."},"path":{"type":"string","description":"File or directory to search (default current directory)."}},"required":["pattern"]}}
EOF
  exit 0
fi
input=$(cat)
pat=$(printf '%s' "$input" | jq -r '.pattern // empty')
[ -n "$pat" ] || { echo "error: missing 'pattern'"; exit 1; }
path=$(printf '%s' "$input" | jq -r '.path // "."')
if command -v rg >/dev/null 2>&1; then
  rg -n --color=never -- "$pat" "$path" 2>&1 | head -n 200
else
  grep -rn -- "$pat" "$path" 2>&1 | head -n 200
fi
