#!/usr/bin/env sh
# harsh_tui.sh — a calm, chat-style TUI for harsh.
#
# A proper terminal chat interface: a scrolling transcript on top and a real
# input line at the bottom. Unlike a filter-box UI, typing a message never
# disturbs the conversation — the history stays put and only redraws when a
# turn completes. It does no agent work itself; it renders state and calls into
# harsh.sh for everything, exactly like the built-in REPL does.
#
#   harsh_tui.sh [SESSION]     Open the TUI. With no SESSION, an fzf picker
#                              offers to resume a previous conversation (or
#                              start a new one); falls back to a fresh session
#                              when fzf is unavailable or none exist.
#
# Inside the TUI:
#   • Type a message and press Enter to send it and run the agent.
#   • /help /tools /skills /new /show     app commands
#   • /SKILL [args]                       invoke a skill (slash command)
#   • /map      conversation minimap — jump to a prompt (fzf; click or Enter).
#   • /browse   browse turns in fzf (optional; only if fzf is installed).
#   • /show     redraw.   /quit or Ctrl-D  quit.

set -u
if [ -n "${ZSH_VERSION:-}" ]; then
  emulate sh 2>/dev/null || setopt sh_word_split 2>/dev/null || true
fi
_self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# Invoke sibling scripts through `sh` so the TUI works even when the scripts
# are not marked executable or live on a noexec mount. (Left unquoted at the
# call sites so the "sh <path>" splits into command + argument.)
_harsh="sh ${_self_dir}/harsh.sh"
_self="sh ${_self_dir}/harsh_tui.sh"

_sub=${1:-}

# ---------------------------------------------------------------------------
# internal subcommands (used by the optional fzf turn browser)
# ---------------------------------------------------------------------------
case "${_sub}" in
  # produce the turn list for fzf (SEQ \t label)
  _list)
    _sess=$2
    _dir=$(${_harsh} path "${_sess}")
    [ -f "${_dir}/manifest.csv" ] || exit 0
    # Read all manifest columns by name for clarity; type/ts/status go unused here.
    # shellcheck disable=SC2034
    while IFS=, read -r _seq _role _type _name _file _ts _status; do
      [ -n "${_seq}" ] || continue
      _f="${_dir}/${_file}"
      [ -f "${_f}" ] || continue
      case "${_role}" in user) _icon='›' ;; assistant) _icon='·' ;; *) _icon=' ' ;; esac
      _label=$(jq -r '
        .block as $b |
        (if $b.type=="text" then $b.text
         elif $b.type=="tool_use" then "⚙ " + $b.name + " " + ($b.input|tojson)
         elif $b.type=="tool_result" then "↩ " + ($b.content|tostring)
         else ($b|tojson) end)
        | gsub("[\n\t]";" ") | .[0:90]' "${_f}")
      printf '%s\t%s %s\n' "${_seq}" "${_icon}" "${_label}"
    done < "${_dir}/manifest.csv"
    exit 0
    ;;

  # preview pane for the selected turn (fzf browser)
  _preview)
    _sess=$2; _seq=${3:-}
    _dir=$(${_harsh} path "${_sess}")
    [ -n "${_seq}" ] || { echo "Select a turn to preview it."; exit 0; }
    for _f in "${_dir}/${_seq}"-*.json; do
      [ -e "${_f}" ] || continue
      jq -r '.role as $r | .block as $b |
        "── " + $r + " / " + $b.type + " ──\n\n" +
        (if $b.type=="text" then $b.text
         elif $b.type=="tool_use" then ($b.name + "\n\n" + ($b.input | tojson))
         elif $b.type=="tool_result" then ($b.content | tostring)
         else ($b | tojson) end)' "${_f}"
    done
    exit 0
    ;;

  # preview pane for a whole session (the session picker). Shows a compact,
  # one-line-per-turn transcript so you can recognize a conversation at a glance.
  _spreview)
    _sess=$2
    [ "${_sess}" = NEW ] && { echo "Start a brand-new conversation."; exit 0; }
    _dir=$(${_harsh} path "${_sess}")
    [ -f "${_dir}/manifest.csv" ] || { echo "(empty session)"; exit 0; }
    printf '── %s ──\n\n' "${_sess}"
    for _f in "${_dir}"/[0-9]*.json; do
      [ -e "${_f}" ] || continue
      jq -r '.role as $r | .block as $b |
        (if $r=="user" then "› " elif $r=="assistant" then "· " else "  " end) +
        (if $b.type=="text" then $b.text
         elif $b.type=="tool_use" then "⚙ " + $b.name + " " + ($b.input|tojson)
         elif $b.type=="tool_result" then "↩ " + ($b.content|tostring)
         else ($b|tojson) end)
        | gsub("[\n\t]";" ")' "${_f}"
    done
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# rendering helpers
# ---------------------------------------------------------------------------

