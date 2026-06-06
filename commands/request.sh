#!/usr/bin/env sh
# request — print the full Messages-API request body that a step would send.
# Composes the `assemble` primitive with the tool schemas (debug aid).
set -u
[ "${1:-}" = --describe ] && { printf 'request SESSION\tPrint the full request body that would be sent.\n'; exit 0; }
msgs=$(sh "$HARSH_SELF" assemble "$1")
tools=$(sh "$HARSH_TOOLS_DIR/tool.sh" schemas 2>/dev/null); [ -n "$tools" ] || tools='[]'
jq -n --arg model "$HARSH_MODEL" --argjson max "$HARSH_MAX_TOKENS" \
      --arg sys "$HARSH_SYSTEM_PROMPT" --argjson tools "$tools" --argjson msgs "$msgs" \
      '{model:$model, max_tokens:$max, system:$sys, tools:$tools, messages:$msgs}'
