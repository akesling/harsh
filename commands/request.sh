#!/usr/bin/env sh
# request — print the full Messages-API request body that a step would send.
# Composes the `assemble` primitive with the tool schemas (debug aid). The jq
# body mirrors build_request in harsh.sh — keep the two in sync, including the
# HARSH_CACHE cache_control breakpoints.
set -u
[ "${1:-}" = --describe ] && { printf 'request SESSION\tPrint the full request body that would be sent.\n'; exit 0; }
_msgs=$(sh "${HARSH_SELF}" assemble "$1")
_tools=$(sh "${HARSH_TOOLS_DIR}/tool.sh" schemas 2>/dev/null); [ -n "${_tools}" ] || _tools='[]'
_cache=true; case "${HARSH_CACHE:-1}" in 0|no|off|'') _cache=false ;; esac
jq -n --arg model "${HARSH_MODEL}" --argjson max "${HARSH_MAX_TOKENS}" \
      --arg sys "${HARSH_SYSTEM_PROMPT}" --argjson tools "${_tools}" \
      --argjson msgs "${_msgs}" --argjson cache "${_cache}" '
  def bp: {cache_control:{type:"ephemeral"}};
  {
    model: $model,
    max_tokens: $max,
    system: (if $cache then [{type:"text", text:$sys} + bp] else $sys end),
    tools: $tools,
    messages: (if ($cache and ($msgs|length>0)
                   and (($msgs[-1].content|type)=="array")
                   and (($msgs[-1].content|length)>0))
               then ($msgs | .[-1].content[-1] += bp)
               else $msgs end)
  }'