# Shared presentation helpers (palette + fmt_markdown), kept in lib/render.sh so
# the TUI and the core REPL never drift in look. Guarded with inert fallbacks so
# the TUI degrades gracefully if the lib is missing.
if [ -f "${_self_dir}/lib/render.sh" ]; then
  # shellcheck disable=SC1091
  . "${_self_dir}/lib/render.sh"
else
  C_DIM=; C_RST=; C_USER=; C_AI=; C_TOOL=; C_BAR=; C_GUT=; C_RES=; GUTTER='|'
  fmt_markdown() { cat; }
  gutter()  { sed "s/^/${GUTTER} /"; }
  body()    { sed 's/^/  /'; }
  tool_oneline() { printf '%s %s\n' "$1" "$2"; }
fi

# The transcript renderer (render_transcript DIR [FROM_SEQ]) lives in
# lib/render.sh, shared with `harsh show`/the REPL so the three never drift.

# Clear the screen and draw the transcript followed by a status bar. The
# transcript is piped through a pager-free tail so the newest turn is visible;
# the terminal's own scrollback keeps the rest.
redraw() {
  _dir=$1; _from_seq=${2:-}
  clear 2>/dev/null || printf '\033[2J\033[H'
  render_transcript "${_dir}" "${_from_seq}"
  printf '%s' "${C_BAR}"
  printf '╶─ harsh · %s' "$(basename "${_dir}")"
  [ -n "${_from_seq}" ] && printf ' · from #%s (/show for full)' "${_from_seq}"
  printf ' ─╴%s\n' "${C_RST}"
  printf '%sEnter: send · /verbose · /map · /browse · /help · /quit%s\n' "${C_DIM}" "${C_RST}"
}

# Optional fzf turn browser, bound to Ctrl-G. Read-only.
browse() {
  _sess=$1
  command -v fzf >/dev/null 2>&1 || { echo "(fzf not installed)"; return 0; }
  ${_self} _list "${_sess}" | fzf \
    --ansi --reverse --no-sort --cycle \
    --delimiter '\t' --with-nth '2..' \
    --header "browse turns — Esc: back" \
    --preview "${_self} _preview '${_sess}' {1}" \
    --preview-window 'down:65%:wrap' \
    --bind 'start:last' >/dev/null 2>&1 || true
}

# Conversation minimap: one row per user prompt (with a one-line summary of the
# response), navigable by arrows or mouse. Prints the chosen prompt's SEQ on
# stdout (empty if cancelled), so the caller can jump the transcript there.
# Reuses the core's `outline` view and the per-turn `_preview` pane.
map() {
  _sess=$1
  command -v fzf >/dev/null 2>&1 || { echo "(fzf not installed)"; return 0; }
  _list=$(${_harsh} outline "${_sess}")
  [ -n "${_list}" ] || { echo "(no prompts yet)"; return 0; }
  # Columns: SEQ \t PROMPT \t SUMMARY. Show prompt + summary; keep SEQ ({1})
  # for the preview and the return value.
  _sel=$(printf '%s\n' "${_list}" | fzf \
    --ansi --reverse --no-sort --cycle \
    --delimiter '\t' --with-nth '2..' \
    --header 'minimap — Enter/click: jump · Esc: back' \
    --bind 'enter:accept' \
    --preview "${_self} _preview '${_sess}' {1}" \
    --preview-window 'down:60%:wrap' 2>/dev/null) || true
  printf '%s' "${_sel%%	*}"
}

