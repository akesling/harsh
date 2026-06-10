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
_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

# Tool names come from the model — sanitize them the same way harsh.sh's
# resolve_command sanitizes command names, so a name can never path-escape
# this directory (e.g. "../x"). Prints the cleaned name.
safe_name() { printf '%s' "$1" | tr -cd 'A-Za-z0-9_-'; }

_sub=${1:-help}; [ $# -gt 0 ] && shift

case "${_sub}" in
  list)
    for _t in "${_dir}"/*.sh; do
      [ -e "${_t}" ] || continue
      _b=$(basename "${_t}" .sh)
      [ "${_b}" = tool ] && continue
      printf '%s\n' "${_b}"
    done ;;
  schemas)
    for _t in "${_dir}"/*.sh; do
      [ -e "${_t}" ] || continue
      _b=$(basename "${_t}" .sh)
      [ "${_b}" = tool ] && continue
      sh "${_t}" --schema 2>/dev/null
    done | jq -s '.' ;;
  schema)
    [ $# -ge 1 ] || { echo "tool.sh schema NAME" >&2; exit 2; }
    _name=$(safe_name "$1")
    { [ -n "${_name}" ] && [ -f "${_dir}/${_name}.sh" ]; } || { printf 'unknown tool: %s\n' "$1" >&2; exit 1; }
    exec sh "${_dir}/${_name}.sh" --schema ;;
  call)
    [ $# -ge 1 ] || { echo "tool.sh call NAME" >&2; exit 2; }
    _name=$(safe_name "$1")
    { [ -n "${_name}" ] && [ -f "${_dir}/${_name}.sh" ]; } || { printf 'unknown tool: %s\n' "$1" >&2; exit 1; }
    exec sh "${_dir}/${_name}.sh" ;;
  help)
    echo "usage: tool.sh {list|schemas|schema NAME|call NAME|NAME}" ;;
  *)
    _name=$(safe_name "${_sub}")
    { [ -n "${_name}" ] && [ -f "${_dir}/${_name}.sh" ]; } || { printf 'unknown tool: %s\n' "${_sub}" >&2; exit 1; }
    exec sh "${_dir}/${_name}.sh" "$@" ;;
esac
