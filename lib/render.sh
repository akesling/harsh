# lib/render.sh — shared presentation helpers for harsh.
#
# Sourced by the core REPL (harsh.sh) and the transcript commands (show) so
# they never drift in look. Defines an ANSI palette (auto-disabled off a TTY
# or under NO_COLOR) and fmt_markdown, a dependency-free markdown highlighter.
#
# This file is sourced, not executed: it must define variables/functions only
# and have no side effects beyond that. It honors an already-set palette, so a
# caller may pre-disable color (e.g. force NO_COLOR) before sourcing.
#
# This is a palette library: several colors are consumed by the sourcing scripts
# (harsh.sh) rather than within this file, so disable the
# unused-variable check file-wide.
# shellcheck disable=SC2034

# ANSI palette. Gated on: stdout is a TTY, NO_COLOR unset, and HARSH_COLOR not
# explicitly "0". A caller wanting color on a non-TTY can set HARSH_COLOR=1.
if { [ "${HARSH_COLOR:-}" = 1 ] || { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; }; } \
   && [ "${HARSH_COLOR:-}" != 0 ]; then
  C_DIM=$(printf '\033[2m');     C_RST=$(printf '\033[0m')
  C_USER=$(printf '\033[1;36m'); C_AI=$(printf '\033[1;32m')
  C_TOOL=$(printf '\033[1;33m'); C_BAR=$(printf '\033[1;34m')
  C_BOLD=$(printf '\033[1m');    C_ITAL=$(printf '\033[3m')
  C_CODE=$(printf '\033[38;5;209m'); C_HEAD=$(printf '\033[1;35m')
  C_GUT=$(printf '\033[38;5;240m');  C_RES=$(printf '\033[38;5;245m')
else
  C_DIM=; C_RST=; C_USER=; C_AI=; C_TOOL=; C_BAR=
  C_BOLD=; C_ITAL=; C_CODE=; C_HEAD=; C_GUT=; C_RES=
fi

# A UTF-8 bullet glyph is only safe under a UTF-8 locale; otherwise BSD sed
# rejects the multibyte byte sequence. Fall back to an ASCII marker when unsure.
# Honor locale precedence — LC_ALL overrides LC_CTYPE overrides LANG — so a
# forced `LC_ALL=C` is respected even when LANG is UTF-8.
_loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
case "${_loc}" in
  *[Uu][Tt][Ff]*) BULLET='•' ;;
  *) BULLET='*' ;;
esac
unset _loc

# Left-gutter glyph that ties every (possibly wrapped) line of an entry to its
# speaker. Like BULLET it must be ASCII-safe outside a UTF-8 locale, since it is
# fed to BSD sed. Kept here so the REPL and `show` share one look.
case "${BULLET}" in
  '•') GUTTER='▌' ;;
  *)   GUTTER='|' ;;
esac

# speaker LABEL COLOR — print a colored gutter header, e.g. "▌ harsh".
# The body that follows should be piped through gutter() with the same color so
# the whole entry reads as one block.
speaker() {
  printf '%s%s %s%s\n' "$2" "${GUTTER}" "$1" "${C_RST}"
}

# gutter COLOR [BODYCOLOR] — filter: prefix each input line with a colored
# gutter glyph. An optional BODYCOLOR wraps the line text itself (used to dim
# tool I/O). A no-op-ish passthrough that still adds the gutter when color off.
gutter() {
  _g=$1; _b=${2:-}
  if [ -n "${_b}" ]; then
    sed "s/^/${_g}${GUTTER}${C_RST} ${_b}/;s/\$/${C_RST}/"
  else
    sed "s/^/${_g}${GUTTER}${C_RST} /"
  fi
}

