#!/usr/bin/env sh
# Prompt caching: the request body carries cache_control breakpoints (so the
# repeated prefix bills at the cache rate), HARSH_CACHE=0 turns it off, and the
# `usage` command tallies token usage from the response log.

test_request_has_cache_breakpoints() {
  _s=$(hnew ctest)
  hsh -q send "${_s}" 'hello there'
  _req=$(hsh request "${_s}")
  # system is rendered as a block array carrying a breakpoint (covers tools+system)
  assert_eq "$(printf '%s' "${_req}" | jq -r '.system|type')" 'array' 'system is a block array'
  assert_eq "$(printf '%s' "${_req}" | jq -r '.system[0].cache_control.type')" 'ephemeral'
  # plus a breakpoint on the final message block (caches the conversation prefix)
  assert_eq "$(printf '%s' "${_req}" | jq -r '.messages[-1].content[-1].cache_control.type')" 'ephemeral'
  # two breakpoints total — well within the 4-per-request limit
  assert_eq "$(printf '%s' "${_req}" | jq '[.. | objects | select(has("cache_control"))] | length')" '2'
}

test_cache_can_be_disabled() {
  _s=$(hnew cdis)
  hsh -q send "${_s}" 'hello there'
  _req=$(HARSH_CACHE=0 hsh request "${_s}")
  assert_eq "$(printf '%s' "${_req}" | jq -r '.system|type')" 'string' 'system stays a plain string'
  assert_eq "$(printf '%s' "${_req}" | jq '[.. | objects | select(has("cache_control"))] | length')" '0'
}

test_cached_request_still_sends_through_the_loop() {
  # End-to-end under the mock: caching markers must not disturb assembly/tools.
  _s=$(hnew cflow)
  hsh -q ask "${_s}" 'go [[tool:bash:echo cachemarker]]' >/dev/null
  _res=$(hsh assemble "${_s}" | jq -r '[.[].content[]|select(.type=="tool_result")][0].content')
  assert_contains "${_res}" 'cachemarker'
}

test_usage_tallies_response_log() {
  _s=$(hnew utest)
  # logs and sessions are siblings in the sandbox tempdir.
  _logdir=$(dirname "$(dirname "$(hsh path "${_s}")")")/logs
  mkdir -p "${_logdir}"
  _row='{"usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"output_tokens":50}}'
  printf '%s\n%s\n' "${_row}" "${_row}" > "${_logdir}/$(basename "$(hsh path "${_s}")").response.log"
  _out=$(hsh usage "${_s}")
  assert_contains "${_out}" 'calls: 2'
  assert_contains "${_out}" 'cache reads (0.1x): 1800'
  assert_contains "${_out}" 'cache hit rate: 90%'
  assert_contains "${_out}" 'est. cost:'
}

test_usage_without_log_is_graceful() {
  _s=$(hnew unolog)
  assert_contains "$(hsh usage "${_s}")" 'no usage recorded yet'
}
