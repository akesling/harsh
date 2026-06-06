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
DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# Invoke sibling scripts through `sh` so the TUI works even when the scripts
# are not marked executable or live on a noexec mount.
HARSH="sh $DIR/harsh.sh"
SELF="sh $DIR/harsh_tui.sh"

sub=${1:-}

# ---------------------------------------------------------------------------
# internal subcommands (used by the optional fzf turn browser)
# ---------------------------------------------------------------------------
case "$sub" in
  # produce the turn list for fzf (SEQ \t label)
  _list)
    sess=$2
    dir=$($HARSH path "$sess")
    [ -f "$dir/manifest.csv" ] || exit 0
    # Read all manifest columns by name for clarity; type/ts/status go unused here.
    # shellcheck disable=SC2034
    while IFS=, read -r seq role type name file ts status; do
      [ -n "$seq" ] || continue
      f="$dir/$file"
      [ -f "$f" ] || continue
      case "$role" in user) icon='›' ;; assistant) icon='·' ;; *) icon=' ' ;; esac
      label=$(jq -r '
        .block as $b |
        (if $b.type=="text" then $b.text
         elif $b.type=="tool_use" then "⚙ " + $b.name + " " + ($b.input|tojson)
         elif $b.type=="tool_result" then "↩ " + ($b.content|tostring)
         else ($b|tojson) end)
        | gsub("[\n\t]";" ") | .[0:90]' "$f")
      printf '%s\t%s %s\n' "$seq" "$icon" "$label"
    done < "$dir/manifest.csv"
    exit 0
    ;;

  # preview pane for the selected turn (fzf browser)
  _preview)
    sess=$2; seq=${3:-}
    dir=$($HARSH path "$sess")
    [ -n "$seq" ] || { echo "Select a turn to preview it."; exit 0; }
    for f in "$dir/$seq"-*.json; do
      [ -e "$f" ] || continue
      jq -r '.role as $r | .block as $b |
        "── " + $r + " / " + $b.type + " ──\n\n" +
        (if $b.type=="text" then $b.text
         elif $b.type=="tool_use" then ($b.name + "\n\n" + ($b.input | tojson))
         elif $b.type=="tool_result" then ($b.content | tostring)
         else ($b | tojson) end)' "$f"
    done
    exit 0
    ;;

  # preview pane for a whole session (the session picker). Shows a compact,
  # one-line-per-turn transcript so you can recognize a conversation at a glance.
  _spreview)
    sess=$2
    [ "$sess" = NEW ] && { echo "Start a brand-new conversation."; exit 0; }
    dir=$($HARSH path "$sess")
    [ -f "$dir/manifest.csv" ] || { echo "(empty session)"; exit 0; }
    printf '── %s ──\n\n' "$sess"
    for f in "$dir"/[0-9]*.json; do
      [ -e "$f" ] || continue
      jq -r '.role as $r | .block as $b |
        (if $r=="user" then "› " elif $r=="assistant" then "· " else "  " end) +
        (if $b.type=="text" then $b.text
         elif $b.type=="tool_use" then "⚙ " + $b.name + " " + ($b.input|tojson)
         elif $b.type=="tool_result" then "↩ " + ($b.content|tostring)
         else ($b|tojson) end)
        | gsub("[\n\t]";" ")' "$f"
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
if [ -f "$DIR/lib/render.sh" ]; then
  # shellcheck disable=SC1091
  . "$DIR/lib/render.sh"
else
  C_DIM=; C_RST=; C_USER=; C_AI=; C_TOOL=; C_BAR=
  C_BOLD=; C_ITAL=; C_CODE=; C_HEAD=; C_GUT=; C_RES=; BULLET='*'; GUTTER='|'
  fmt_markdown() { cat; }
  speaker() { printf '%s %s\n' "$GUTTER" "$1"; }
  gutter()  { sed "s/^/$GUTTER /"; }
  body()    { sed 's/^/  /'; }
  tool_oneline() { printf '%s %s\n' "$1" "$2"; }
fi

