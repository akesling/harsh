#!/usr/bin/env sh
# read tool — print a file with line numbers, optionally sliced.
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"read","description":"Read a text file and return its contents with line numbers. Supports optional offset (1-based start line) and limit (max lines).","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file."},"offset":{"type":"integer","description":"1-based line to start at (default 1)."},"limit":{"type":"integer","description":"Maximum number of lines (default: all)."}},"required":["path"]}}
EOF
  exit 0
fi
input=$(cat)
path=$(printf '%s' "$input" | jq -r '.path // empty')
[ -n "$path" ] || { echo "error: missing 'path'"; exit 1; }
[ -f "$path" ] || { echo "error: no such file: $path"; exit 1; }
off=$(printf '%s' "$input" | jq -r '.offset // 1')
lim=$(printf '%s' "$input" | jq -r '.limit // 0')
awk -v o="$off" -v l="$lim" '
  NR >= o { printf "%6d\t%s\n", NR, $0; n++; if (l > 0 && n >= l) exit }
' "$path"
