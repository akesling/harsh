#!/usr/bin/env sh
# tool.sh — the tool dispatcher. Every tool call is run through here.
#
#   tool.sh list                List tool names.
#   tool.sh schemas             Print all tool schemas as a JSON array.
#   tool.sh schema NAME         Print one tool's schema.
#   tool.sh call NAME           Run a tool (JSON input on stdin).
#   tool.sh NAME [--schema]     Shorthand for the above.
#
# A tool is any executable `NAME.sh` in this directory that prints its schema
# with `--schema` and reads a JSON object on stdin when invoked.

set -u
if [ -n "${ZSH_VERSION:-}" ]; then
  emulate sh 2>/dev/null || setopt sh_word_split 2>/dev/null || true
fi
DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

sub=${1:-help}; [ $# -gt 0 ] && shift

case "$sub" in
  list)
    for t in "$DIR"/*.sh; do
      [ -e "$t" ] || continue
      b=$(basename "$t" .sh)
      [ "$b" = tool ] && continue
      printf '%s\n' "$b"
    done ;;
  schemas)
    for t in "$DIR"/*.sh; do
      [ -e "$t" ] || continue
      b=$(basename "$t" .sh)
      [ "$b" = tool ] && continue
      sh "$t" --schema 2>/dev/null
    done | jq -s '.' ;;
  schema)
    [ $# -ge 1 ] || { echo "tool.sh schema NAME" >&2; exit 2; }
    exec sh "$DIR/$1.sh" --schema ;;
  call)
    [ $# -ge 1 ] || { echo "tool.sh call NAME" >&2; exit 2; }
    name=$1
    [ -f "$DIR/$name.sh" ] || { printf 'unknown tool: %s\n' "$name" >&2; exit 1; }
    exec sh "$DIR/$name.sh" ;;
  help)
    echo "usage: tool.sh {list|schemas|schema NAME|call NAME|NAME}" ;;
  *)
    [ -f "$DIR/$sub.sh" ] || { printf 'unknown tool: %s\n' "$sub" >&2; exit 1; }
    exec sh "$DIR/$sub.sh" "$@" ;;
esac
