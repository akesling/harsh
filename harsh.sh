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

# Shared presentation helpers (palette + fmt_markdown), used to give the REPL
# the same look as the TUI. Optional: the core stays fully functional without
# it, so we guard the source and provide inert fallbacks when it's absent.
if [ -f "$SELF_DIR/lib/render.sh" ]; then
  # shellcheck disable=SC1091
  . "$SELF_DIR/lib/render.sh"
else
  # Inert palette/format fallbacks for when lib/render.sh is absent. Markdown-only
  # colors (e.g. italic) are omitted here: they're used solely by render.sh's
  # fmt_markdown, which self-defines them; the fallback fmt_markdown is plain cat.
  C_DIM=; C_RST=; C_USER=; C_AI=; C_TOOL=; C_BAR=; C_GUT=; C_RES=; GUTTER='|'
  fmt_markdown() { cat; }
  speaker() { printf '%s %s\n' "$GUTTER" "$1"; }
  gutter()  { sed "s/^/$GUTTER /"; }
  body()    { sed 's/^/  /'; }
  tool_oneline() { printf '%s %s\n' "$1" "$2"; }
fi

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
  # Extensible CLI commands and the shared render lib (defaults sit next to
  # harsh.sh). Derived commands live in HARSH_COMMANDS_DIR as drop-in scripts.
  : "${HARSH_COMMANDS_DIR:=$SELF_DIR/commands}"
  : "${HARSH_LIB_DIR:=$SELF_DIR/lib}"
  : "${HARSH_SYSTEM_PROMPT:=You are harsh, a concise and capable coding agent operating through a portable shell harness. Use the provided tools to inspect and modify the project. Prefer small, verifiable steps. When done, stop.}"
  HARSH_API_KEY=${HARSH_API_KEY:-${ANTHROPIC_API_KEY:-}}
  # Expose the harness itself and the resolved config to tool subprocesses, so a
  # tool (e.g. tools/agent.sh) can re-invoke harsh for a sub-session with the
  # exact same configuration. HARSH_CONFIG is pinned to the file actually loaded
  # so a child re-resolves identically instead of re-discovering a different one.
  HARSH_SELF="$SELF_DIR/harsh.sh"
  HARSH_CONFIG=$CONFIG_FILE
  export HARSH_MODEL HARSH_MAX_TOKENS HARSH_API_URL HARSH_API_VERSION \
         HARSH_TOOLS_DIR HARSH_SKILLS_DIR HARSH_SESSIONS_DIR HARSH_LOG_DIR \
         HARSH_HOOKS_DIR HARSH_COMMANDS_DIR HARSH_LIB_DIR \
         HARSH_MAX_TURNS HARSH_SYSTEM_PROMPT HARSH_API_KEY \
         HARSH_SELF HARSH_CONFIG HARSH_VERSION
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

