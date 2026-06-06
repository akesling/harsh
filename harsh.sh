#!/usr/bin/env sh
# harsh — a portable shell agent harness.
#
# The core. Fully functional on its own. Drives an LLM agent loop over a
# session directory of one-file-per-entry conversation state plus a
# manifest.csv of lightweight metadata. Maximum dependencies: jq, curl, and a
# bash-like shell (bash, zsh, and ash are all supported).
#
# Usage: harsh.sh [-c CONFIG] [-q] COMMAND [ARGS...]
# See `harsh.sh help`.

set -u
# Make zsh behave like a POSIX shell when invoked as `zsh harsh.sh`.
if [ -n "${ZSH_VERSION:-}" ]; then
  emulate sh 2>/dev/null || setopt sh_word_split 2>/dev/null || true
fi

HARSH_VERSION=0.1.0
# SELF_DIR locates the harsh checkout (for the repo-local config and sibling
# scripts like harsh_tui.sh). The data directories themselves are NOT inferred
# from it — they come from the config (see load_config / harsh.conf). An
# installed `ha` points at its config via HARSH_CONFIG, so directory discovery
# never depends on how harsh was invoked.
SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
CONFIG_FILE=""

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
die()  { printf 'harsh: %s\n' "$*" >&2; exit 1; }
say()  { [ -n "${HARSH_QUIET:-}" ] || printf '%s\n' "$*"; }
# warn() goes to stderr — use it for diagnostics inside functions whose stdout
# is captured by command substitution (e.g. call_api), so the message reaches
# the user instead of being swallowed into the captured value.
warn() { printf '%s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

load_config() {
  # SELF_DIR is exported so config files can reference it explicitly, e.g.
  #   HARSH_TOOLS_DIR="$SELF_DIR/tools"
  export SELF_DIR
  cfg=${HARSH_CONFIG:-}
  if [ -z "$cfg" ]; then
    for c in ./harsh.conf "$SELF_DIR/harsh.conf" "$HOME/.config/harsh/harsh.conf"; do
      [ -f "$c" ] && { cfg=$c; break; }
    done
  fi
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    # shellcheck disable=SC1090
    . "$cfg"
    CONFIG_FILE=$cfg
  fi
  : "${HARSH_MODEL:=claude-opus-4-8}"
  : "${HARSH_MAX_TOKENS:=4096}"
  : "${HARSH_API_URL:=https://api.anthropic.com/v1/messages}"
  : "${HARSH_API_VERSION:=2023-06-01}"
  # Directories are not inferred: they must be set explicitly, either in the
  # config file or the environment. The shipped harsh.conf sets them.
  for v in HARSH_TOOLS_DIR HARSH_SKILLS_DIR HARSH_SESSIONS_DIR HARSH_LOG_DIR; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || die "$v is not set; define it in $cfg (see harsh.conf)"
  done
  : "${HARSH_MAX_TURNS:=127}"
  # Hooks are optional: if the directory is absent, run_hooks is a no-op. The
  # default sits next to the other dirs, but nothing breaks if it doesn't exist.
  : "${HARSH_HOOKS_DIR:=$SELF_DIR/hooks}"
  : "${HARSH_SYSTEM_PROMPT:=You are harsh, a concise and capable coding agent operating through a portable shell harness. Use the provided tools to inspect and modify the project. Prefer small, verifiable steps. When done, stop.}"
  HARSH_API_KEY=${HARSH_API_KEY:-${ANTHROPIC_API_KEY:-}}
  export HARSH_MODEL HARSH_MAX_TOKENS HARSH_API_URL HARSH_API_VERSION \
         HARSH_TOOLS_DIR HARSH_SKILLS_DIR HARSH_SESSIONS_DIR HARSH_LOG_DIR \
         HARSH_HOOKS_DIR HARSH_MAX_TURNS HARSH_SYSTEM_PROMPT HARSH_API_KEY
  have jq || die "jq is required"
}

# Resolve a session argument (a bare name -> under sessions dir; a path -> as is)
session_dir() {
  s=$1
  case "$s" in
    /*|./*|../*|*/*) printf '%s' "$s" ;;
    *)              printf '%s/%s' "$HARSH_SESSIONS_DIR" "$s" ;;
  esac
}

# Next zero-padded sequence number for a session directory.
next_seq() {
  dir=$1
  n=0
  for f in "$dir"/[0-9]*.json; do
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%04d' $((n + 1))
}

