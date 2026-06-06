#!/usr/bin/env sh
# write tool — write content to a file (creating parent directories).
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"write","description":"Write text content to a file, overwriting it if it exists and creating parent directories as needed.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Path to write."},"content":{"type":"string","description":"Full file contents."}},"required":["path","content"]}}
EOF
  exit 0
fi
input=$(cat)
path=$(printf '%s' "$input" | jq -r '.path // empty')
[ -n "$path" ] || { echo "error: missing 'path'"; exit 1; }
dir=$(dirname "$path")
mkdir -p "$dir" || { echo "error: cannot create $dir"; exit 1; }
printf '%s' "$input" | jq -j '.content' > "$path" || { echo "error: write failed"; exit 1; }
echo "wrote $(wc -c < "$path" | tr -d ' ') bytes to $path"