# Strip leading zeros from a numeric string (POSIX-safe). Avoids feeding a
# zero-padded seq like "0008" straight into $(( )), where leading zeros mean
# octal and "0008"/"0009" would error.
dec() { d=${1#"${1%%[!0]*}"}; printf '%s' "${d:-0}"; }

# Render the transcript as colorized, prefixed lines. Reuses the same per-entry
# decoding the core uses, so the TUI never drifts from `harsh show`. An optional
# second argument anchors the render: only entries with SEQ >= from_seq are
# drawn, so `/map` can "jump" the view to a chosen prompt.
render_transcript() {
  dir=$1; from_seq=${2:-}
  for f in "$dir"/[0-9]*.json; do
    [ -e "$f" ] || continue
    seq=$(basename "$f"); seq=${seq%%-*}
    if [ -n "$from_seq" ]; then
      # Numeric compare with leading zeros stripped (POSIX; no base-conversion).
      [ "$(dec "$seq")" -ge "$(dec "$from_seq")" ] || continue
    fi
    role=$(jq -r '.role' "$f")
    btype=$(jq -r '.block.type' "$f")
    # Prose is the content you read, so it gets a header + clean indent. Tool
    # mechanics are skimmable, so they collapse to one dim line each — matching
    # the REPL (cmd_step in harsh.sh) so the two never drift in look.
    case "$role:$btype" in
      user:text)
        printf '%syou%s\n' "$C_USER" "$C_RST"
        jq -r '.block.text' "$f" | body "$C_USER" ;;
      assistant:text)
        # Skip empty prose blocks that accompany a tool call.
        txt=$(jq -r '.block.text' "$f")
        if [ -n "$(printf '%s' "$txt" | tr -d '[:space:]')" ]; then
          printf '%sharsh%s\n' "$C_AI" "$C_RST"
          printf '%s' "$txt" | fmt_markdown | body
        else
          continue
        fi ;;
      assistant:tool_use)
        name=$(jq -r '.block.name' "$f")
        input=$(jq -c '.block.input' "$f")
        tool_oneline "$name" "$input" ;;
      *:tool_result)
        # Append the result's line-count to the preceding call line, tagged with
        # its #seq handle. On error (or under HARSH_VERBOSE) show the output; on
        # success a single glance ("→ N lines · #SEQ") suffices.
        out=$(jq -r '.block.content | tostring' "$f")
        iserr=$(jq -r '.block.is_error // false' "$f")
        lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
        if [ "$iserr" = true ]; then
          printf '  %s→ error · #%s%s\n' "$C_TOOL" "$seq" "$C_RST"
          printf '%s\n' "$out" | head -n 8 | gutter "$C_GUT" "$C_RES"
        else
          printf '  %s→ %s line%s · #%s%s\n' \
            "$C_DIM" "$lines" "$( [ "$lines" = 1 ] || printf s )" "$seq" "$C_RST"
          [ -n "${HARSH_VERBOSE:-}" ] && printf '%s\n' "$out" | gutter "$C_GUT" "$C_RES"
        fi
        # No trailing blank: keep the result snug under its call line.
        continue ;;
      *)
        printf '%s%s/%s%s\n' "$C_DIM" "$role" "$btype" "$C_RST"
        jq -r '.block | tojson' "$f" | body "$C_GUT" ;;
    esac
    printf '\n'
  done
}

# Clear the screen and draw the transcript followed by a status bar. The
# transcript is piped through a pager-free tail so the newest turn is visible;
# the terminal's own scrollback keeps the rest.
redraw() {
  dir=$1; from_seq=${2:-}
  clear 2>/dev/null || printf '\033[2J\033[H'
  render_transcript "$dir" "$from_seq"
  printf '%s' "${C_BAR}"
  printf '╶─ harsh · %s' "$(basename "$dir")"
  [ -n "$from_seq" ] && printf ' · from #%s (/show for full)' "$from_seq"
  printf ' ─╴%s\n' "${C_RST}"
  printf '%sEnter: send · /verbose · /map · /browse · /help · /quit%s\n' "$C_DIM" "$C_RST"
}

# Optional fzf turn browser, bound to Ctrl-G. Read-only.
browse() {
  sess=$1
  command -v fzf >/dev/null 2>&1 || { echo "(fzf not installed)"; return 0; }
  $SELF _list "$sess" | fzf \
    --ansi --reverse --no-sort --cycle \
    --delimiter '\t' --with-nth '2..' \
    --header "browse turns — Esc: back" \
    --preview "$SELF _preview '$sess' {1}" \
    --preview-window 'down:65%:wrap' \
    --bind 'start:last' >/dev/null 2>&1 || true
}

# Conversation minimap: one row per user prompt (with a one-line summary of the
# response), navigable by arrows or mouse. Prints the chosen prompt's SEQ on
# stdout (empty if cancelled), so the caller can jump the transcript there.
# Reuses the core's `outline` view and the per-turn `_preview` pane.
map() {
  sess=$1
  command -v fzf >/dev/null 2>&1 || { echo "(fzf not installed)"; return 0; }
  list=$($HARSH outline "$sess")
  [ -n "$list" ] || { echo "(no prompts yet)"; return 0; }
  # Columns: SEQ \t PROMPT \t SUMMARY. Show prompt + summary; keep SEQ ({1})
  # for the preview and the return value.
  sel=$(printf '%s\n' "$list" | fzf \
    --ansi --reverse --no-sort --cycle \
    --delimiter '\t' --with-nth '2..' \
    --header 'minimap — Enter/click: jump · Esc: back' \
    --bind 'enter:accept' \
    --preview "$SELF _preview '$sess' {1}" \
    --preview-window 'down:60%:wrap' 2>/dev/null) || true
  printf '%s' "${sel%%	*}"
}

