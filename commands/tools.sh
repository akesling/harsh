#!/usr/bin/env sh
# tools — list available tools (name + description) from the tools dir.
set -u
[ "${1:-}" = --describe ] && { printf 'tools\tList available tools.\n'; exit 0; }
sh "${HARSH_TOOLS_DIR}/tool.sh" schemas | jq -r '.[] | "• " + .name + " — " + (.description // "")'