# Append a conversation entry: one file holding {role, block} plus a manifest line.
#   add_entry DIR ROLE TYPE NAME BLOCK_JSON
add_entry() {
  dir=$1; role=$2; type=$3; name=$4; block=$5
  seq=$(next_seq "$dir")
  if [ -n "$name" ]; then
    safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')
    file="$seq-$role-$type-$safe.json"
  else
    file="$seq-$role-$type.json"
  fi
  jq -nc --arg role "$role" --argjson block "$block" '{role:$role,block:$block}' \
    > "$dir/$file" || die "failed to write entry (invalid block json)"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$seq" "$role" "$type" "$name" "$file" "$ts" "ok" \
    >> "$dir/manifest.csv"
}

# run_hooks EVENT PAYLOAD_JSON [TOOL]
# Runs every hook (*.sh) under $HARSH_HOOKS_DIR/$EVENT — and, when TOOL is given,
# also under $HARSH_HOOKS_DIR/$EVENT/$TOOL — in sorted order, feeding PAYLOAD_JSON
# on stdin (the same contract as Claude Code hooks).
#   exit 2      -> BLOCK: the hook's stdout is the reason; run_hooks prints it
#                  and returns 2 (no further hooks run).
#   exit 0      -> allow: stdout is collected as context.
#   other       -> non-blocking error: logged to $HARSH_LOG_DIR/hooks.log, ignored.
# On allow, run_hooks prints the collected context and returns 0.
run_hooks() {
  event=$1; payload=$2; tool=${3:-}
  base="$HARSH_HOOKS_DIR/$event"
  ctx=""
  mkdir -p "$HARSH_LOG_DIR" 2>/dev/null || true
  # Scan the event dir (runs for everything), then the tool-specific subdir.
  for d in "$base" "${tool:+$base/$tool}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    for h in "$d"/*.sh; do
      [ -f "$h" ] || continue
      out=$(printf '%s' "$payload" | sh "$h" 2>>"$HARSH_LOG_DIR/hooks.log"); rc=$?
      case $rc in
        0) [ -n "$out" ] && ctx="$ctx$out
" ;;
        2) printf '%s' "$out"; return 2 ;;
        *) warn "[hook] $event/$(basename "$h") exited $rc (ignored)" ;;
      esac
    done
  done
  printf '%s' "$ctx"
  return 0
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
cmd_init() {
  name=${1:-sess-$(date -u +%Y%m%d-%H%M%S)}
  dir=$(session_dir "$name")
  fresh=0
  [ -d "$dir" ] || fresh=1
  mkdir -p "$dir"
  [ -f "$dir/manifest.csv" ] || : > "$dir/manifest.csv"
  # SessionStart fires once per new session. Its output (if any) is injected as
  # opening context — captured here so it never reaches stdout, which is the
  # session directory path the callers consume.
  if [ "$fresh" = 1 ]; then
    hp=$(jq -nc --arg e SessionStart --arg s "$dir" '{event:$e,session_dir:$s}')
    hc=$(run_hooks SessionStart "$hp") || true
    [ -n "$hc" ] && add_entry "$dir" user text "" "$(jq -nc --arg t "$hc" '{type:"text",text:$t}')"
  fi
  printf '%s\n' "$dir"
}

cmd_path() { session_dir "$1"; }

# List existing sessions, newest first, one per line:
#   NAME \t LABEL    where LABEL = "<turns> turns · <topic>"
# Dependency-free (no fzf): a building block for scripts and the TUI picker.
cmd_sessions() {
  d=$HARSH_SESSIONS_DIR
  [ -d "$d" ] || return 0
  for m in "$d"/*/manifest.csv; do
    [ -f "$m" ] || continue
    sdir=$(dirname "$m"); name=$(basename "$sdir")
    # Count non-empty manifest lines (turns). grep -c exits 1 on no match,
    # so capture the count directly and default to 0.
    turns=$(grep -c . "$m" 2>/dev/null); turns=${turns:-0}
    # First user text block is the session's "topic".
    topic=""
    tf=$(awk -F, '$2=="user"{print $5; exit}' "$m" 2>/dev/null)
    if [ -n "$tf" ] && [ -f "$sdir/$tf" ]; then
      topic=$(jq -r '.block.text // ""' "$sdir/$tf" 2>/dev/null \
                | tr '\n\t' '  ' | sed 's/^ *//; s/ *$//' | cut -c1-80)
    fi
    [ -n "$topic" ] || topic="(empty)"
    printf '%s\t%s turns · %s\n' "$name" "$turns" "$topic"
  done | sort -r
}

