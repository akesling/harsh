#!/usr/bin/env sh
# harsh — a portable shell agent harness.
#
# The core harness is fully functional alone.  Sessions are directories of a
# file per turn/entry + a manifest.csv. Deps: jq, curl, a shell.
#
# Usage: harsh.sh [-c CONFIG] [-q] COMMAND [ARGS...]
# See `harsh.sh help`.

set -u
# Make zsh behave like a POSIX shell when invoked as `zsh harsh.sh`.
if [ -n "${ZSH_VERSION:-}" ]; then
  emulate sh 2>/dev/null || setopt sh_word_split 2>/dev/null || true
fi

HARSH_VERSION=0.2.0
# SELF_DIR locates the checkout (repo-local config, sibling scripts). Data
# directories are NOT inferred from it — they come from the config.
SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
_config_file=""

# Presentation lives in lib/render.sh so the REPL and `show` share one look. It is
# optional: when absent, these inert fallbacks keep harsh.sh fully usable on its
# own — just without color or markdown. They cover only what harsh.sh calls
# directly (the colors it prints, plus the two block renderers).
if [ -f "${SELF_DIR}/lib/render.sh" ]; then
  # shellcheck disable=SC1091
  . "${SELF_DIR}/lib/render.sh"
else
  C_DIM=; C_RST=; C_USER=; C_TOOL=; C_BAR=; GUTTER='|'
  render_assistant() {
    [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ] || return 0
    printf 'harsh\n'; printf '%s\n' "$1" | sed 's/^/  /'
  }
  render_tool_result() {
    printf '#%s %s %s\n' "$1" "$2" "$3"
    { [ "$5" = true ] || [ -n "${HARSH_VERBOSE:-}" ]; } && printf '%s\n' "$4" | sed 's/^/  /'
    return 0
  }
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
die()  { printf 'harsh: %s\n' "$*" >&2; exit 1; }
say()  { [ -n "${HARSH_QUIET:-}" ] || printf '%s\n' "$*"; }
# warn() → stderr, so diagnostics survive command substitution (e.g. call_api,
# whose stdout is captured by the caller).
warn() { printf '%s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
# jqv VALUE [jq-args...] — run jq over a JSON VALUE held in a shell variable,
# instead of the noisy `printf '%s' "$x" | jq …` at every call site.
jqv() { _jqv=$1; shift; printf '%s' "${_jqv}" | jq "$@"; }

load_config() {
  export SELF_DIR   # so config files can reference it: HARSH_TOOLS_DIR="$SELF_DIR/tools"
  _cfg=${HARSH_CONFIG:-}
  if [ -z "${_cfg}" ]; then
    for _c in ./harsh.conf "${SELF_DIR}/harsh.conf" "${HOME}/.config/harsh/harsh.conf"; do
      [ -f "${_c}" ] && { _cfg=${_c}; break; }
    done
  fi
  if [ -n "${_cfg}" ] && [ -f "${_cfg}" ]; then
    # shellcheck disable=SC1090
    . "${_cfg}"
    _config_file=${_cfg}
  fi
  # Provider picks the wire format (anthropic Messages API | openai Chat
  # Completions). Model, endpoint, and key-env default per provider; all are
  # overridable in the config or environment.
  : "${HARSH_PROVIDER:=anthropic}"
  case "${HARSH_PROVIDER}" in
    openai)
      : "${HARSH_MODEL:=gpt-4o}"
      : "${HARSH_API_URL:=https://api.openai.com/v1/chat/completions}"
      HARSH_API_KEY=${HARSH_API_KEY:-${OPENAI_API_KEY:-}}
      ;;
    anthropic)
      : "${HARSH_MODEL:=claude-opus-4-8}"
      : "${HARSH_API_URL:=https://api.anthropic.com/v1/messages}"
      HARSH_API_KEY=${HARSH_API_KEY:-${ANTHROPIC_API_KEY:-}}
      ;;
    *) die "unknown HARSH_PROVIDER: ${HARSH_PROVIDER} (expected anthropic or openai)" ;;
  esac
  : "${HARSH_MAX_TOKENS:=8192}"
  : "${HARSH_API_VERSION:=2023-06-01}"
  # Prompt caching (Anthropic only) on by default — see build_request. 0 disables.
  : "${HARSH_CACHE:=1}"
  # Transient API failures (network, 408/429/5xx) are retried with exponential
  # backoff: HARSH_RETRIES attempts, starting at HARSH_RETRY_DELAY seconds.
  : "${HARSH_RETRIES:=3}"
  : "${HARSH_RETRY_DELAY:=2}"
  # Data directories must be set explicitly (config or env) — never inferred.
  for _v in HARSH_TOOLS_DIR HARSH_SKILLS_DIR HARSH_SESSIONS_DIR HARSH_LOG_DIR; do
    eval "_val=\${${_v}:-}"
    [ -n "${_val}" ] || die "${_v} is not set; define it in ${_cfg} (see harsh.conf)"
  done
  : "${HARSH_MAX_TURNS:=127}"
  # Auto-compaction: when the last turn's context exceeds this many tokens,
  # cmd_run summarizes the conversation and restarts the session from the
  # summary (full history is archived in the session dir). 0 disables.
  : "${HARSH_COMPACT_AT:=150000}"
  case "${HARSH_COMPACT_AT}" in *[!0-9]*) die "HARSH_COMPACT_AT must be a number (tokens), got: ${HARSH_COMPACT_AT}" ;; esac
  # Hooks/commands/lib are optional; defaults sit next to harsh.sh. A missing
  # hooks or commands dir simply means none are installed.
  : "${HARSH_HOOKS_DIR:=${SELF_DIR}/hooks}"
  : "${HARSH_COMMANDS_DIR:=${SELF_DIR}/commands}"
  : "${HARSH_LIB_DIR:=${SELF_DIR}/lib}"
  : "${HARSH_SYSTEM_PROMPT:=You are a concise and capable assistant operating inside harsh, a coding agent harness. Prefer small, verifiable steps. When the task is complete, stop and summarize.}"
  # (HARSH_API_KEY was resolved per-provider above.)
  # Expose the harness path and resolved config to tool subprocesses, so a tool
  # (e.g. tools/agent.sh) can re-invoke harsh for a sub-session with the same
  # config. HARSH_CONFIG is pinned to the loaded file so children don't re-discover.
  HARSH_SELF="${SELF_DIR}/harsh.sh"
  HARSH_CONFIG=${_config_file}
  export HARSH_PROVIDER HARSH_MODEL HARSH_MAX_TOKENS HARSH_CACHE HARSH_API_URL HARSH_API_VERSION \
         HARSH_TOOLS_DIR HARSH_SKILLS_DIR HARSH_SESSIONS_DIR HARSH_LOG_DIR \
         HARSH_HOOKS_DIR HARSH_COMMANDS_DIR HARSH_LIB_DIR \
         HARSH_MAX_TURNS HARSH_SYSTEM_PROMPT HARSH_API_KEY \
         HARSH_RETRIES HARSH_RETRY_DELAY HARSH_COMPACT_AT \
         HARSH_SELF HARSH_CONFIG HARSH_VERSION
  have jq || die "jq is required"
}

# Resolve a session argument (a bare name -> under sessions dir; a path -> as is)
session_dir() {
  _s=$1
  case "${_s}" in
    /*|./*|../*|*/*) printf '%s' "${_s}" ;;
    *)              printf '%s/%s' "${HARSH_SESSIONS_DIR}" "${_s}" ;;
  esac
}

# Next zero-padded sequence number for a session directory.
next_seq() {
  _dir=$1
  _n=0
  for _f in "${_dir}"/[0-9]*.json; do
    [ -e "${_f}" ] && _n=$((_n + 1))
  done
  printf '%04d' $((_n + 1))
}