# Pick a session to resume via fzf, or start a new one. Prints the chosen
# session name (or directory) on stdout. Falls back to a fresh session when
# fzf is unavailable or there is nothing to resume.
pick_session() {
  command -v fzf >/dev/null 2>&1 || { ${_harsh} new; return; }
  _list=$(${_harsh} sessions)
  [ -n "${_list}" ] || { ${_harsh} new; return; }
  _choice=$( { printf 'NEW\t＋ new conversation\n'; printf '%s\n' "${_list}"; } | fzf \
    --ansi --reverse --no-sort --cycle \
    --delimiter '\t' --with-nth '2..' \
    --header 'resume a conversation — Enter: open · Esc: cancel' \
    --preview "${_self} _spreview {1}" \
    --preview-window 'down:65%:wrap' ) || true
  _sel=${_choice%%	*}
  case "${_sel}" in
    ''|NEW) ${_harsh} new ;;
    *)      printf '%s\n' "${_sel}" ;;
  esac
}

# ---------------------------------------------------------------------------
# main loop
# ---------------------------------------------------------------------------
_sess=${1:-}
if [ -z "${_sess}" ]; then
  # No session given: offer to resume a previous conversation (fzf picker),
  # falling back to a fresh session when none exist or fzf is unavailable.
  _sess=$(pick_session)
fi
_dir=$(${_harsh} path "${_sess}")
[ -d "${_dir}" ] || _dir=$(${_harsh} init "${_sess}")

if [ -z "${HARSH_API_KEY:-}${ANTHROPIC_API_KEY:-}" ] && [ -z "${HARSH_MOCK:-}" ]; then
  _warned_no_key=1
else
  _warned_no_key=0
fi

redraw "${_dir}"
[ "${_warned_no_key}" = 1 ] && \
  printf '%s! No API key set — export ANTHROPIC_API_KEY or set HARSH_MOCK=1.%s\n' "${C_DIM}" "${C_RST}"

while :; do
  printf '%s› %s' "${C_USER}" "${C_RST}"
  IFS= read -r _line || { echo; break; }
  case "${_line}" in
    '') continue ;;
    /quit|/exit|/q) break ;;
    /help)
      cat <<EOF
harsh TUI
  <text>           send a message to the agent and run
  /SKILL [args]    invoke a skill (e.g. /commit, /review)
  /verbose         toggle full tool output;  /verbose #SEQ  expand one entry
  /map             minimap: jump to a prompt (fzf)
  /browse          browse turns in fzf
  /show            redraw the transcript
  /sessions        switch / resume (fzf picker)
  /new             fresh session;  /quit or Ctrl-D  quit