cmd_send() {
  dir=$(session_dir "$1"); shift; text=$*
  [ -d "$dir" ] || die "no such session: $dir (run: harsh.sh init)"
  # UserPromptSubmit — a hook may reject the prompt (exit 2) or emit context that
  # is injected just before it (consecutive user blocks merge into one message).
  hp=$(jq -nc --arg e UserPromptSubmit --arg s "$dir" --arg p "$text" \
        '{event:$e,session_dir:$s,prompt:$p}')
  if ! hc=$(run_hooks UserPromptSubmit "$hp"); then
    warn "[blocked] prompt rejected by hook: $hc"
    return 1
  fi
  [ -n "$hc" ] && add_entry "$dir" user text "" "$(jq -nc --arg t "$hc" '{type:"text",text:$t}')"
  block=$(jq -nc --arg t "$text" '{type:"text",text:$t}')
  add_entry "$dir" user text "" "$block"
}

# Assemble the conversation files into a Messages-API `messages` array by
# grouping consecutive same-role blocks into one message.
cmd_assemble() {
  dir=$(session_dir "$1")
  set -- "$dir"/[0-9]*.json
  [ -e "$1" ] || { printf '[]'; return 0; }
  jq -s 'reduce .[] as $e ([];
      if (length > 0) and (.[-1].role == $e.role)
      then (.[0:-1] + [(.[-1] | .content += [$e.block])])
      else (. + [{role: $e.role, content: [$e.block]}])
      end)' "$@"
}

cmd_schemas() { sh "$HARSH_TOOLS_DIR/tool.sh" schemas; }

cmd_tools() {
  cmd_schemas | jq -r '.[] | "• " + .name + " — " + (.description // "")'
}

cmd_tool() { sh "$HARSH_TOOLS_DIR/tool.sh" call "$1"; }

cmd_manifest() { cat "$(session_dir "$1")/manifest.csv"; }

cmd_show() {
  dir=$(session_dir "$1")
  for f in "$dir"/[0-9]*.json; do
    [ -e "$f" ] || continue
    jq -r '.role as $r | .block as $b |
      "[" + $r + "/" + $b.type + "] " +
      (if $b.type=="text" then $b.text
       elif $b.type=="tool_use" then ($b.name + " " + ($b.input|tojson))
       elif $b.type=="tool_result" then ($b.content|tostring)
       else ($b|tojson) end)' "$f"
  done
}

# Conversation outline: one row per user *prompt*, each with a cheap summary of
# the response it produced. A derived view over the same entry files that
# `show`/`assemble` read — dependency-free (jq only, no fzf, no model call), so
# it works under HARSH_MOCK and in plain shell pipes.
#
# Output: TSV, one row per prompt:   SEQ \t PROMPT \t SUMMARY
#   SEQ      sequence number of the user/text entry (a jump target)
#   PROMPT   first line of the prompt, trimmed
#   SUMMARY  first line of the assistant's reply, or "ran N tool(s)" when the
#            turn was all tool calls, or "(no response)" if nothing followed.
cmd_outline() {
  dir=$(session_dir "$1")
  set -- "$dir"/[0-9]*.json
  [ -e "$1" ] || return 0
  # Tag each entry with its sequence (the filename's numeric prefix) so the
  # reduce below can carry a jump target, then group from each user/text prompt
  # up to (but not including) the next one.
  for f in "$@"; do
    seq=$(basename "$f"); seq=${seq%%-*}
    jq -c --arg seq "$seq" '{seq:$seq, role:.role, block:.block}' "$f"
  done | jq -rs '
    # Walk entries; start a new outline row at each user/text block, then fold
    # the following blocks into that row until the next prompt.
    reduce .[] as $e ([];
      if ($e.role=="user" and $e.block.type=="text")
      then . + [{seq:$e.seq, prompt:$e.block.text, replies:[], tools:0}]
      elif (length==0) then .   # skip anything before the first prompt
      else
        .[-1] as $cur |
        (.[0:-1]) + [
          if ($e.role=="assistant" and $e.block.type=="text")
          then ($cur | .replies += [$e.block.text])
          elif ($e.role=="assistant" and $e.block.type=="tool_use")
          then ($cur | .tools += 1)
          else $cur end
        ]
      end)
    | .[]
    | (.prompt | gsub("[\n\t]";" ") | gsub("^ +| +$";"")) as $p
    | (if (.replies | length) > 0
        then (.replies[0] | gsub("[\n\t]";" ") | gsub("^ +| +$";""))
       elif .tools > 0
        then "ran " + (.tools|tostring) + " tool" + (if .tools==1 then "" else "s" end)
       else "(no response)" end) as $s
    | [.seq, ($p[0:100]), ($s[0:100])] | @tsv'
}

