#!/usr/bin/env sh
# request — print the full Messages-API request body that a step would send.
# Composes the `assemble` primitive with the tool schemas (debug aid).
set -u
[ "${1:-}" = --describe ] && { printf 'request SESSION\tPrint the full request body that would be sent.\n'; exit 0; }
_msgs=$(sh "${HARSH_SELF}" assemble "$1")
_tools=$(sh "${HARSH_TOOLS_DIR}/tool.sh" schemas 2>/dev/null); [ -n "${_tools}" ] || _tools='[]'
jq -n --arg model "${HARSH_MODEL}" --argjson max "${HARSH_MAX_TOKENS}" \
      --arg sys "${HARSH_SYSTEM_PROMPT}" --argjson tools "${_tools}" --argjson msgs "${_msgs}" \
      '{model:$model, max_tokens:$max, system:$sys, tools:$tools, messages:$msgs}'