# body COLOR — filter: indent each line by two spaces, optionally colored. Unlike
# gutter() this draws no per-line glyph, so prose reads as a clean block instead
# of a busy ladder. Use gutter() for tool I/O (where the glyph aids scanning) and
# body() for assistant prose (where it just adds noise).
body() {
  _c=${1:-}
  if [ -n "${_c}" ]; then
    sed "s/^/  ${_c}/;s/\$/${C_RST}/"
  else
    sed 's/^/  /'
  fi
}

# tool_oneline NAME INPUT_JSON — render a compact, single-line summary of a tool
# call: the tool name plus its most salient argument (command / path / pattern),
# truncated. Keeps the REPL readable by collapsing a JSON blob to one glance.
# Falls back to the whole JSON (trimmed) for tools without a known key.
tool_oneline() {
  _name=$1; _json=$2
  _arg=$(printf '%s' "${_json}" | jq -r '
    .command // .path // .pattern // .file // .query //
    (to_entries | map("\(.key)=\(.value|tostring)") | join(" ")) // ""' 2>/dev/null)
  # Collapse whitespace/newlines and clip to keep it to a single tidy line.
  _arg=$(printf '%s' "${_arg}" | tr '\n' ' ' | cut -c1-60)
  printf '%s%s %s%s %s%s%s\n' \
    "${C_TOOL}" "${BULLET}" "${_name}" "${C_RST}" "${C_DIM}" "${_arg}" "${C_RST}"
}

# render_assistant TEXT — an assistant prose block: a colored "harsh" header and
# an indented, markdown-highlighted body. Skips all-whitespace text (the model
# sometimes emits an empty prose block alongside a tool call).
render_assistant() {
  [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ] || return 0
  printf '%sharsh%s\n' "${C_AI}" "${C_RST}"
  printf '%s' "$1" | fmt_markdown | body
  printf '\n'
}

# render_tool_result SEQ NAME INPUT_JSON OUTPUT IS_ERR — the collapsed one-line
# record of a tool call ("#SEQ • name args → N lines"), expandable later via
# `verbose #SEQ`. On error (or under HARSH_VERBOSE) the output is shown inline,
# gutter-prefixed; errors cap at 8 lines with a "+N more" hint.
render_tool_result() {
  _sum=$(tool_oneline "$2" "$3"); _out=$4; _err=$5
  _n=$(printf '%s\n' "${_out}" | wc -l | tr -d ' ')
  printf '%s#%s%s ' "${C_DIM}" "$1" "${C_RST}"
  printf '%s' "${_sum}" | tr -d '\n'
  if [ "${_err}" = true ]; then
    printf '%s → error%s\n' "${C_TOOL}" "${C_RST}"
    printf '%s\n' "${_out}" | head -n 8 | gutter "${C_GUT}" "${C_RES}"
    [ "${_n}" -gt 8 ] && printf '  %s… +%s more lines (/verbose #%s)%s\n' "${C_DIM}" "$((_n - 8))" "$1" "${C_RST}"
  else
    printf '%s → %s line%s%s\n' "${C_DIM}" "${_n}" "$( [ "${_n}" = 1 ] || printf s )" "${C_RST}"
    [ -n "${HARSH_VERBOSE:-}" ] && printf '%s\n' "${_out}" | gutter "${C_GUT}" "${C_RES}"
  fi
  return 0
}

# render_user TEXT — a user prose block: a colored "you" header and an indented,
# user-colored body. The mirror of render_assistant for replayed transcripts.
render_user() {
  printf '%syou%s\n' "${C_USER}" "${C_RST}"
  printf '%s' "$1" | body "${C_USER}"
  printf '\n'
}

# render_transcript DIR [FROM_SEQ] — replay a whole session as colorized,
# headered, markdown-highlighted turns: the exact look of the live REPL, so
# `harsh show` (and hence /resume) never drifts from it. Prose gets a speaker
# header + clean indent; tool mechanics collapse to one dim line each (expandable
# via /verbose). FROM_SEQ, if given, anchors the view to entries with SEQ >= it.
render_transcript() {
  _dir=$1; _from_seq=${2:-}
  for _f in "${_dir}"/[0-9]*.json; do
    [ -e "${_f}" ] || continue
    _seq=$(basename "${_f}"); _seq=${_seq%%-*}
    if [ -n "${_from_seq}" ]; then
      # Numeric compare with leading zeros stripped (POSIX; no base-conversion).
      _a=${_seq#"${_seq%%[!0]*}"}; _b=${_from_seq#"${_from_seq%%[!0]*}"}
      [ "${_a:-0}" -ge "${_b:-0}" ] || continue
    fi
    _role=$(jq -r '.role' "${_f}")
    _btype=$(jq -r '.block.type' "${_f}")
    case "${_role}:${_btype}" in
      user:text)
        render_user "$(jq -r '.block.text' "${_f}")"; continue ;;
      assistant:text)
        # render_assistant already skips all-whitespace prose blocks.
        render_assistant "$(jq -r '.block.text' "${_f}")"; continue ;;
      assistant:tool_use)
        tool_oneline "$(jq -r '.block.name' "${_f}")" "$(jq -c '.block.input' "${_f}")" ;;
      *:tool_result)
        _out=$(jq -r '.block.content | tostring' "${_f}")
        _iserr=$(jq -r '.block.is_error // false' "${_f}")
        _lines=$(printf '%s\n' "${_out}" | wc -l | tr -d ' ')
        if [ "${_iserr}" = true ]; then
          printf '  %s→ error · #%s%s\n' "${C_TOOL}" "${_seq}" "${C_RST}"
          printf '%s\n' "${_out}" | head -n 8 | gutter "${C_GUT}" "${C_RES}"
        else
          printf '  %s→ %s line%s · #%s%s\n' \
            "${C_DIM}" "${_lines}" "$( [ "${_lines}" = 1 ] || printf s )" "${_seq}" "${C_RST}"
          [ -n "${HARSH_VERBOSE:-}" ] && printf '%s\n' "${_out}" | gutter "${C_GUT}" "${C_RES}"
        fi
        continue ;;   # keep the result snug under its call line
      *)
        printf '%s%s/%s%s\n' "${C_DIM}" "${_role}" "${_btype}" "${C_RST}"
        jq -r '.block | tojson' "${_f}" | body "${C_GUT}" ;;
    esac
    printf '\n'
  done
}