cmd_skills() {
  d=$HARSH_SKILLS_DIR
  [ -d "$d" ] || { say "(no skills directory: $d)"; return 0; }
  base=$(basename "$d")
  for s in "$d"/*/SKILL.md "$d"/*.md; do
    [ -e "$s" ] || continue
    name=$(basename "$(dirname "$s")")
    [ "$name" = "$base" ] && name=$(basename "$s" .md)
    desc=$(sed -n 's/^description:[[:space:]]*//p' "$s" | head -n1)
    printf '/%s\t%s\n' "$name" "$desc"
  done
}

# List installed hooks, grouped by event:  EVENT<TAB>relative/path.sh
# A hook in EVENT/ runs for everything; one in EVENT/<tool>/ runs only for that
# tool call (e.g. PreToolUse/bash/ fires only before the bash tool).
cmd_hooks() {
  d=$HARSH_HOOKS_DIR
  [ -d "$d" ] || { say "(no hooks directory: $d)"; return 0; }
  found=0
  for evt in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do
    for h in "$d/$evt"/*.sh "$d/$evt"/*/*.sh; do
      [ -f "$h" ] || continue
      found=1
      printf '%s\t%s\n' "$evt" "${h#"$d/"}"
    done
  done
  [ "$found" = 0 ] && say "(no hooks installed in $d)"
  return 0
}

# Build the full request body for a session (debug aid).
cmd_request() {
  msgs=$(cmd_assemble "$1")
  tools=$(sh "$HARSH_TOOLS_DIR/tool.sh" schemas 2>/dev/null); [ -n "$tools" ] || tools='[]'
  jq -n --arg model "$HARSH_MODEL" --argjson max "$HARSH_MAX_TOKENS" \
        --arg sys "$HARSH_SYSTEM_PROMPT" --argjson tools "$tools" --argjson msgs "$msgs" \
        '{model:$model, max_tokens:$max, system:$sys, tools:$tools, messages:$msgs}'
}

# Call the model. Honors HARSH_MOCK for offline smoke testing.
call_api() {
  req=$1; dir=$2
  mkdir -p "$HARSH_LOG_DIR"
  base=$(basename "$dir")
  printf '%s\n' "$req" >> "$HARSH_LOG_DIR/$base.request.log"
  if [ -n "${HARSH_MOCK:-}" ]; then
    resp=$(mock_api "$req")
    printf '%s\n' "$resp" >> "$HARSH_LOG_DIR/$base.response.log"
    printf '%s' "$resp"
    return 0
  fi
  [ -n "$HARSH_API_KEY" ] || {
    warn "[error] no API key set — export ANTHROPIC_API_KEY (or HARSH_API_KEY), or set HARSH_MOCK=1 for offline testing."
    return 1
  }
  resp=$(printf '%s' "$req" | curl -sS -X POST "$HARSH_API_URL" \
      -H "x-api-key: $HARSH_API_KEY" \
      -H "anthropic-version: $HARSH_API_VERSION" \
      -H "content-type: application/json" \
      --data-binary @-) || { warn "[error] curl request to $HARSH_API_URL failed"; return 1; }
  printf '%s\n' "$resp" >> "$HARSH_LOG_DIR/$base.response.log"
  printf '%s' "$resp"
}