# Append a conversation entry: one file holding {role, block[, meta]} plus a
# manifest line. The optional META_JSON carries per-turn response metadata
# (usage, stop_reason, model, id, …) — it is preserved in the session record but
# deliberately ignored by cmd_assemble, so it never reaches the API request.
#   add_entry DIR ROLE TYPE NAME BLOCK_JSON [META_JSON]
add_entry() {
  _dir=$1; _role=$2; _type=$3; _name=$4; _block=$5; _meta=${6:-}
  _seq=$(next_seq "${_dir}")
  if [ -n "${_name}" ]; then
    _safe=$(printf '%s' "${_name}" | tr -c 'A-Za-z0-9_.-' '_')
    _file="${_seq}-${_role}-${_type}-${_safe}.json"
  else
    _file="${_seq}-${_role}-${_type}.json"
  fi
  if [ -n "${_meta}" ] && [ "${_meta}" != null ] && [ "${_meta}" != '{}' ]; then
    jq -nc --arg role "${_role}" --argjson block "${_block}" --argjson meta "${_meta}" \
      '{role:$role, block:$block, meta:$meta}' \
      > "${_dir}/${_file}" || die "failed to write entry (invalid block/meta json)"
  else
    jq -nc --arg role "${_role}" --argjson block "${_block}" '{role:$role,block:$block}' \
      > "${_dir}/${_file}" || die "failed to write entry (invalid block json)"
  fi
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s,%s,%s,%s,%s,%s,%s\n' "${_seq}" "${_role}" "${_type}" "${_name}" "${_file}" "${_ts}" "ok" \
    >> "${_dir}/manifest.csv"
}

