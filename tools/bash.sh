#!/usr/bin/env sh
# bash tool — run a shell command, return combined stdout+stderr.
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"bash","description":"Run a shell command in the working directory and return its combined stdout and stderr. Use for building, testing, git, and general file operations.","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute."},"timeout":{"type":"integer","description":"Optional timeout in seconds."}},"required":["command"]}}
EOF
  exit 0
fi
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.command // empty')
[ -n "$cmd" ] || { echo "error: missing 'command'"; exit 1; }
to=$(printf '%s' "$input" | jq -r '.timeout // empty')
if [ -n "$to" ] && command -v timeout >/dev/null 2>&1; then
  timeout "$to" sh -c "$cmd" 2>&1
else
  sh -c "$cmd" 2>&1
fi