# Offline mock model: echoes text, or emits a tool call when the last user
# message contains a [[tool:NAME:ARG]] marker. Lets the loop be smoke-tested.
mock_api() {
  req=$1
  last=$(printf '%s' "$req" | jq -r '
    [.messages[] | select(.role=="user")] | (.[-1].content // []) |
    if type=="array" then (map(select(.type=="text").text) | join(" ")) else (.|tostring) end')
  case "$last" in
    *'[[tool:'*']]'*)
      spec=${last#*'[[tool:'}; spec=${spec%%']]'*}
      tname=${spec%%:*}; targs=${spec#*:}
      jq -n --arg n "$tname" --arg a "$targs" '{
        content:[
          {type:"text",text:("Calling tool " + $n)},
          {type:"tool_use",id:"toolu_mock1",name:$n,
           input:{command:$a,path:$a,pattern:$a,name:$a}}],
        stop_reason:"tool_use"}' ;;
    *)
      jq -n --arg t "[mock] You said: $last" '{content:[{type:"text",text:$t}],stop_reason:"end_turn"}' ;;
  esac
}

# One model turn. Appends assistant blocks; if the model asked for tools, runs
# them and appends tool_result blocks.
# returns: 0 = finished, 2 = tool_use (caller should continue), 1 = error.
cmd_step() {
  dir=$(session_dir "$1")
  [ -d "$dir" ] || die "no such session: $dir"
  msgs=$(cmd_assemble "$1")
  tools=$(sh "$HARSH_TOOLS_DIR/tool.sh" schemas 2>/dev/null); [ -n "$tools" ] || tools='[]'
  req=$(jq -n --arg model "$HARSH_MODEL" --argjson max "$HARSH_MAX_TOKENS" \
        --arg sys "$HARSH_SYSTEM_PROMPT" --argjson tools "$tools" --argjson msgs "$msgs" \
        '{model:$model, max_tokens:$max, system:$sys, tools:$tools, messages:$msgs}')
  resp=$(call_api "$req" "$dir") || return 1

  if [ "$(printf '%s' "$resp" | jq -r 'has("content")')" != "true" ]; then
    emsg=$(printf '%s' "$resp" | jq -r '.error.message // .message // "unknown API error"')
    warn "[error] $emsg"
    return 1
  fi

  n=$(printf '%s' "$resp" | jq '.content | length')
  i=0
  while [ "$i" -lt "$n" ]; do
    block=$(printf '%s' "$resp" | jq -c ".content[$i]")
    btype=$(printf '%s' "$block" | jq -r '.type')
    bname=$(printf '%s' "$block" | jq -r '.name // ""')
    add_entry "$dir" assistant "$btype" "$bname" "$block"
    case "$btype" in
      text)     say "🤖 $(printf '%s' "$block" | jq -r '.text')" ;;
      tool_use) say "🔧 $bname $(printf '%s' "$block" | jq -c '.input')" ;;
    esac
    i=$((i + 1))
  done

  stop=$(printf '%s' "$resp" | jq -r '.stop_reason // ""')
  if [ "$stop" = tool_use ]; then
    printf '%s' "$resp" | jq -c '.content[] | select(.type=="tool_use")' | while IFS= read -r tu; do
      id=$(printf '%s' "$tu"    | jq -r '.id')
      name=$(printf '%s' "$tu"  | jq -r '.name')
      input=$(printf '%s' "$tu" | jq -c '.input')
      # PreToolUse — a hook may deny the call (exit 2); its reason is fed back to
      # the model as the (error) tool_result, and the tool is not run.
      prepay=$(jq -nc --arg e PreToolUse --arg s "$dir" --arg n "$name" --argjson in "$input" \
                '{event:$e,session_dir:$s,tool_name:$n,tool_input:$in}')
      if reason=$(run_hooks PreToolUse "$prepay" "$name"); then
        out=$(printf '%s' "$input" | sh "$HARSH_TOOLS_DIR/tool.sh" call "$name" 2>&1); rc=$?
        if [ "$rc" -eq 0 ]; then err=false; else err=true; fi
        # PostToolUse — feedback (if any) is appended to the tool output.
        postpay=$(jq -nc --arg e PostToolUse --arg s "$dir" --arg n "$name" \
                  --argjson in "$input" --arg o "$out" --argjson er "$err" \
                  '{event:$e,session_dir:$s,tool_name:$n,tool_input:$in,tool_output:$o,is_error:$er}')
        fb=$(run_hooks PostToolUse "$postpay" "$name") || true
        [ -n "$fb" ] && out="$out