# Pick a session to resume via fzf, or start a new one. Prints the chosen
# session name (or directory) on stdout. Falls back to a fresh session when
# fzf is unavailable or there is nothing to resume.
pick_session() {
  command -v fzf >/dev/null 2>&1 || { $HARSH new; return; }
  list=$($HARSH sessions)
  [ -n "$list" ] || { $HARSH new; return; }
  choice=$( { printf 'NEW\t＋ new conversation\n'; printf '%s\n' "$list"; } | fzf \
    --ansi --reverse --no-sort --cycle \
    --delimiter '\t' --with-nth '2..' \
    --header 'resume a conversation — Enter: open · Esc: cancel' \
    --preview "$SELF _spreview {1}" \
    --preview-window 'down:65%:wrap' ) || true
  sel=${choice%%	*}
  case "$sel" in
    ''|NEW) $HARSH new ;;
    *)      printf '%s\n' "$sel" ;;
  esac
}

# ---------------------------------------------------------------------------
# main loop
# ---------------------------------------------------------------------------
sess=${1:-}
if [ -z "$sess" ]; then
  # No session given: offer to resume a previous conversation (fzf picker),
  # falling back to a fresh session when none exist or fzf is unavailable.
  sess=$(pick_session)
fi
dir=$($HARSH path "$sess")
[ -d "$dir" ] || dir=$($HARSH init "$sess")

if [ -z "${HARSH_API_KEY:-}${ANTHROPIC_API_KEY:-}" ] && [ -z "${HARSH_MOCK:-}" ]; then
  warned_no_key=1
else
  warned_no_key=0
fi

redraw "$dir"
[ "$warned_no_key" = 1 ] && \
  printf '%s! No API key set — export ANTHROPIC_API_KEY or set HARSH_MOCK=1.%s\n' "$C_DIM" "$C_RST"

while :; do
  printf '%s› %s' "$C_USER" "$C_RST"
  IFS= read -r line || { echo; break; }
  case "$line" in
    '') continue ;;
    /quit|/exit|/q) break ;;
    /help)
      cat <<EOF
harsh TUI commands
  <text>           send a message to the agent and run
  /help            this help
  /tools           list available tools
  /skills          list available skills
  /hooks           list installed hooks
  /show            redraw the transcript (full, from the top)
  /verbose         toggle full tool output (off by default)
  /verbose #SEQ    expand one collapsed entry by its #id
  /map             conversation minimap: jump to a prompt (fzf; click or Enter)
  /browse          browse individual turns in fzf (if installed)
  /sessions        switch to / resume another conversation (fzf picker)
  /new             start a fresh session
  /SKILL [args]    invoke a skill (e.g. /commit, /review)
  /quit or Ctrl-D  quit
EOF
      printf '\n%s[ press Enter to continue ]%s' "$C_DIM" "$C_RST"; read -r _ || true
      redraw "$dir"; continue ;;
    /tools)
      $HARSH tools
      printf '\n%s[ press Enter to continue ]%s' "$C_DIM" "$C_RST"; read -r _ || true
      redraw "$dir"; continue ;;
    /skills)
      $HARSH skills | sed 's/\t/  →  /'
      printf '\n%s[ press Enter to continue ]%s' "$C_DIM" "$C_RST"; read -r _ || true
      redraw "$dir"; continue ;;
    /hooks)
      $HARSH hooks | sed 's/\t/  →  /'
      printf '\n%s[ press Enter to continue ]%s' "$C_DIM" "$C_RST"; read -r _ || true
      redraw "$dir"; continue ;;
    /show|/redraw) redraw "$dir"; continue ;;
    /verbose|/v)
      # Toggle full tool output. Exported so render_transcript (and the core, if
      # a turn runs) honors it; redraw reflects the change immediately.
      if [ -n "${HARSH_VERBOSE:-}" ]; then unset HARSH_VERBOSE; else export HARSH_VERBOSE=1; fi
      redraw "$dir"; continue ;;
    '/verbose '*|'/v '*)
      # Expand one entry by #SEQ without changing the mode.
      $HARSH verbose "$sess" "${line#* }"
      printf '\n%s[ press Enter to continue ]%s' "$C_DIM" "$C_RST"; read -r _ || true
      redraw "$dir"; continue ;;
    /map|/outline)
      jump=$(map "$sess")
      if [ -n "$jump" ]; then redraw "$dir" "$jump"; else redraw "$dir"; fi
      continue ;;
    /browse) browse "$sess"; redraw "$dir"; continue ;;
    /sessions|/resume|/switch)
      picked=$(pick_session)
      [ -n "$picked" ] && { sess=$picked; dir=$($HARSH path "$sess"); }
      redraw "$dir"; continue ;;
    /new)
      sess=$($HARSH new); dir=$($HARSH path "$sess"); redraw "$dir"; continue ;;
    /*)
      name=${line#/}; rest=""
      case "$name" in *' '*) rest=${name#* }; name=${name%% *} ;; esac
      $HARSH skill "$sess" "$name" "$rest"
      redraw "$dir"; continue ;;
    *)
      $HARSH send "$sess" "$line" && $HARSH run "$sess"
      redraw "$dir"; continue ;;
  esac
done
printf '%s[harsh] bye%s\n' "$C_DIM" "$C_RST"