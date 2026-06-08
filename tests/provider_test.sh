#!/usr/bin/env sh
# Provider abstraction (HARSH_PROVIDER). The OpenAI path translates harsh's
# canonical messages into Chat Completions and folds the response back into
# canonical blocks; the mock emits provider-shaped replies so the whole loop
# runs offline. Anthropic stays the default and is unchanged.

oai() { HARSH_PROVIDER=openai hsh "$@"; }

test_openai_request_is_chat_completions_shape() {
  _s=$(oai new oaireq)
  oai -q send "${_s}" 'hello world' >/dev/null
  _req=$(oai request "${_s}")
  assert_eq "$(printf '%s' "${_req}" | jq -r '.messages[0].role')" 'system' 'leading system message'
  assert_eq "$(printf '%s' "${_req}" | jq -r 'has("max_completion_tokens")')" 'true'
  assert_eq "$(printf '%s' "${_req}" | jq -r 'has("system")')" 'false' 'no anthropic top-level system'
  assert_eq "$(printf '%s' "${_req}" | jq -r '.tools[0].type')" 'function' 'tools wrapped as function'
  assert_contains "$(printf '%s' "${_req}" | jq -r '[.tools[].function.name]|join(",")')" 'bash' 'bash tool present'
}

test_openai_has_no_cache_control() {
  # HARSH_CACHE defaults on, but cache_control is Anthropic-only — OpenAI auto-caches.
  _s=$(oai new oainocache)
  oai -q send "${_s}" 'hi' >/dev/null
  assert_eq "$(HARSH_CACHE=1 oai request "${_s}" | jq '[.. | objects | select(has("cache_control"))] | length')" '0'
}

test_openai_text_turn_normalizes_to_blocks() {
  _s=$(oai new oaitext)
  oai -q ask "${_s}" 'ping' >/dev/null
  # the mock's choices[].message.content becomes a canonical text block
  assert_contains "$(oai show "${_s}")" '[mock] You said: ping'
  assert_eq "$(oai assemble "${_s}" | jq -r '.[-1].content[-1].type')" 'text'
}

test_openai_tool_turn_links_ids_and_terminates() {
  _s=$(oai new oaitool)
  oai -q ask "${_s}" 'go [[tool:bash:echo OAIMARK]]' >/dev/null 2>&1
  assert_contains "$(oai assemble "${_s}" | jq -r '[.[].content[]|select(.type=="tool_result").content][0]')" 'OAIMARK'
  _req=$(oai request "${_s}")
  # exactly one tool round-trip (no runaway), and the assistant tool_calls id
  # matches the tool message's tool_call_id.
  assert_eq "$(printf '%s' "${_req}" | jq '[.messages[]|select(.role=="tool")]|length')" '1' 'single tool turn'
  _cid=$(printf '%s' "${_req}" | jq -r '[.messages[]|select(.role=="assistant")|.tool_calls[]?.id]|unique|join(",")')
  _tid=$(printf '%s' "${_req}" | jq -r '[.messages[]|select(.role=="tool")|.tool_call_id]|unique|join(",")')
  assert_eq "${_cid}" "${_tid}" 'tool_call ids link assistant -> tool message'
}

test_openai_tool_use_block_is_canonical() {
  _s=$(oai new oaiblock)
  oai -q ask "${_s}" 'go [[tool:bash:echo X]]' >/dev/null 2>&1
  _tu=$(oai assemble "${_s}" | jq -c '[.[].content[]|select(.type=="tool_use")][0]')
  assert_eq "$(printf '%s' "${_tu}" | jq -r '.name')" 'bash'
  assert_eq "$(printf '%s' "${_tu}" | jq -r '.input.command')" 'echo X' 'arguments parsed from JSON string'
}

test_openai_usage_is_tallied() {
  # usage coalesces OpenAI field names (prompt_tokens / completion_tokens /
  # prompt_tokens_details.cached_tokens) from the raw response log.
  _s=$(oai new oaiusage)
  oai -q ask "${_s}" 'hello' >/dev/null
  _out=$(oai usage "${_s}")
  assert_contains "${_out}" 'cache reads (0.1x):'
  assert_not_contains "${_out}" 'no usage recorded yet'
}

test_unknown_provider_is_rejected() {
  HARSH_PROVIDER=frobnicate hsh assemble "$(hnew up)" >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'unknown HARSH_PROVIDER must error'
}

test_anthropic_is_the_default_shape() {
  _s=$(hnew antshape)
  hsh -q send "${_s}" 'hi' >/dev/null
  _req=$(hsh request "${_s}")
  assert_eq "$(printf '%s' "${_req}" | jq -r 'has("system")')" 'true' 'anthropic top-level system'
  assert_eq "$(printf '%s' "${_req}" | jq -r 'has("max_completion_tokens")')" 'false'
  assert_eq "$(printf '%s' "${_req}" | jq -r '.tools[0]|has("input_schema")')" 'true' 'anthropic tool schema'
}