[hook] $fb"
      else
        say "⛔ $name blocked by hook: $reason"
        out="Tool call blocked by hook: $reason"; err=true
      fi
      say "📤 $name → $(printf '%s' "$out" | head -n 4)"
      block=$(jq -nc --arg id "$id" --arg out "$out" --argjson e "$err" \
        '{type:"tool_result", tool_use_id:$id, content:$out, is_error:$e}')
      add_entry "$dir" user tool_result "$name" "$block"
    done
    return 2
  fi
  return 0
}

# Run the agent loop to completion (or HARSH_MAX_TURNS).
cmd_run() {
  sess=$1
  dir=$(session_dir "$sess")
  turns=0; stops=0
  while [ "$turns" -lt "$HARSH_MAX_TURNS" ]; do
    cmd_step "$sess"; rc=$?
    turns=$((turns + 1))
    case $rc in
      0)
        # Stop — a hook may force another turn (exit 2) by injecting a message,
        # up to a small cap so it can't loop forever.
        if [ "$stops" -lt 3 ]; then
          sp=$(jq -nc --arg e Stop --arg s "$dir" '{event:$e,session_dir:$s}')
          if reason=$(run_hooks Stop "$sp"); then
            return 0
          fi
          stops=$((stops + 1))
          say "↻ continuing (Stop hook): $reason"
          add_entry "$dir" user text "" "$(jq -nc --arg t "$reason" '{type:"text",text:$t}')"
          continue
        fi
        return 0 ;;
      2) continue ;;
      *) return 1 ;;
    esac
  done
  say "[harsh] reached max turns ($HARSH_MAX_TURNS)"
}

# Send a user message then run to completion.
cmd_ask() {
  sess=$1; shift
  cmd_send "$sess" "$*" && cmd_run "$sess"
}

# Invoke a skill: load its instructions via the Skills tool, inject as a user
# message, and run. Backs slash commands in the TUI.
cmd_skill() {
  sess=$1; name=$2; shift 2 2>/dev/null || shift $#
  args=$*
  input=$(jq -nc --arg n "$name" --arg a "$args" '{name:$n,args:$a}')
  if ! content=$(printf '%s' "$input" | sh "$HARSH_TOOLS_DIR/tool.sh" call skills); then
    say "skill not found: $name"
    return 1
  fi
  msg=$(printf 'Please follow the "%s" skill below. Arguments: %s\n\n%s' "$name" "$args" "$content")
  cmd_send "$sess" "$msg" && cmd_run "$sess"
}

repl_help() {
  cat <<'EOF'
REPL commands:
  <text>           send a message to the agent and run
  /tools           list available tools
  /skills          list available skills
  /hooks           list installed hooks
  /SKILL [args]    invoke a skill (e.g. /commit, /review)
  /show            print the transcript so far
  /session         print this session's directory
  /new             start a fresh session
  /help            this help
  /quit            exit (or Ctrl-D)
EOF
}