# Lightweight, dependency-free markdown highlighter for assistant prose.
# Operates line-by-line with sed (BRE only, so it stays portable across the
# BSD/GNU split). Conservative: it styles the common inline/block forms and
# leaves anything it doesn't recognize untouched. Fenced code blocks
# (``` ... ```) pass through verbatim in a code color with inline rules
# suppressed, so snippets render faithfully. A no-op (cat) when color is off.
fmt_markdown() {
  [ -n "${C_RST}" ] || { cat; return; }
  _in_code=0
  while IFS= read -r _ln || [ -n "${_ln}" ]; do
    case "${_ln}" in
      '```'*)
        _in_code=$((1 - _in_code))
        printf '%s%s%s\n' "${C_DIM}" "${_ln}" "${C_RST}"
        continue ;;
    esac
    if [ "${_in_code}" = 1 ]; then
      printf '%s%s%s\n' "${C_CODE}" "${_ln}" "${C_RST}"
      continue
    fi
    printf '%s\n' "${_ln}" | sed \
      -e "s/^\(#\{1,6\}\) \(.*\)/${C_HEAD}\1 \2${C_RST}/" \
      -e "s/^\([[:space:]]*\)[*-] /\1${C_TOOL}${BULLET}${C_RST} /" \
      -e "s/\`\([^\`]*\)\`/${C_CODE}\1${C_RST}/g" \
      -e "s/\*\*\([^*]*\)\*\*/${C_BOLD}\1${C_RST}/g" \
      -e "s/__\([^_]*\)__/${C_BOLD}\1${C_RST}/g"
  done
}
