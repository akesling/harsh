#!/usr/bin/env sh
# final — print a session's last assistant text (the sub-agent result contract).
set -u
[ "${1:-}" = --describe ] && { printf 'final SESSION\tPrint the last assistant message (sub-agent result).\n'; exit 0; }
_dir=$(sh "${HARSH_SELF}" path "$1")
set -- "${_dir}"/[0-9]*.json
[ -e "$1" ] || exit 0
jq -rs '[.[] | select(.role=="assistant" and .block.type=="text") | .block.text]
        | last // ""' "$@"