# Default interactive mode: a dependency-free, line-based REPL. (harsh_tui.sh
# is the richer fzf interface; this needs nothing beyond the core.)
cmd_repl() {
  if [ "${1:-}" != "" ]; then
    sess=$1
    dir=$(session_dir "$sess")
    [ -d "$dir" ] || dir=$(cmd_init "$sess")
    sess=$dir
  else
    dir=$(cmd_init); sess=$dir
  fi
  tty=0; [ -t 0 ] && tty=1
  if [ "$tty" = 1 ]; then
    printf 'harsh %s — REPL · session %s\n' "$HARSH_VERSION" "$sess" >&2
    printf 'Type a message and press Enter. /help for commands, /quit to exit.\n' >&2
    if [ -z "$HARSH_API_KEY" ] && [ -z "${HARSH_MOCK:-}" ]; then
      printf '! No API key set — the agent cannot respond. Export ANTHROPIC_API_KEY,\n' >&2
      printf '! or set HARSH_MOCK=1 for an offline mock model.\n' >&2
    fi
  fi
  while :; do
    [ "$tty" = 1 ] && printf 'harsh> ' >&2
    IFS= read -r line || break
    case "$line" in
      '') continue ;;
      /quit|/exit|/q) break ;;
      /help)    repl_help >&2 ;;
      /tools)   cmd_tools ;;
      /skills)  cmd_skills ;;
      /hooks)   cmd_hooks ;;
      /show)    cmd_show "$sess" ;;
      /session) printf '%s\n' "$dir" ;;
      /new)
        dir=$(cmd_init); sess=$dir
        [ "$tty" = 1 ] && printf '[new session: %s]\n' "$sess" >&2 ;;
      /*)
        name=${line#/}; rest=""
        case "$name" in *' '*) rest=${name#* }; name=${name%% *} ;; esac
        cmd_skill "$sess" "$name" "$rest" ;;
      *)
        cmd_send "$sess" "$line" && cmd_run "$sess" ;;
    esac
  done
  [ "$tty" = 1 ] && printf '[harsh] bye\n' >&2
  return 0
}

usage() {
  cat <<EOF
harsh $HARSH_VERSION — a portable shell agent harness

Usage: harsh.sh [-c CONFIG] [-q] [COMMAND [ARGS...]]

With no command, harsh.sh starts an interactive REPL (the dependency-free
counterpart to harsh_tui.sh).

Interactive:
  repl [SESSION]         Line-based REPL (default when no command is given).
  tui [SESSION]          Launch the fzf chat TUI (harsh_tui.sh).

Sessions:
  init [NAME]            Create a session; prints its directory.
  new                    Alias for init.
  send SESSION TEXT...   Append a user message.
  step SESSION           Run one model turn (executes tools if requested).
  run SESSION            Run the agent loop to completion.
  ask SESSION TEXT...    send + run in one go.
  skill SESSION NAME [A] Load a skill and run it.

Inspection:
  assemble SESSION       Print the Messages-API messages[] array.
  request SESSION        Print the full request body that would be sent.
  manifest SESSION       Print the session manifest.csv.
  show SESSION           Print a readable transcript.
  outline SESSION        Print a prompt-by-prompt outline: SEQ<TAB>PROMPT<TAB>SUMMARY.
  path SESSION           Print the resolved session directory.
  sessions               List existing sessions (newest first) as NAME<TAB>LABEL.

Tools, skills & hooks:
  tools                  List available tools.
  schemas                Print the tools[] JSON array.
  tool NAME              Run a tool by name (JSON input on stdin).
  skills                 List available skills / slash commands.
  hooks                  List installed hooks, grouped by event.

Other:
  config                 Show effective configuration.
  version | help

Environment / config (see harsh.conf):
  HARSH_API_KEY / ANTHROPIC_API_KEY, HARSH_MODEL, HARSH_MAX_TOKENS,
  HARSH_SYSTEM_PROMPT, HARSH_MAX_TURNS, HARSH_MOCK (offline test mode).
  Directories must be set explicitly (no inference); the shipped harsh.conf
  defines them via $SELF_DIR (the directory containing harsh.sh):
  HARSH_TOOLS_DIR, HARSH_SKILLS_DIR, HARSH_SESSIONS_DIR, HARSH_LOG_DIR.
EOF
}

# ---------------------------------------------------------------------------
# entry
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -c) HARSH_CONFIG=$2; shift 2 ;;
    -q|--quiet) HARSH_QUIET=1; shift ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *)  break ;;
  esac
done
load_config

cmd=${1:-repl}; [ $# -gt 0 ] && shift
case "$cmd" in
  repl)     cmd_repl "$@" ;;
  tui)      exec sh "$SELF_DIR/harsh_tui.sh" "$@" ;;
  init)     cmd_init "$@" ;;
  new)      cmd_init "$@" ;;
  send)     cmd_send "$@" ;;
  step)     cmd_step "$@" ;;
  run)      cmd_run "$@" ;;
  ask)      cmd_ask "$@" ;;
  skill)    cmd_skill "$@" ;;
  assemble) cmd_assemble "$@" ;;
  request)  cmd_request "$@" ;;
  manifest) cmd_manifest "$@" ;;
  outline)  cmd_outline "$@" ;;
  sessions) cmd_sessions ;;
  show)     cmd_show "$@" ;;
  path)     cmd_path "$@" ;;
  tools)    cmd_tools ;;
  schemas)  cmd_schemas ;;
  tool)     cmd_tool "$@" ;;
  skills)   cmd_skills ;;
  hooks)    cmd_hooks ;;
  config)   printf 'config file: %s\n' "${CONFIG_FILE:-<defaults>}"; set | grep '^HARSH_' | grep -v API_KEY ;;
  version)  printf 'harsh %s\n' "$HARSH_VERSION" ;;
  help|-h|--help) usage ;;
  *)        die "unknown command: $cmd (try: harsh.sh help)" ;;
esac