EOF
      printf '\nCommands (type as /NAME — SESSION is filled in automatically):\n'
      ${_harsh} commands repl | sed 's/^/  \//'
      printf '\n%s[ press Enter to continue ]%s' "${C_DIM}" "${C_RST}"; read -r _ || true
      redraw "${_dir}"; continue ;;
    /show|/redraw) redraw "${_dir}"; continue ;;
    /verbose|/v)
      # Toggle full tool output. Exported so render_transcript (and the core, if
      # a turn runs) honors it; redraw reflects the change immediately.
      if [ -n "${HARSH_VERBOSE:-}" ]; then unset HARSH_VERBOSE; else export HARSH_VERBOSE=1; fi
      redraw "${_dir}"; continue ;;
    '/verbose '*|'/v '*)
      # Expand one entry by #SEQ without changing the mode.
      ${_harsh} verbose "${_sess}" "${_line#* }"
      printf '\n%s[ press Enter to continue ]%s' "${C_DIM}" "${C_RST}"; read -r _ || true
      redraw "${_dir}"; continue ;;
    /map|/outline)
      _jump=$(map "${_sess}")
      if [ -n "${_jump}" ]; then redraw "${_dir}" "${_jump}"; else redraw "${_dir}"; fi
      continue ;;
    /browse) browse "${_sess}"; redraw "${_dir}"; continue ;;
    /sessions|/resume|/switch)
      _picked=$(pick_session)
      [ -n "${_picked}" ] && { _sess=${_picked}; _dir=$(${_harsh} path "${_sess}"); }
      redraw "${_dir}"; continue ;;
    /new)
      _sess=$(${_harsh} new); _dir=$(${_harsh} path "${_sess}"); redraw "${_dir}"; continue ;;
    /*)
      # Any commands/ verb is reachable as /NAME (session auto-filled when it
      # takes one); otherwise fall back to a skill of that name.
      _name=${_line#/}; _rest=""
      case "${_name}" in *' '*) _rest=${_name#* }; _name=${_name%% *} ;; esac
      _name=$(printf '%s' "${_name}" | tr -cd 'A-Za-z0-9_-')
      _cline=$(${_harsh} commands repl | grep -E "^${_name}([[:space:]]|$)" | head -n1)
      if [ -n "${_cline}" ]; then
        # A repl-surfaced commands/ verb; fill in the session when it takes one.
        case "${_cline}" in *SESSION*) _sset=${_sess} ;; *) _sset="" ;; esac
        # Same two channels as the REPL: HARSH_CURRENT_SESSION names the active
        # session; a command may request a switch by writing to HARSH_SESSION_OUT.
        _sout=$(mktemp 2>/dev/null || echo "/tmp/harsh_tsout.$$"); : > "${_sout}"
        # shellcheck disable=SC2086  # sset/rest are intentionally split into args
        HARSH_CURRENT_SESSION="${_sess}" HARSH_SESSION_OUT="${_sout}" ${_harsh} "${_name}" ${_sset} ${_rest}
        if [ -s "${_sout}" ]; then
          _tgt=$(cat "${_sout}"); _ndir=$(${_harsh} path "${_tgt}")
          { [ -d "${_ndir}" ] && [ -f "${_ndir}/manifest.csv" ]; } && { _sess=${_tgt}; _dir=${_ndir}; }
        fi
        rm -f "${_sout}"
        printf '\n%s[ press Enter to continue ]%s' "${C_DIM}" "${C_RST}"; read -r _ || true
      elif ${_harsh} commands | grep -qE "^${_name}([[:space:]]|$)"; then
        # Exists, but it's CLI-only (e.g. reads stdin) — not meaningful here.
        printf '%s/%s is a CLI-only command (run: harsh.sh %s …)%s\n' "${C_DIM}" "${_name}" "${_name}" "${C_RST}"
        printf '\n%s[ press Enter to continue ]%s' "${C_DIM}" "${C_RST}"; read -r _ || true
      else
        ${_harsh} skill "${_sess}" "${_name}" "${_rest}"
      fi
      redraw "${_dir}"; continue ;;
    *)
      # Acknowledge the turn before the blocking run; redraw wipes the notice.
      if ${_harsh} send "${_sess}" "${_line}"; then
        printf '%s%s working…%s\n' "${C_DIM}" "${GUTTER}" "${C_RST}"
        ${_harsh} run "${_sess}"
      fi
      redraw "${_dir}"; continue ;;
  esac
done
printf '%s[harsh] bye%s\n' "${C_DIM}" "${C_RST}"