# Locate a command by name on a given SURFACE and print its script path (else
# return 1). A command at the top level of $HARSH_COMMANDS_DIR is available on
# every surface; one inside the SURFACE subdir (cli/ or repl/) is available only
# there — placement is the declaration, the same way hooks narrow scope with a
# subdirectory. Names are sanitized to forbid path traversal.
resolve_command() {
  surface=$1
  safe=$(printf '%s' "$2" | tr -cd 'A-Za-z0-9_-')
  [ -n "$safe" ] || return 1
  for p in "$HARSH_COMMANDS_DIR/$safe.sh" "$HARSH_COMMANDS_DIR/$surface/$safe.sh"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Run a command on the repl surface (top level + repl/). REPL convenience.
run_command() {
  p=$(resolve_command repl "$1") || return 127
  shift
  sh "$p" "$@"
}

# Print "NAME<TAB>description" (via --describe) for the top level plus the SURFACE
# subdir. Default cli — the CLI sees top-level + cli/ commands; pass repl for the
# REPL/TUI set (top-level + repl/).
list_commands() {
  surface=${1:-cli}
  for d in "$HARSH_COMMANDS_DIR" "$HARSH_COMMANDS_DIR/$surface"; do
    [ -d "$d" ] || continue
    for c in "$d"/*.sh; do
      [ -f "$c" ] || continue
      sh "$c" --describe 2>/dev/null || printf '%s\t(no description)\n' "$(basename "$c" .sh)"
    done
  done
}

# True if the command at PATH takes a SESSION as its first argument — read from
# its --describe usage, so the REPL can fill in the current session for
# session-scoped commands (e.g. /show) while leaving session-less ones alone.
command_wants_session() {
  case " $(sh "$1" --describe 2>/dev/null | cut -f1) " in *' SESSION'*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# commands (engine primitives; derived commands live in $HARSH_COMMANDS_DIR)
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
      text)
        if [ -z "${HARSH_QUIET:-}" ]; then
          # Skip empty prose blocks the model sometimes emits alongside a tool
          # call — they'd render as a bare "harsh" header with nothing under it.
          txt=$(printf '%s' "$block" | jq -r '.text')
          if [ -n "$(printf '%s' "$txt" | tr -d '[:space:]')" ]; then
            printf '%sharsh%s\n' "$C_AI" "$C_RST"
            printf '%s' "$txt" | fmt_markdown | body
            printf '\n'
          fi
        fi ;;
      tool_use)
        # The compact one-liner is printed after the call runs (with its result),
        # so we don't render anything here — see the tool_use loop below.
        : ;;
    esac
    i=$((i + 1))
  done

  stop=$(printf '%s' "$resp" | jq -r '.stop_reason // ""')
  if [ "$stop" = tool_use ]; then
    printf '%s' "$resp" | jq -c '.content[] | select(.type=="tool_use")' | while IFS= read -r tu; do
      id=$(printf '%s' "$tu"    | jq -r '.id')
      name=$(printf '%s' "$tu"  | jq -r '.name')
      input=$(printf '%s' "$tu" | jq -c '.input')
      # Compact one-line summary of this call, reused in the result line below.
      tool_summary=$(tool_oneline "$name" "$input")
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
        say "${C_TOOL}⛔ $name blocked by hook:${C_RST} $reason"
        out="Tool call blocked by hook: $reason"; err=true
      fi
      block=$(jq -nc --arg id "$id" --arg out "$out" --argjson e "$err" \
        '{type:"tool_result", tool_use_id:$id, content:$out, is_error:$e}')
      # The seq this entry will get is the handle users pass to /verbose to expand
      # this call's full output. Capture it before add_entry writes the file.
      rseq=$(next_seq "$dir")
      add_entry "$dir" user tool_result "$name" "$block"
      if [ -z "${HARSH_QUIET:-}" ]; then
        lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
        # One tidy line per call, tagged with its expandable handle:
        #   "#0007 • bash  git status → 4 lines"
        # The full output prints inline only on error or when HARSH_VERBOSE is set;
        # otherwise /verbose #0007 brings it back on demand.
        printf '%s#%s%s ' "$C_DIM" "$rseq" "$C_RST"
        printf '%s' "$tool_summary" | tr -d '\n'
        if [ "$err" = true ]; then
          printf '%s → error%s\n' "$C_TOOL" "$C_RST"
          printf '%s\n' "$out" | head -n 8 | gutter "$C_GUT" "$C_RES"
          [ "$lines" -gt 8 ] && printf '  %s… +%s more lines (/verbose #%s)%s\n' \
            "$C_DIM" "$((lines - 8))" "$rseq" "$C_RST"
        else
          printf '%s → %s line%s%s\n' \
            "$C_DIM" "$lines" "$( [ "$lines" = 1 ] || printf s )" "$C_RST"
          # Full firehose when globally verbose.
          if [ -n "${HARSH_VERBOSE:-}" ]; then
            printf '%s\n' "$out" | gutter "$C_GUT" "$C_RES"
          fi
        fi
      fi
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
          say "${C_DIM}↻ continuing (Stop hook):${C_RST} $reason"
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
REPL:
  <text>           send a message to the agent and run
  /SKILL [args]    invoke a skill (e.g. /commit, /review)
  /verbose         toggle full tool output;  /verbose #SEQ  expand one entry
  /session         print this session's directory
  /sessions        list past sessions;  /resume <ID>  switch
  /new             start a fresh session
  /help            this help;  /quit  exit (or Ctrl-D)

Commands (type as /NAME — SESSION is filled in automatically):
EOF
  list_commands repl | sort | sed 's/^/  \//'
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
    printf '%s╶─ harsh %s · REPL · %s ─╴%s\n' "$C_BAR" "$HARSH_VERSION" "$sess" "$C_RST" >&2
    printf '%sType a message and press Enter. /help for commands, /quit to exit.%s\n' "$C_DIM" "$C_RST" >&2
    if [ -z "$HARSH_API_KEY" ] && [ -z "${HARSH_MOCK:-}" ]; then
      printf '! No API key set — the agent cannot respond. Export ANTHROPIC_API_KEY,\n' >&2
      printf '! or set HARSH_MOCK=1 for an offline mock model.\n' >&2
    fi
  fi
  while :; do
    [ "$tty" = 1 ] && printf '%sharsh>%s ' "$C_USER" "$C_RST" >&2
    IFS= read -r line || break
    case "$line" in
      '') continue ;;
      /quit|/exit|/q) break ;;
      /help)    repl_help >&2 ;;
      /verbose|/v)
        # No arg: toggle global verbose (every tool result prints in full).
        if [ -n "${HARSH_VERBOSE:-}" ]; then
          HARSH_VERBOSE=; printf '%s[verbose off]%s\n' "$C_DIM" "$C_RST" >&2
        else
          HARSH_VERBOSE=1; printf '%s[verbose on]%s\n' "$C_DIM" "$C_RST" >&2
        fi ;;
      '/verbose '*|'/v '*)
        # With a #SEQ arg: expand that one entry without changing the mode.
        run_command verbose "$sess" "${line#* }" ;;
      /session) printf '%s\n' "$dir" ;;
      /sessions|/ls)
        # NAME<TAB>LABEL → an indented, readable list.
        run_command sessions | sed 's/^/  /' >&2
        [ "$tty" = 1 ] && printf '%sUse /resume <ID> to switch.%s\n' "$C_DIM" "$C_RST" >&2 ;;
      '/resume '*|'/switch '*)
        target=${line#* }
        tdir=$(session_dir "$target")
        if [ -d "$tdir" ] && [ -f "$tdir/manifest.csv" ]; then
          dir=$tdir; sess=$dir
          [ "$tty" = 1 ] && printf '%s[resumed: %s]%s\n' "$C_DIM" "$sess" "$C_RST" >&2
          run_command show "$sess"
        else
          printf 'no such session: %s\n' "$target" >&2
        fi ;;
      /resume|/switch)
        printf 'usage: /resume <session ID>  (see /sessions)\n' >&2 ;;
      /new)
        dir=$(cmd_init); sess=$dir
        [ "$tty" = 1 ] && printf '[new session: %s]\n' "$sess" >&2 ;;
      /*)
        # Any commands/ verb is reachable as /NAME; the current session is filled
        # in for session-scoped ones. Otherwise fall back to a skill of that name.
        name=${line#/}; rest=""
        case "$name" in *' '*) rest=${name#* }; name=${name%% *} ;; esac
        if p=$(resolve_command repl "$name"); then
          if command_wants_session "$p"; then
            # shellcheck disable=SC2086  # split rest into positional args
            sh "$p" "$sess" $rest
          else
            # shellcheck disable=SC2086
            sh "$p" $rest
          fi
        elif resolve_command cli "$name" >/dev/null 2>&1; then
          printf '%s/%s is a CLI-only command — run: harsh.sh %s …%s\n' \
            "$C_DIM" "$name" "$name" "$C_RST" >&2
        else
          cmd_skill "$sess" "$name" "$rest"
        fi ;;
      *)
        # No prompt echo: the user just typed it at the "harsh>" line directly
        # above, so repeating it only adds noise. A blank line sets the reply off.
        [ "$tty" = 1 ] && printf '\n' >&2
        cmd_send "$sess" "$line" && cmd_run "$sess" ;;
    esac
  done
  [ "$tty" = 1 ] && printf '%s%s harsh · bye%s\n' "$C_DIM" "$GUTTER" "$C_RST" >&2
  return 0
}

usage() {
  cat <<EOF
harsh $HARSH_VERSION — a portable shell agent harness

Usage: harsh.sh [-c CONFIG] [-q] [COMMAND [ARGS...]]

With no command, harsh.sh starts an interactive REPL.

Interactive:
  repl [SESSION]         Line-based REPL (default when no command is given).
  tui [SESSION]          Launch the fzf chat TUI (harsh_tui.sh).

Engine primitives (built in):
  init|new [NAME]        Create a session; prints its directory.
  send SESSION TEXT...   Append a user message.
  step SESSION           Run one model turn (executes tools if requested).
  run SESSION            Run the agent loop to completion.
  ask SESSION TEXT...    send + run in one go.
  skill SESSION NAME [A] Load a skill and run it.
  assemble SESSION       Print the Messages-API messages[] array.
  path SESSION           Print the resolved session directory.

Commands (extensible — drop a NAME.sh into \$HARSH_COMMANDS_DIR):
EOF
  list_commands | sort | sed 's/^/  /'
  cat <<EOF

Environment / config (see harsh.conf):
  HARSH_API_KEY / ANTHROPIC_API_KEY, HARSH_MODEL, HARSH_MAX_TOKENS,
  HARSH_SYSTEM_PROMPT, HARSH_MAX_TURNS, HARSH_MOCK (offline test mode),
  HARSH_VERBOSE (print full tool output instead of a collapsed summary).
  Directories (set in harsh.conf, absolute): HARSH_TOOLS_DIR, HARSH_SKILLS_DIR,
  HARSH_HOOKS_DIR, HARSH_COMMANDS_DIR, HARSH_SESSIONS_DIR, HARSH_LOG_DIR.
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
  # --- engine primitives (in-process; reserved, never shadowed) -------------
  repl)     cmd_repl "$@" ;;
  tui)      exec sh "$SELF_DIR/harsh_tui.sh" "$@" ;;
  init|new) cmd_init "$@" ;;
  send)     cmd_send "$@" ;;
  step)     cmd_step "$@" ;;
  run)      cmd_run "$@" ;;
  ask)      cmd_ask "$@" ;;
  skill)    cmd_skill "$@" ;;
  assemble) cmd_assemble "$@" ;;
  path)     cmd_path "$@" ;;
  # --- meta -----------------------------------------------------------------
  commands) list_commands "$@" | sort ;;
  help|-h|--help) usage ;;
  # --- everything else: an extensible command from $HARSH_COMMANDS_DIR ------
  *)
    if p=$(resolve_command cli "$cmd"); then
      exec sh "$p" "$@"
    fi
    die "unknown command: $cmd (try: harsh.sh help)" ;;
esac