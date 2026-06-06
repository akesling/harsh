#!/usr/bin/env sh
# agent tool — delegate a task to a sub-agent and return only its final message.
#
# A sub-agent is just harsh re-invoking itself: this tool creates a fresh child
# session, runs the task there to completion (its own tool-using loop), and
# returns the child's final assistant message. The parent's context stays clean
# — it sees the summary, not the child's intermediate steps. This needs no
# special support in harsh.sh beyond the exported HARSH_SELF / HARSH_CONFIG, so
# the child runs with the very same configuration (tools, hooks, model, dirs).
# Dependencies: jq (+ the shell). No awk, no extra tools.
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"agent","description":"Delegate a self-contained task to a sub-agent. It runs its own tool-using loop in a fresh session and returns only its final summary, so intermediate steps stay out of this conversation. Use it for focused sub-tasks (research a question, refactor a file, draft a section). The sub-agent does NOT see this conversation — put everything it needs in 'task'.","input_schema":{"type":"object","properties":{"task":{"type":"string","description":"The complete, self-contained task/prompt for the sub-agent."},"label":{"type":"string","description":"Optional short slug used in the child session name (a-z, 0-9, -, _)."}},"required":["task"]}}
EOF
  exit 0
fi

[ -n "${HARSH_SELF:-}" ] || { echo "error: HARSH_SELF is not set (the agent tool must be run under harsh)"; exit 1; }

# Recursion guard: refuse once we hit the depth cap, so sub-agents (which can
# themselves call this tool) cannot recurse forever. The depth rides along in
# the environment, inherited by every descendant.
depth=${HARSH_AGENT_DEPTH:-0}
max=${HARSH_AGENT_MAX_DEPTH:-3}
case "$depth" in *[!0-9]*|'') depth=0 ;; esac
case "$max"   in *[!0-9]*|'') max=3   ;; esac
if [ "$depth" -ge "$max" ]; then
  printf 'error: sub-agent depth limit reached (%s); refusing to spawn another.\n' "$max"
  exit 1
fi

input=$(cat)
task=$(printf '%s' "$input" | jq -r '.task // empty')
[ -n "$task" ] || { echo "error: missing 'task'"; exit 1; }
label=$(printf '%s' "$input" | jq -r '.label // empty')
case "$label" in *[!A-Za-z0-9_-]*|'') label="task" ;; esac

# A unique, inspectable child session name (no random/awk deps). Children live
# alongside normal sessions under HARSH_SESSIONS_DIR, prefixed so they stand out.
child="agent-$label-$(date -u +%Y%m%d-%H%M%S)-$$"

# The child inherits an incremented depth (so any agents IT spawns count up).
HARSH_AGENT_DEPTH=$((depth + 1)); export HARSH_AGENT_DEPTH

# Create the child session and run the task. Child output is discarded — the
# result is read back off disk via `final` so only the summary reaches the parent.
sh "$HARSH_SELF" new "$child" >/dev/null 2>&1 || { echo "error: could not create sub-session"; exit 1; }

errf=$(mktemp 2>/dev/null || printf '/tmp/harsh_agent.%s' "$$")
if ! sh "$HARSH_SELF" -q ask "$child" "$task" >/dev/null 2>"$errf"; then
  printf 'sub-agent run failed: %s\n' "$(cat "$errf" 2>/dev/null)"
  rm -f "$errf"
  exit 1
fi
rm -f "$errf"

result=$(sh "$HARSH_SELF" final "$child")
if [ -n "$result" ]; then
  printf '%s\n' "$result"
else
  printf '(sub-agent produced no final message; inspect session %s)\n' "$child"
fi
