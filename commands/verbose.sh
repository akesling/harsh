#!/usr/bin/env sh
# verbose — expand one entry (#SEQ) in full: the tool's complete input/output.
# Accepts "7", "0007", or "#0007". Uses the shared renderer for the palette.
set -u
[ "${1:-}" = --describe ] && { printf 'verbose SESSION SEQ\tExpand one entry (#SEQ) in full — tool input/output.\n'; exit 0; }
# shellcheck source=/dev/null
. "$HARSH_LIB_DIR/render.sh"
dir=$(sh "$HARSH_SELF" path "$1"); want=$2
want=${want#\#}                       # tolerate a leading '#'
case "$want" in *[!0-9]*|'') printf 'usage: verbose SESSION #SEQ\n' >&2; exit 1 ;; esac
want=$(printf '%04d' "$want")         # normalize to the zero-padded filename form
for f in "$dir/$want"-*.json; do
  [ -e "$f" ] || { printf 'no such entry: #%s\n' "$want" >&2; exit 1; }
  name=$(jq -r '.block.name // ""' "$f")
  btype=$(jq -r '.block.type' "$f")
  printf '%s#%s %s%s%s\n' "$C_DIM" "$want" "$btype" \
    "$( [ -n "$name" ] && printf ' · %s' "$name" )" "$C_RST"
  case "$btype" in
    tool_use)    jq -r '.block.input | tojson' "$f" | gutter "$C_GUT" "$C_DIM" ;;
    tool_result) jq -r '.block.content | tostring' "$f" | gutter "$C_GUT" "$C_RES" ;;
    text)        jq -r '.block.text' "$f" | fmt_markdown | body ;;
    *)           jq -r '.block | tojson' "$f" | gutter "$C_GUT" ;;
  esac
  exit 0
done