# run_hooks EVENT PAYLOAD_JSON [TOOL] — feed PAYLOAD_JSON on stdin to each *.sh
# under $HARSH_HOOKS_DIR/$EVENT (and the $EVENT/$TOOL subdir, if TOOL given), in
# order. Hook exit codes (the Claude Code contract): 2 = block (its stdout is the
# reason; stops and returns 2); 0 = allow (stdout collected as context); other =
# error, logged to hooks.log and ignored. On allow, prints the context, returns 0.
run_hooks() {
  _event=$1; _payload=$2; _tool=${3:-}
  _base="${HARSH_HOOKS_DIR}/${_event}"
  _ctx=""
  mkdir -p "${HARSH_LOG_DIR}" 2>/dev/null || true
  # Scan the event dir (runs for everything), then the tool-specific subdir.
  for _d in "${_base}" "${_tool:+${_base}/${_tool}}"; do
    { [ -n "${_d}" ] && [ -d "${_d}" ]; } || continue
    for _h in "${_d}"/*.sh; do
      [ -f "${_h}" ] || continue
      _out=$(printf '%s' "${_payload}" | sh "${_h}" 2>>"${HARSH_LOG_DIR}/hooks.log"); _rc=$?
      case ${_rc} in
        0) [ -n "${_out}" ] && _ctx="${_ctx}${_out}
" ;;
        2) printf '%s' "${_out}"; return 2 ;;
        *) warn "[hook] ${_event}/$(basename "${_h}") exited ${_rc} (ignored)" ;;
      esac
    done
  done
  printf '%s' "${_ctx}"
  return 0
}

# Locate a command by name on a given SURFACE and print its script path (else
# return 1). A command at the top level of $HARSH_COMMANDS_DIR is available on
# every surface; one inside the SURFACE subdir (cli/ or repl/) is available only
# there — placement is the declaration, the same way hooks narrow scope with a
# subdirectory. Names are sanitized to forbid path traversal.
resolve_command() {
  _surface=$1
  _safe=$(printf '%s' "$2" | tr -cd 'A-Za-z0-9_-')
  [ -n "${_safe}" ] || return 1
  for _p in "${HARSH_COMMANDS_DIR}/${_safe}.sh" "${HARSH_COMMANDS_DIR}/${_surface}/${_safe}.sh"; do
    [ -f "${_p}" ] && { printf '%s' "${_p}"; return 0; }
  done
  return 1
}

# Run a command on the repl surface (top level + repl/). REPL convenience.
run_command() {
  _p=$(resolve_command repl "$1") || return 127
  shift
  sh "${_p}" "$@"
}

# Print "NAME<TAB>description" (via --describe) for the top level plus the SURFACE
# subdir. Default cli — the CLI sees top-level + cli/ commands; pass repl for the
# REPL set (top-level + repl/).
list_commands() {
  _surface=${1:-cli}
  for _d in "${HARSH_COMMANDS_DIR}" "${HARSH_COMMANDS_DIR}/${_surface}"; do
    [ -d "${_d}" ] || continue
    for _c in "${_d}"/*.sh; do
      [ -f "${_c}" ] || continue
      sh "${_c}" --describe 2>/dev/null || printf '%s\t(no description)\n' "$(basename "${_c}" .sh)"
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
  _name=${1:-sess-$(date -u +%Y%m%d-%H%M%S)}
  _dir=$(session_dir "${_name}")
  _fresh=0
  [ -d "${_dir}" ] || _fresh=1
  mkdir -p "${_dir}"
  [ -f "${_dir}/manifest.csv" ] || : > "${_dir}/manifest.csv"
  # SessionStart fires once per new session. Its output (if any) is injected as
  # opening context — captured here so it never reaches stdout, which is the
  # session directory path the callers consume.
  if [ "${_fresh}" = 1 ]; then
    _hp=$(jq -nc --arg e SessionStart --arg s "${_dir}" '{event:$e,session_dir:$s}')
    _hc=$(run_hooks SessionStart "${_hp}") || true
    [ -n "${_hc}" ] && add_entry "${_dir}" user text "" \
      "$(jq -nc --arg t "${_hc}" '{type:"text",text:$t}')" '{"context":"SessionStart"}'
  fi
  printf '%s\n' "${_dir}"
}

cmd_path() { session_dir "$1"; }

cmd_send() {
  _dir=$(session_dir "$1"); shift; _text=$*
  [ -d "${_dir}" ] || die "no such session: ${_dir} (run: harsh.sh init)"
  # UserPromptSubmit — a hook may reject the prompt (exit 2) or emit context that
  # is injected just before it (consecutive user blocks merge into one message).
  _hp=$(jq -nc --arg e UserPromptSubmit --arg s "${_dir}" --arg p "${_text}" \
        '{event:$e,session_dir:$s,prompt:$p}')
  if ! _hc=$(run_hooks UserPromptSubmit "${_hp}"); then
    warn "[blocked] prompt rejected by hook: ${_hc}"
    return 1
  fi
  [ -n "${_hc}" ] && add_entry "${_dir}" user text "" "$(jq -nc --arg t "${_hc}" '{type:"text",text:$t}')"
  _block=$(jq -nc --arg t "${_text}" '{type:"text",text:$t}')
  add_entry "${_dir}" user text "" "${_block}"
}

# Assemble the conversation files into a Messages-API `messages` array by
# grouping consecutive same-role blocks into one message.
cmd_assemble() {
  _dir=$(session_dir "$1")
  set -- "${_dir}"/[0-9]*.json
  [ -e "$1" ] || { printf '[]'; return 0; }
  jq -s 'reduce .[] as $e ([];
      if (length > 0) and (.[-1].role == $e.role)
      then (.[0:-1] + [(.[-1] | .content += [$e.block])])
      else (. + [{role: $e.role, content: [$e.block]}])
      end)' "$@"
}

# Streaming is opt-in (HARSH_STREAM=1) and Anthropic-only: OpenAI's delta
# format differs and is not wired up. The mock never streams.
stream_on() {
  [ "${HARSH_STREAM:-0}" = 1 ] && [ "${HARSH_PROVIDER}" = anthropic ] && [ -z "${HARSH_MOCK:-}" ]
}

# Fold a stream of Anthropic SSE event objects (JSON, one per line, on stdin)
# back into the canonical non-streaming response shape: message_start carries
# the skeleton, content_block_start/delta build the blocks (text appends;
# tool_use input arrives as partial JSON), message_delta carries stop_reason
# and the output-side usage. Exposed as `harsh.sh stream-assemble` (raw SSE on
# stdin) so the transform is testable offline.
stream_assemble() {
  jq -s '
    def finalize: if .type == "tool_use" and has("_pj")
                  then (.input = ((._pj | fromjson?) // {})) | del(._pj)
                  else . end;
    reduce .[] as $e (
      {base: {}, blocks: [], stop: null, dusage: {}};
      if $e.type == "message_start" then .base = ($e.message // {})
      elif $e.type == "content_block_start" then
        .blocks[$e.index] = ($e.content_block // {})
      elif $e.type == "content_block_delta" then
        if $e.delta.type == "text_delta" then
          .blocks[$e.index].text = ((.blocks[$e.index].text // "") + $e.delta.text)
        elif $e.delta.type == "input_json_delta" then
          .blocks[$e.index]._pj = ((.blocks[$e.index]._pj // "") + $e.delta.partial_json)
        else . end
      elif $e.type == "message_delta" then
        (.stop = ($e.delta.stop_reason // .stop)) | (.dusage = ($e.usage // {}))
      else . end)
    | .base
      + {content: (.blocks | map(select(. != null) | finalize)),
         stop_reason: (.stop // .base.stop_reason),
         usage: ((.base.usage // {}) + .dusage)}'
}

# Approximate size (tokens) of the conversation as the API last saw it: the
# most recent turn's usage covers the whole request context, plus what the
# model added on top. Prints 0 when no turn has usage yet (fresh session).
last_context_tokens() {
  _dir=$1
  set -- "${_dir}"/[0-9]*.json
  [ -e "$1" ] || { printf '0'; return 0; }
  jq -s '
    [.[] | .meta.usage // empty] | last // {}
    | (.input_tokens // 0) + (.cache_read_input_tokens // 0)
      + (.cache_creation_input_tokens // 0) + (.output_tokens // 0)' "$@"
}

# Compact a session: ask the model for a comprehensive summary, move every
# entry (and the manifest) into archive/<timestamp>/ inside the session dir,
# and restart the live session from a single summary entry. The next request
# then carries a small context; nothing is lost — the archive keeps the full
# history, inspectable with the usual file tools.
#   cmd_compact SESSION
cmd_compact() {
  _sess=$1
  _dir=$(session_dir "${_sess}")
  [ -d "${_dir}" ] || die "no such session: ${_dir}"
  set -- "${_dir}"/[0-9]*.json
  [ -e "$1" ] || { say "nothing to compact in ${_dir}"; return 0; }

  # PreCompact — a hook may block compaction (exit 2) or emit extra guidance
  # that is appended to the summarizer instruction.
  _hp=$(jq -nc --arg e PreCompact --arg s "${_dir}" '{event:$e,session_dir:$s}')
  if ! _hint=$(run_hooks PreCompact "${_hp}"); then
    warn "[blocked] compaction blocked by hook: ${_hint}"
    return 1
  fi

  _instr='Summarize this entire conversation so far. The summary will REPLACE the conversation as your only context, so be comprehensive: the user'\''s goals and constraints, every decision made and why, the current state of the work, exact file paths/commands/facts that matter, and what remains to be done. Reply with the summary only.'
  [ -n "${_hint}" ] && _instr="${_instr}
${_hint}"
  # Ride the instruction on the existing last user message if there is one
  # (messages must alternate roles), else append a fresh user message. No tools:
  # this turn must produce prose.
  _smsgs=$(cmd_assemble "${_sess}" | jq -c --arg t "${_instr}" '
    if (length > 0) and (.[-1].role == "user")
    then (.[-1].content += [{type:"text",text:$t}])
    else . + [{role:"user",content:[{type:"text",text:$t}]}] end')
  _req=$(build_request "${_smsgs}" '[]')
  _resp=$(call_api "${_req}" "${_dir}") || { warn "[error] compaction failed: API call failed"; return 1; }
  _resp=$(printf '%s' "${_resp}" | normalize_response)
  _sum=$(jqv "${_resp}" -r '.content // [] | map(select(.type=="text").text) | join("\n")')
  [ -n "${_sum}" ] || { warn "[error] compaction failed: empty summary"; return 1; }

  # A trailing, not-yet-answered user prompt must survive compaction (the
  # auto-trigger fires between `send` and the first step). _cut is the last
  # entry that is NOT plain user text; everything after it is the pending
  # prompt, kept aside and re-appended after the summary. tool_result entries
  # are user-role but never pending — they pair with an archived tool_use.
  _cut=""
  for _f in "${_dir}"/[0-9]*.json; do
    [ "$(jq -r '.role + "/" + .block.type' "${_f}")" = "user/text" ] || _cut=${_f}
  done
  [ -n "${_cut}" ] || { say "nothing to compact (no completed turns)"; return 0; }

  _arch="${_dir}/archive/$(date -u +%Y%m%dT%H%M%SZ)"
  _keep=$(mktemp -d 2>/dev/null || echo "/tmp/harsh_keep.$$"); mkdir -p "${_keep}"
  mkdir -p "${_arch}" || die "cannot create ${_arch}"
  _n=0; _after=0
  for _f in "${_dir}"/[0-9]*.json; do
    [ -e "${_f}" ] || continue
    if [ "${_after}" = 1 ]; then
      mv "${_f}" "${_keep}/"
    else
      mv "${_f}" "${_arch}/" && _n=$((_n + 1))
      [ "${_f}" = "${_cut}" ] && _after=1
    fi
  done
  [ -f "${_dir}/manifest.csv" ] && cp "${_dir}/manifest.csv" "${_arch}/manifest.csv"
  : > "${_dir}/manifest.csv"
  add_entry "${_dir}" user text "" \
    "$(jq -nc --arg t "Summary of the conversation so far (earlier turns were compacted away; their full record is archived):

${_sum}" '{type:"text",text:$t}')" '{"context":"compact"}'
  for _f in "${_keep}"/[0-9]*.json; do
    [ -e "${_f}" ] || continue
    add_entry "${_dir}" "$(jq -r '.role' "${_f}")" "$(jq -r '.block.type' "${_f}")" \
      "$(jq -r '.block.name // ""' "${_f}")" "$(jq -c '.block' "${_f}")"
  done
  rm -rf "${_keep}"
  say "[harsh] compacted ${_n} entries into a summary (archive: ${_arch})"
}

# Call the model. Honors HARSH_MOCK for offline smoke testing.
call_api() {
  _req=$1; _dir=$2
  mkdir -p "${HARSH_LOG_DIR}"
  _base=$(basename "${_dir}")
  printf '%s\n' "${_req}" >> "${HARSH_LOG_DIR}/${_base}.request.log"
  if [ -n "${HARSH_MOCK:-}" ]; then
    _resp=$(mock_api "${_req}")
    printf '%s\n' "${_resp}" >> "${HARSH_LOG_DIR}/${_base}.response.log"
    printf '%s' "${_resp}"
    return 0
  fi
  [ -n "${HARSH_API_KEY}" ] || {
    warn "[error] no API key set — export ANTHROPIC_API_KEY (or HARSH_API_KEY), or set HARSH_MOCK=1 for offline testing."
    return 1
  }
  # Provider auth differs: OpenAI uses a Bearer token; Anthropic uses x-api-key
  # plus the dated anthropic-version header. Headers are passed to curl through
  # a private file (-H @file), never argv, so the key is not visible in `ps`;
  # umask 077 keeps the file owner-only for its short life.
  _hdr=$(umask 077; mktemp 2>/dev/null || echo "/tmp/harsh_hdr.$$")
  _bodyf=$(umask 077; mktemp 2>/dev/null || echo "/tmp/harsh_body.$$")
  if [ "${HARSH_PROVIDER}" = openai ]; then
    printf 'authorization: Bearer %s\ncontent-type: application/json\n' \
      "${HARSH_API_KEY}" > "${_hdr}"
  else
    printf 'x-api-key: %s\nanthropic-version: %s\ncontent-type: application/json\n' \
      "${HARSH_API_KEY}" "${HARSH_API_VERSION}" > "${_hdr}"
  fi
  # Streaming path: ask for SSE, print text deltas to stderr as they arrive
  # (stdout stays the captured response), and fold the event stream back into
  # the canonical response shape afterwards. No retry loop here — a stream
  # failure surfaces as the provider's error body via the same error path.
  if stream_on; then
    _evf=$(umask 077; mktemp 2>/dev/null || echo "/tmp/harsh_sse.$$"); : > "${_evf}"
    printf '%s' "${_req}" | jq -c '. + {stream:true}' | curl -sS --no-buffer -X POST "${HARSH_API_URL}" \
        -H @"${_hdr}" --data-binary @- 2>>"${HARSH_LOG_DIR}/curl.log" \
      | while IFS= read -r _sline; do
          printf '%s\n' "${_sline}" >> "${_evf}"
          case "${_sline}" in
            'data: '*'"text_delta"'*)
              printf '%s' "${_sline#data: }" | jq -rj '.delta.text // empty' >&2 ;;
          esac
        done
    rm -f "${_hdr}"
    [ -s "${_evf}" ] || { rm -f "${_evf}" "${_bodyf}"; warn "[error] streaming request to ${HARSH_API_URL} returned nothing"; return 1; }
    printf '\n' >&2
    if grep -q '^data: ' "${_evf}"; then
      _resp=$(sed -n 's/^data: //p' "${_evf}" | stream_assemble)
    else
      # Not SSE: an HTTP-level error body — pass it through to the error path.
      _resp=$(cat "${_evf}")
    fi
    rm -f "${_evf}" "${_bodyf}"
    printf '%s\n' "${_resp}" >> "${HARSH_LOG_DIR}/${_base}.response.log"
    printf '%s' "${_resp}"
    return 0
  fi
  # Transient failures (network, timeouts, 408/429/5xx — including Anthropic's
  # 529 overloaded) retry with exponential backoff. Other non-2xx responses are
  # passed through: cmd_step surfaces .error.message from the body.
  _attempt=0; _delay=${HARSH_RETRY_DELAY}
  while :; do
    _code=$(printf '%s' "${_req}" | curl -sS -X POST "${HARSH_API_URL}" \
        -H @"${_hdr}" --data-binary @- \
        -o "${_bodyf}" -w '%{http_code}' 2>>"${HARSH_LOG_DIR}/curl.log") || _code=000
    case "${_code}" in
      2*) break ;;
      ''|000|408|429|5*)
        _attempt=$((_attempt + 1))
        if [ "${_attempt}" -gt "${HARSH_RETRIES}" ]; then
          rm -f "${_hdr}" "${_bodyf}"
          warn "[error] request to ${HARSH_API_URL} failed after ${HARSH_RETRIES} retries (HTTP ${_code:-000})"
          return 1
        fi
        warn "[retry] HTTP ${_code:-000} from API — attempt ${_attempt}/${HARSH_RETRIES}, waiting ${_delay}s"
        sleep "${_delay}"
        _delay=$((_delay * 2)) ;;
      *) break ;;
    esac
  done
  rm -f "${_hdr}"
  _resp=$(cat "${_bodyf}"); rm -f "${_bodyf}"
  printf '%s\n' "${_resp}" >> "${HARSH_LOG_DIR}/${_base}.response.log"
  printf '%s' "${_resp}"
}

# Offline mock model: echoes text, or emits a tool call when the last user
# message contains a [[tool:NAME:ARG]] marker. Lets the loop be smoke-tested.
mock_api() {
  _req=$1
  # The latest input to respond to is the last message — a user turn (Anthropic
  # content is an array of blocks; OpenAI content is a string) or, after a tool
  # ran, the tool result (Anthropic tool_result blocks carry no text; OpenAI is a
  # role:"tool" string). Pulling only text means a post-tool turn yields "" and
  # the mock stops instead of re-firing the tool. (Selecting role=="user" would
  # miss OpenAI tool results, which are role:"tool", and loop forever.)
  _last=$(jqv "${_req}" -r '
    (.messages[-1].content // []) |
    if type=="array" then (map(select(.type=="text").text) | join(" ")) else (.|tostring) end')
  case "${_last}" in
    # Failure-path fixtures, so tests can exercise the engine's error handling
    # offline: an API error body, a max_tokens truncation, and a parallel
    # multi-tool turn.
    *'[[mock:error]]'*)
      if [ "${HARSH_PROVIDER}" = openai ]; then
        jq -n '{error:{message:"mock API error",type:"invalid_request_error"}}'
      else
        jq -n '{type:"error",error:{type:"invalid_request_error",message:"mock API error"}}'
      fi ;;
    *'[[mock:truncate]]'*)
      if [ "${HARSH_PROVIDER}" = openai ]; then
        jq -n '{id:"chatcmpl_mock1", model:"mock-openai",
          choices:[{message:{role:"assistant", content:"partial reply cut", tool_calls:null}, finish_reason:"length"}],
          usage:{prompt_tokens:10, completion_tokens:5, prompt_tokens_details:{cached_tokens:0}}}'
      else
        jq -n '{content:[{type:"text",text:"partial reply cut"}],stop_reason:"max_tokens",
          model:"mock-model", id:"msg_mock1", role:"assistant", type:"message",
          usage:{input_tokens:10, output_tokens:5, cache_read_input_tokens:0, cache_creation_input_tokens:0}}'
      fi ;;
    *'[[mock:multitool]]'*)
      if [ "${HARSH_PROVIDER}" = openai ]; then
        jq -n '{id:"chatcmpl_mock1", model:"mock-openai",
          choices:[{message:{role:"assistant", content:"two at once",
            tool_calls:[
              {id:"call_mockA", type:"function", function:{name:"bash", arguments:"{\"command\":\"echo one\"}"}},
              {id:"call_mockB", type:"function", function:{name:"bash", arguments:"{\"command\":\"echo two\"}"}}]},
            finish_reason:"tool_calls"}],
          usage:{prompt_tokens:10, completion_tokens:5, prompt_tokens_details:{cached_tokens:0}}}'
      else
        jq -n '{content:[
            {type:"text",text:"two at once"},
            {type:"tool_use",id:"toolu_mockA",name:"bash",input:{command:"echo one"}},
            {type:"tool_use",id:"toolu_mockB",name:"bash",input:{command:"echo two"}}],
          stop_reason:"tool_use"}'
      fi ;;
    *'[[tool:'*']]'*)
      _spec=${_last#*'[[tool:'}; _spec=${_spec%%']]'*}
      _tname=${_spec%%:*}; _targs=${_spec#*:}
      if [ "${HARSH_PROVIDER}" = openai ]; then
        jq -n --arg n "${_tname}" --arg a "${_targs}" '{
          id:"chatcmpl_mock1", model:"mock-openai",
          choices:[{message:{role:"assistant", content:("Calling tool " + $n),
            tool_calls:[{id:"call_mock1", type:"function",
              function:{name:$n, arguments:({command:$a,path:$a,pattern:$a,name:$a}|tojson)}}]},
            finish_reason:"tool_calls"}],
          usage:{prompt_tokens:10, completion_tokens:5, prompt_tokens_details:{cached_tokens:0}}}'
      else
        jq -n --arg n "${_tname}" --arg a "${_targs}" '{
          content:[
            {type:"text",text:("Calling tool " + $n)},
            {type:"tool_use",id:"toolu_mock1",name:$n,
             input:{command:$a,path:$a,pattern:$a,name:$a}}],
          stop_reason:"tool_use"}'
      fi ;;
    *)
      if [ "${HARSH_PROVIDER}" = openai ]; then
        jq -n --arg t "[mock] You said: ${_last}" '{
          id:"chatcmpl_mock1", model:"mock-openai",
          choices:[{message:{role:"assistant", content:$t, tool_calls:null}, finish_reason:"stop"}],
          usage:{prompt_tokens:10, completion_tokens:5, prompt_tokens_details:{cached_tokens:0}}}'
      else
        jq -n --arg t "[mock] You said: ${_last}" '{content:[{type:"text",text:$t}],stop_reason:"end_turn",
          model:"mock-model", id:"msg_mock1", role:"assistant", type:"message",
          usage:{input_tokens:10, output_tokens:5, cache_read_input_tokens:0, cache_creation_input_tokens:0}}'
      fi ;;
  esac
}

# Build the wire request from harsh's canonical (Anthropic-shaped) assembled
# messages + tool schemas, in the configured provider's format. The `request`
# command shells back to `build-request` so it always matches what `step` sends.
build_request() {
  case "${HARSH_PROVIDER}" in
    openai) build_request_openai "$1" "$2" ;;
    *)      build_request_anthropic "$1" "$2" ;;
  esac
}

# Anthropic Messages API. With HARSH_CACHE on (default), inserts cache_control
# breakpoints so the model bills the repeated prefix at the cache-read rate
# (~0.1x) on later turns instead of full price every call. Render order is
# tools->system->messages, so one breakpoint on the system block covers
# tools+system (the large stable prefix); a second on the final message caches
# the conversation so far. Without it, an N-step agentic turn re-bills the whole
# prefix N times.
build_request_anthropic() {
  _bmsgs=$1; _btools=$2
  _bcache=true; case "${HARSH_CACHE:-1}" in 0|no|off|'') _bcache=false ;; esac
  jq -n --arg model "${HARSH_MODEL}" --argjson max "${HARSH_MAX_TOKENS}" \
        --arg sys "${HARSH_SYSTEM_PROMPT}" --argjson tools "${_btools}" \
        --argjson msgs "${_bmsgs}" --argjson cache "${_bcache}" '
    def bp: {cache_control:{type:"ephemeral"}};
    {
      model: $model,
      max_tokens: $max,
      system: (if $cache then [{type:"text", text:$sys} + bp] else $sys end),
      tools: $tools,
      messages: (if ($cache and ($msgs|length>0)
                     and (($msgs[-1].content|type)=="array")
                     and (($msgs[-1].content|length)>0))
                 then ($msgs | .[-1].content[-1] += bp)
                 else $msgs end)
    }'
}

# OpenAI Chat Completions. Translates the canonical messages into OpenAI's shape:
# system prompt as a leading system message; each assistant tool_use becomes a
# tool_calls entry; each tool_result becomes a separate {role:"tool"} message
# linked by tool_call_id; tools wrap as {type:"function", function:{...}}. OpenAI
# caches prefixes automatically, so HARSH_CACHE does not apply here.
build_request_openai() {
  _bmsgs=$1; _btools=$2
  jq -n --arg model "${HARSH_MODEL}" --argjson max "${HARSH_MAX_TOKENS}" \
        --arg sys "${HARSH_SYSTEM_PROMPT}" --argjson tools "${_btools}" \
        --argjson msgs "${_bmsgs}" '
    def oa_msgs:
      reduce .[] as $m ([];
        if $m.role == "assistant" then
          . + [ ( {role:"assistant"}
                  + ( ($m.content | map(select(.type=="text").text) | join("")) as $t
                      | if ($t|length)>0 then {content:$t} else {content:null} end )
                  + ( ($m.content | map(select(.type=="tool_use")
                          | {id:.id, type:"function",
                             function:{name:.name, arguments:(.input|tojson)}})) as $c
                      | if ($c|length)>0 then {tool_calls:$c} else {} end ) ) ]
        elif ($m.content | any(.type=="tool_result")) then
          . + ($m.content | map(
                if .type=="tool_result"
                then {role:"tool", tool_call_id:.tool_use_id,
                      content:(.content | if type=="string" then . else tojson end)}
                elif .type=="text" then {role:"user", content:.text}
                else empty end))
        else
          . + [ {role:"user", content: ($m.content | map(select(.type=="text").text) | join(""))} ]
        end);
    ( {model:$model, max_completion_tokens:$max,
       messages: ([{role:"system", content:$sys}] + ($msgs | oa_msgs))}
      + ( ($tools | map({type:"function",
                         function:{name:.name, description:.description, parameters:.input_schema}})) as $ot
          | if ($ot|length)>0 then {tools:$ot} else {} end) )'
}

# Normalize a provider response into the canonical Anthropic shape
# ({content:[blocks], stop_reason, usage, ...}) that cmd_step consumes, reading
# the raw response on stdin. Anthropic is already canonical (pass through); for
# OpenAI, map choices[0].message -> text/tool_use blocks and finish_reason ->
# stop_reason. Error bodies (no choices) pass through so the error path still
# finds .error.message.
normalize_response() {
  case "${HARSH_PROVIDER}" in
    openai)
      jq -c 'if has("choices") then
          (.choices[0]) as $c |
          { content:
              ( ( if (($c.message.content // "") | length) > 0
                  then [{type:"text", text:$c.message.content}] else [] end )
                + ( ($c.message.tool_calls // []) | map(
                      {type:"tool_use", id:.id, name:.function.name,
                       input:(.function.arguments | (try fromjson catch {}))}) ) ),
            stop_reason: ( $c.finish_reason
                           | if .=="tool_calls" then "tool_use"
                             elif .=="stop" then "end_turn"
                             elif .=="length" then "max_tokens"
                             else (. // "end_turn") end ),
            model: .model, id: .id,
            usage: ( (.usage // {}) | {
                       input_tokens: (.prompt_tokens // 0),
                       output_tokens: (.completion_tokens // 0),
                       cache_read_input_tokens: (.prompt_tokens_details.cached_tokens // 0),
                       cache_creation_input_tokens: 0 } ) }
        else . end' ;;
    *) cat ;;
  esac
}

# Run one tool_use block end to end: PreToolUse gate, execute the tool (with a
# private fd-3 display channel), PostToolUse feedback, then store and render the
# tool_result. Called once per block inside cmd_step's `while read` subshell.
#   do_tool_call SESSION_DIR TOOL_USE_JSON
do_tool_call() {
  _d=$1; _t=$2
  _id=$(jqv "${_t}" -r '.id'); _name=$(jqv "${_t}" -r '.name'); _input=$(jqv "${_t}" -c '.input')
  # PreToolUse — a hook may deny the call (exit 2); its reason is fed back to the
  # model as the (error) tool_result, and the tool is not run.
  _prepay=$(jq -nc --arg e PreToolUse --arg s "${_d}" --arg n "${_name}" --argjson in "${_input}" \
            '{event:$e,session_dir:$s,tool_name:$n,tool_input:$in}')
  _disp=""
  if _reason=$(run_hooks PreToolUse "${_prepay}" "${_name}"); then
    # fd 3 is a display side-channel: a tool can write rich, human-only output
    # there (e.g. edit's colored diff) that we show the user but never feed back
    # to the model. Captured to a temp file, separate from stdout (the
    # model-facing tool_result).
    _disp=$(mktemp 2>/dev/null || echo "/tmp/harsh_disp.$$")
    _out=$(printf '%s' "${_input}" | sh "${HARSH_TOOLS_DIR}/tool.sh" call "${_name}" 2>&1 3>"${_disp}"); _rc=$?
    _err=true; [ "${_rc}" -eq 0 ] && _err=false
    # PostToolUse — feedback (if any) is appended to the tool output.
    _postpay=$(jq -nc --arg e PostToolUse --arg s "${_d}" --arg n "${_name}" \
              --argjson in "${_input}" --arg o "${_out}" --argjson er "${_err}" \
              '{event:$e,session_dir:$s,tool_name:$n,tool_input:$in,tool_output:$o,is_error:$er}')
    _fb=$(run_hooks PostToolUse "${_postpay}" "${_name}") || true
    [ -n "${_fb}" ] && _out="${_out}
[hook] ${_fb}"
  else
    say "${C_TOOL}⛔ ${_name} blocked by hook:${C_RST} ${_reason}"
    _out="Tool call blocked by hook: ${_reason}"; _err=true
  fi
  _block=$(jq -nc --arg id "${_id}" --arg out "${_out}" --argjson e "${_err}" \
    '{type:"tool_result", tool_use_id:$id, content:$out, is_error:$e}')
  _rseq=$(next_seq "${_d}")   # the #handle for `verbose`, captured before the write
  add_entry "${_d}" user tool_result "${_name}" "${_block}"
  [ -n "${HARSH_QUIET:-}" ] || render_tool_result "${_rseq}" "${_name}" "${_input}" "${_out}" "${_err}"
  # Show the fd-3 display channel to the user only (never the model's context).
  if [ -z "${HARSH_QUIET:-}" ] && [ -n "${_disp}" ] && [ -s "${_disp}" ]; then
    sed 's/^/  /' "${_disp}"
  fi
  [ -n "${_disp}" ] && rm -f "${_disp}"
}

# One model turn. Appends assistant blocks; if the model asked for tools, runs
# them (do_tool_call) and appends tool_result blocks.
# returns: 0 = finished, 2 = tool_use (caller should continue), 1 = error,
#          3 = truncated at max_tokens (caller may continue the reply).
cmd_step() {
  _dir=$(session_dir "$1")
  [ -d "${_dir}" ] || die "no such session: ${_dir}"
  _msgs=$(cmd_assemble "$1")
  _tools=$(sh "${HARSH_TOOLS_DIR}/tool.sh" schemas 2>/dev/null); [ -n "${_tools}" ] || _tools='[]'
  _req=$(build_request "${_msgs}" "${_tools}")
  _resp=$(call_api "${_req}" "${_dir}") || return 1
  # Fold the provider response into the canonical shape the rest of this
  # function expects (content blocks + stop_reason + usage meta).
  _resp=$(printf '%s' "${_resp}" | normalize_response)

  if [ "$(jqv "${_resp}" -r 'has("content")')" != "true" ]; then
    warn "[error] $(jqv "${_resp}" -r '.error.message // .message // "unknown API error"')"
    return 1
  fi

  # Per-turn response metadata (everything the API returned except the content
  # blocks themselves): usage/token counts, stop_reason, model, id, etc. We
  # attach it to this turn's first assistant block so it's preserved in the
  # session record; cmd_assemble drops it when building the API request.
  _meta=$(jqv "${_resp}" -c 'del(.content, .role, .type)')

  # Record each assistant content block; the turn meta rides the first one. Tool
  # calls render with their result (do_tool_call) below; here we show prose only.
  _i=0
  jqv "${_resp}" -c '.content[]' | while IFS= read -r _block; do
    _btype=$(jqv "${_block}" -r '.type'); _bname=$(jqv "${_block}" -r '.name // ""')
    if [ "${_i}" -eq 0 ]; then _m=${_meta}; else _m=""; fi
    add_entry "${_dir}" assistant "${_btype}" "${_bname}" "${_block}" "${_m}"
    # Streamed text was already printed live (call_api's delta path) — skip the
    # replay; everything else renders as usual.
    if [ "${_btype}" = text ] && [ -z "${HARSH_QUIET:-}" ] && ! stream_on; then
      render_assistant "$(jqv "${_block}" -r '.text')"
    fi
    _i=$((_i + 1))
  done

  _stop=$(jqv "${_resp}" -r '.stop_reason // ""')
  if [ "${_stop}" = tool_use ]; then
    jqv "${_resp}" -c '.content[] | select(.type=="tool_use")' | while IFS= read -r _tu; do
      do_tool_call "${_dir}" "${_tu}"
    done
    return 2
  fi
  # Hitting the output cap mid-reply must not read as a clean finish: the reply
  # is incomplete. Signal the caller, which re-steps — the conversation then
  # ends on an assistant message, so the model continues where it was cut off.
  if [ "${_stop}" = max_tokens ]; then
    warn "[warn] reply truncated at HARSH_MAX_TOKENS=${HARSH_MAX_TOKENS} — asking the model to continue"
    return 3
  fi
  return 0
}

# Run the agent loop to completion (or HARSH_MAX_TURNS).
cmd_run() {
  _sess=$1
  _dir=$(session_dir "${_sess}")
  _turns=0; _stops=0; _truncs=0
  while [ "${_turns}" -lt "${HARSH_MAX_TURNS}" ]; do
    # Auto-compaction: without it the request grows without bound until the
    # provider rejects it. Checked before each step using the previous turn's
    # actual usage numbers (not an estimate). A failed compaction is non-fatal —
    # worst case the next call fails with the provider's own error.
    if [ "${HARSH_COMPACT_AT}" -gt 0 ]; then
      _ctx=$(last_context_tokens "${_dir}")
      if [ "${_ctx:-0}" -gt "${HARSH_COMPACT_AT}" ]; then
        say "${C_DIM}↻ compacting context (~${_ctx} tokens > HARSH_COMPACT_AT=${HARSH_COMPACT_AT})${C_RST}"
        cmd_compact "${_sess}" || warn "[warn] compaction failed; continuing with full context"
      fi
    fi
    cmd_step "${_sess}"; _rc=$?
    _turns=$((_turns + 1))
    case ${_rc} in
      0)
        # Stop — a hook may force another turn (exit 2) by injecting a message,
        # up to a small cap so it can't loop forever.
        if [ "${_stops}" -lt 3 ]; then
          _sp=$(jq -nc --arg e Stop --arg s "${_dir}" '{event:$e,session_dir:$s}')
          if _reason=$(run_hooks Stop "${_sp}"); then
            return 0
          fi
          _stops=$((_stops + 1))
          say "${C_DIM}↻ continuing (Stop hook):${C_RST} ${_reason}"
          add_entry "${_dir}" user text "" "$(jq -nc --arg t "${_reason}" '{type:"text",text:$t}')"
          continue
        fi
        return 0 ;;
      2) continue ;;
      3)
        # Truncated reply: re-step so the model continues it, but bounded — a
        # reply that can't finish in a few extensions needs a bigger
        # HARSH_MAX_TOKENS, not an unbounded loop.
        if [ "${_truncs}" -lt 3 ]; then
          _truncs=$((_truncs + 1))
          continue
        fi
        warn "[error] reply still truncated after ${_truncs} continuations — raise HARSH_MAX_TOKENS"
        return 1 ;;
      *) return 1 ;;
    esac
  done
  say "[harsh] reached max turns (${HARSH_MAX_TURNS})"
}

# Send a user message then run to completion.
cmd_ask() {
  _sess=$1; shift
  cmd_send "${_sess}" "$*" && cmd_run "${_sess}"
}

# Invoke a skill: load its instructions via the Skills tool, inject as a user
# message, and run. Backs slash commands in the REPL.
cmd_skill() {
  _sess=$1; _name=$2; shift 2 2>/dev/null || shift $#
  _args=$*
  _input=$(jq -nc --arg n "${_name}" --arg a "${_args}" '{name:$n,args:$a}')
  if ! _content=$(printf '%s' "${_input}" | sh "${HARSH_TOOLS_DIR}/tool.sh" call skills); then
    say "skill not found: ${_name}"
    return 1
  fi
  _msg=$(printf 'Please follow the "%s" skill below. Arguments: %s\n\n%s' "${_name}" "${_args}" "${_content}")
  cmd_send "${_sess}" "${_msg}" && cmd_run "${_sess}"
}

repl_help() {
  cat <<'EOF'
REPL:
  <text>           send a message to the agent and run
  /SKILL [args]    invoke a skill (e.g. /commit, /review)
  /verbose         toggle full tool output;  /verbose #SEQ  expand one entry
  /new             start a fresh session  (/sessions to list, /resume <ID> to switch)
  /help            this help;  /quit  exit (or Ctrl-D)

  Ctrl-C           cancel the current line (Ctrl-D or /quit to exit)
  (paste)          a multi-line paste is sent as a single prompt
  ↑/↓              recall earlier input — only in HARSH_RLWRAP=1 mode (Ctrl-R searches)

Commands (type as /NAME — SESSION is filled in automatically):
EOF
  list_commands repl | sort | sed 's/^/  \//'
}

# Bracketed-paste markers. Terminals in bracketed-paste mode wrap a paste in
# ESC[200~ … ESC[201~, so a multi-line paste arrives as several `read` lines with
# the start marker on the first and the end marker on the last. We use these to
# stitch a paste back into ONE prompt (see read_prompt). The bytes are built once.
_PASTE_BEG=$(printf '\033[200~'); _PASTE_END=$(printf '\033[201~')
_ESC=$(printf '\033')

# strip_nav — remove bare cursor/navigation escape sequences from a typed line.
# Without readline (the default native loop), pressing ↑/↓/←/→ or Home/End emits
# CSI sequences (ESC[A, ESC[1~, …) that `read` would otherwise capture as literal
# junk in the message. We can't turn them into history, but we can keep them from
# corrupting input. Sets $_line. Only applied to typed lines, never to pastes
# (a pasted snippet may legitimately contain escapes).
strip_nav() {
  case "${_line}" in
    *"${_ESC}["*)
      # Drop ESC '[' then any parameter/intermediate bytes then a final letter
      # or '~'. Repeat until no such sequence remains.
      while :; do
        case "${_line}" in
          *"${_ESC}["*) ;;
          *) break ;;
        esac
        _pre=${_line%%"${_ESC}["*}
        _post=${_line#*"${_ESC}["}
        # Trim leading params (digits, ';') and one final byte (letter or '~').
        while :; do
          case "${_post}" in
            [0-9\;]*) _post=${_post#?} ;;
            *) break ;;
          esac
        done
        _post=${_post#?}   # drop the final command byte
        _line="${_pre}${_post}"
      done ;;
  esac
}

# read_prompt — read one logical line of REPL input into $_line. A normal line is
# returned as-is. A bracketed paste (multi-line) is accumulated across reads until
# its end marker and returned as a single newline-joined string, so pasting many
# lines yields ONE prompt instead of one-per-line. Returns non-zero at EOF.
read_prompt() {
  IFS= read -r _line || return 1
  case "${_line}" in
    "${_PASTE_BEG}"*)
      # Strip the start marker; keep reading until the end marker appears.
      _line=${_line#"${_PASTE_BEG}"}
      while :; do
        case "${_line}" in
          *"${_PASTE_END}"*) _line=${_line%"${_PASTE_END}"*}; break ;;
        esac
        IFS= read -r _more || break
        _line="${_line}
${_more}"
      done ;;
    *)
      # Typed line: scrub stray cursor-key / nav escapes so they don't pollute
      # the message. (Pastes are handled above and left intact.)
      strip_nav ;;
  esac
  return 0
}

# Default interactive mode: a dependency-free, line-based REPL — it needs
# nothing beyond the core.
#
# Input handling — why the native loop is the default:
#   The native loop (read_prompt, below) puts the terminal in bracketed-paste
#   mode (ESC[?2004h) and stitches a multi-line paste back into ONE prompt. This
#   is the behaviour people expect when they paste a snippet.
#
#   rlwrap would give us ↑/↓ history and richer line editing "for free", but it
#   CANNOT preserve a multi-line paste: rlwrap's readline accepts each pasted
#   newline as a separate line, so a paste arrives as one-prompt-per-line — and
#   its own man page warns that bracketed paste "will confuse rlwrap". No flag
#   combination (-m, --multi-line-ext, enable-bracketed-paste) fixes this in
#   rlwrap 0.48 / readline 8.3. Correct paste and rlwrap are mutually exclusive,
#   so we default to correct paste.
#
#   rlwrap remains available as an explicit opt-in (HARSH_RLWRAP=1) for people
#   who want history/editing and don't paste multi-line. HARSH_RLWRAP=1 both
#   selects the rlwrap path AND guards against re-exec re-entry.
cmd_repl() {
  if [ -t 0 ] && [ "${HARSH_RLWRAP:-}" = 1 ] && [ "${HARSH_NO_RLWRAP:-}" != 1 ] \
     && command -v rlwrap >/dev/null 2>&1; then
    _hist="${HARSH_LOG_DIR:-${SELF_DIR}/logs}/repl_history"
    mkdir -p "$(dirname "${_hist}")" 2>/dev/null || true
    # HARSH_CONFIG and the dir vars are already exported by load_config; carry the
    # quiet flag too so the re-exec'd REPL behaves identically. HARSH_RLWRAP=2
    # marks "already under rlwrap" so the re-exec'd child takes the native loop.
    export HARSH_QUIET="${HARSH_QUIET:-}" HARSH_RLWRAP=2
    exec rlwrap -C harsh -H "${_hist}" -s 5000 \
      sh "${SELF_DIR}/harsh.sh" repl "$@"
  fi
  if [ "${1:-}" != "" ]; then
    _sess=$1
    _dir=$(session_dir "${_sess}")
    [ -d "${_dir}" ] || _dir=$(cmd_init "${_sess}")
    _sess=${_dir}
  else
    _dir=$(cmd_init); _sess=${_dir}
  fi
  _tty=0; [ -t 0 ] && _tty=1
  if [ "${_tty}" = 1 ]; then
    printf '%s╶─ harsh %s · REPL · %s ─╴%s\n' "${C_BAR}" "${HARSH_VERSION}" "${_sess}" "${C_RST}" >&2
    if [ -n "${HARSH_RLWRAP:-}" ]; then
      printf '%sType a message and press Enter. ↑/↓ history, /help for commands, /quit to exit.%s\n' "${C_DIM}" "${C_RST}" >&2
      printf '%s(rlwrap mode: multi-line pastes arrive one line per prompt — unset HARSH_RLWRAP for paste support)%s\n' "${C_DIM}" "${C_RST}" >&2
    else
      printf '%sType a message and press Enter. /help for commands, /quit to exit.%s\n' "${C_DIM}" "${C_RST}" >&2
      command -v rlwrap >/dev/null 2>&1 && printf '%s(set HARSH_RLWRAP=1 for ↑/↓ history and line editing — note: disables multi-line paste)%s\n' "${C_DIM}" "${C_RST}" >&2
    fi
    if [ -z "${HARSH_API_KEY}" ] && [ -z "${HARSH_MOCK:-}" ]; then
      printf '! No API key set — the agent cannot respond. Export ANTHROPIC_API_KEY,\n' >&2
      printf '! or set HARSH_MOCK=1 for an offline mock model.\n' >&2
    fi
    # Ask the terminal to bracket pastes so a multi-line paste reads as ONE
    # prompt (handled in read_prompt). Disabled again only when we exit — NOT on
    # Ctrl-C, which must cancel the current line and keep the REPL running.
    # Skip under rlwrap (HARSH_RLWRAP=2): rlwrap owns the TTY and bracketed paste
    # "confuses rlwrap" (its words), so emitting it there only causes glitches.
    if [ "${HARSH_RLWRAP:-}" != 2 ]; then
      printf '\033[?2004h' >&2
      # Clean up the terminal on real exit / kill only.
      trap 'printf "\033[?2004l" >&2' EXIT TERM
    fi
    # Ctrl-C cancels the line in progress, like a normal shell: the tty discards
    # the partial line and this handler acknowledges the interrupt. The
    # interrupted read resumes in place (it does NOT loop back to the prompt), so
    # the handler also redraws the "harsh>" prompt — otherwise the user is left on
    # a bare line. We do NOT exit and do NOT swallow the next line.
    trap 'printf "%s^C — interrupted (Ctrl-D or /quit to exit)%s\n%sharsh>%s " "${C_DIM}" "${C_RST}" "${C_USER}" "${C_RST}" >&2' INT
  fi
  while :; do
    [ "${_tty}" = 1 ] && printf '%sharsh>%s ' "${C_USER}" "${C_RST}" >&2
    read_prompt || break
    case "${_line}" in
      '') continue ;;
      /quit|/exit|/q) break ;;
      /help)    repl_help >&2 ;;
      /verbose|/v)
        # No arg: toggle global verbose (every tool result prints in full).
        if [ -n "${HARSH_VERBOSE:-}" ]; then
          HARSH_VERBOSE=; printf '%s[verbose off]%s\n' "${C_DIM}" "${C_RST}" >&2
        else
          HARSH_VERBOSE=1; printf '%s[verbose on]%s\n' "${C_DIM}" "${C_RST}" >&2
        fi ;;
      '/verbose '*|'/v '*)
        # With a #SEQ arg: expand that one entry without changing the mode.
        run_command verbose "${_sess}" "${_line#* }" ;;
      # /session, /sessions, and /resume are ordinary commands now (see
      # commands/session.sh, commands/sessions.sh, commands/repl/resume.sh) —
      # they resolve through the /NAME path below. /resume requests a switch by
      # writing the target to $HARSH_SESSION_OUT, which the loop honors there.
      /new)
        _dir=$(cmd_init); _sess=${_dir}
        [ "${_tty}" = 1 ] && printf '[new session: %s]\n' "${_sess}" >&2 ;;
      /*)
        # Any commands/ verb is reachable as /NAME; the current session is filled
        # in for session-scoped ones. Otherwise fall back to a skill of that name.
        _name=${_line#/}; _rest=""
        case "${_name}" in *' '*) _rest=${_name#* }; _name=${_name%% *} ;; esac
        if _p=$(resolve_command repl "${_name}"); then
          # Two channels let a command interact with the loop's current session:
          # HARSH_CURRENT_SESSION (read) names it; a command that writes a target
          # to the HARSH_SESSION_OUT file requests a switch (see resume).
          _sout=$(mktemp 2>/dev/null || echo "/tmp/harsh_sout.$$"); : > "${_sout}"
          if command_wants_session "${_p}"; then
            # shellcheck disable=SC2086  # split rest into positional args
            HARSH_CURRENT_SESSION="${_sess}" HARSH_SESSION_OUT="${_sout}" sh "${_p}" "${_sess}" ${_rest}
          else
            # shellcheck disable=SC2086
            HARSH_CURRENT_SESSION="${_sess}" HARSH_SESSION_OUT="${_sout}" sh "${_p}" ${_rest}
          fi
          if [ -s "${_sout}" ]; then
            _ndir=$(session_dir "$(cat "${_sout}")")
            { [ -d "${_ndir}" ] && [ -f "${_ndir}/manifest.csv" ]; } && { _dir=${_ndir}; _sess=${_dir}; }
          fi
          rm -f "${_sout}"
        elif resolve_command cli "${_name}" >/dev/null 2>&1; then
          printf '%s/%s is a CLI-only command — run: harsh.sh %s …%s\n' \
            "${C_DIM}" "${_name}" "${_name}" "${C_RST}" >&2
        else
          cmd_skill "${_sess}" "${_name}" "${_rest}"
        fi ;;
      *)
        # No prompt echo: the user just typed it at the "harsh>" line directly
        # above, so repeating it only adds noise. A blank line sets the reply
        # off; once the prompt is recorded, a dim "working…" acknowledges the
        # turn has started — the API call blocks, so this is the only feedback
        # until the reply lands.
        [ "${_tty}" = 1 ] && printf '\n' >&2
        if cmd_send "${_sess}" "${_line}"; then
          [ "${_tty}" = 1 ] && printf '%s%s working…%s\n' "${C_DIM}" "${GUTTER}" "${C_RST}" >&2
          cmd_run "${_sess}"
        fi ;;
    esac
  done
  if [ "${_tty}" = 1 ]; then
    trap - INT
    if [ "${HARSH_RLWRAP:-}" != 2 ]; then
      printf '\033[?2004l' >&2        # leave bracketed-paste mode
      trap - EXIT TERM
    fi
    printf '%s%s harsh · bye%s\n' "${C_DIM}" "${GUTTER}" "${C_RST}" >&2
  fi
  return 0
}

usage() {
  cat <<EOF
harsh ${HARSH_VERSION} — a portable shell agent harness

Usage: harsh.sh [-c CONFIG] [-q] [COMMAND [ARGS...]]

With no command, harsh.sh starts an interactive REPL.

Interactive:
  repl [SESSION]         Line-based REPL (default when no command is given).

Engine primitives (built in):
  init|new [NAME]        Create a session; prints its directory.
  send SESSION TEXT...   Append a user message.
  step SESSION           Run one model turn (executes tools if requested).
  run SESSION            Run the agent loop to completion.
  ask SESSION TEXT...    send + run in one go.
  skill SESSION NAME [A] Load a skill and run it.
  assemble SESSION       Print the Messages-API messages[] array.
  compact SESSION        Summarize + archive the conversation; restart from the summary.
  path SESSION           Print the resolved session directory.

Commands (extensible — drop a NAME.sh into \$HARSH_COMMANDS_DIR):
EOF
  list_commands | sort | sed 's/^/  /'
  cat <<EOF

Environment / config (see harsh.conf):
  HARSH_PROVIDER (anthropic | openai; default anthropic),
  HARSH_API_KEY / ANTHROPIC_API_KEY / OPENAI_API_KEY, HARSH_MODEL,
  HARSH_MAX_TOKENS, HARSH_SYSTEM_PROMPT, HARSH_MAX_TURNS,
  HARSH_COMPACT_AT (auto-compaction threshold in tokens; 0 disables),
  HARSH_RETRIES / HARSH_RETRY_DELAY (transient API failure backoff),
  HARSH_STREAM=1 (stream replies live; anthropic only),
  HARSH_MOCK (offline test mode),
  HARSH_CACHE (Anthropic prompt caching, on by default; 0 to disable),
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

_cmd=${1:-repl}; [ $# -gt 0 ] && shift
case "${_cmd}" in
  # --- engine primitives (in-process; reserved, never shadowed) -------------
  repl)     cmd_repl "$@" ;;
  init|new) cmd_init "$@" ;;
  send)     cmd_send "$@" ;;
  step)     cmd_step "$@" ;;
  run)      cmd_run "$@" ;;
  ask)      cmd_ask "$@" ;;
  skill)    cmd_skill "$@" ;;
  assemble) cmd_assemble "$@" ;;
  compact)  cmd_compact "$@" ;;
  path)     cmd_path "$@" ;;
  # Print the wire request a step would send (used by commands/request.sh so the
  # provider-specific builder lives in exactly one place).
  build-request)
    _m=$(cmd_assemble "$1")
    _t=$(sh "${HARSH_TOOLS_DIR}/tool.sh" schemas 2>/dev/null); [ -n "${_t}" ] || _t='[]'
    build_request "${_m}" "${_t}" ;;
  # Fold raw Anthropic SSE (on stdin) into a canonical response. Internal —
  # call_api's streaming path uses the same transform; exposed for tests.
  stream-assemble)
    sed -n 's/^data: //p' | stream_assemble ;;
  # --- meta -----------------------------------------------------------------
  commands) list_commands "$@" | sort ;;
  help|-h|--help) usage ;;
  # --- everything else: an extensible command from $HARSH_COMMANDS_DIR ------
  *)
    if _p=$(resolve_command cli "${_cmd}"); then
      exec sh "${_p}" "$@"
    fi
    die "unknown command: ${_cmd} (try: harsh.sh help)" ;;
esac
