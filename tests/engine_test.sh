#!/usr/bin/env sh
# Engine failure paths: API errors, max_tokens truncation, parallel tool use,
# transient-HTTP retry, and the streaming reconstruction transform. All
# offline: the mock provides failure fixtures; the retry test stubs curl.

test_api_error_fails_the_turn() {
  _s=$(hnew eerr)
  _out=$(hsh ask "${_s}" 'please [[mock:error]]' 2>&1); _rc=$?
  assert_ne "${_rc}" 0 'an API error body must fail the turn'
  assert_contains "${_out}" 'mock API error'
}

test_truncated_reply_warns_and_continues() {
  _s=$(hnew etrunc)
  _out=$(hsh ask "${_s}" 'please [[mock:truncate]]' 2>&1); _rc=$?
  assert_eq 0 "${_rc}" 'truncation should not fail the run'
  assert_contains "${_out}" 'truncated at HARSH_MAX_TOKENS'
  # The loop re-stepped: the truncated assistant turn is followed by a
  # continuation turn, so the session holds at least two assistant entries.
  _n=$(grep -c ',assistant,' "$(hsh path "${_s}")/manifest.csv")
  [ "${_n}" -ge 2 ] || fail "expected a continuation turn, got ${_n} assistant entries"
}

test_parallel_tool_use_runs_every_call() {
  _s=$(hnew emulti)
  hsh -q ask "${_s}" 'go [[mock:multitool]]' >/dev/null 2>&1 || fail "multitool run failed"
  _dir=$(hsh path "${_s}")
  _n=$(grep -c ',tool_result,' "${_dir}/manifest.csv")
  assert_eq 2 "${_n}" 'both parallel tool calls must produce results'
  _all=$(cat "${_dir}"/[0-9]*-user-tool_result*.json)
  assert_contains "${_all}" 'one'
  assert_contains "${_all}" 'two'
}

# A curl stub on PATH: first call answers HTTP 429, second 200. Lets the real
# call_api retry loop run with no network and no mock.
make_fake_curl() {
  _bin=$1
  mkdir -p "${_bin}"
  cat > "${_bin}/curl" <<'EOF'
#!/bin/sh
_out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) _out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > /dev/null   # consume the request body
if [ ! -f "${FAKE_CURL_STATE}" ]; then
  : > "${FAKE_CURL_STATE}"
  printf '{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}' > "${_out}"
  printf '429'
else
  printf '{"content":[{"type":"text","text":"recovered"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}' > "${_out}"
  printf '200'
fi
EOF
  chmod +x "${_bin}/curl"
}

test_transient_http_error_is_retried() {
  _d=$(mktemp -d)
  make_fake_curl "${_d}/bin"
  _s=$(hnew eretry)
  _out=$(PATH="${_d}/bin:${PATH}" FAKE_CURL_STATE="${_d}/state" \
         HARSH_MOCK='' HARSH_API_KEY=test-key HARSH_RETRY_DELAY=0 HARSH_STREAM=0 \
         hsh ask "${_s}" 'hello' 2>&1); _rc=$?
  assert_eq 0 "${_rc}" "retried run should succeed: ${_out}"
  assert_contains "${_out}" '[retry] HTTP 429'
  assert_contains "$(hsh final "${_s}")" 'recovered'
  rm -rf "${_d}"
}

test_retries_exhausted_fails() {
  _d=$(mktemp -d)
  mkdir -p "${_d}/bin"
  # Always-429 curl stub.
  cat > "${_d}/bin/curl" <<'EOF'
#!/bin/sh
_out=""
while [ $# -gt 0 ]; do case "$1" in -o) _out=$2; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
printf '{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}' > "${_out}"
printf '429'
EOF
  chmod +x "${_d}/bin/curl"
  _s=$(hnew eretryx)
  _out=$(PATH="${_d}/bin:${PATH}" HARSH_MOCK='' HARSH_API_KEY=test-key \
         HARSH_RETRY_DELAY=0 HARSH_RETRIES=2 HARSH_STREAM=0 \
         hsh ask "${_s}" 'hello' 2>&1); _rc=$?
  assert_ne "${_rc}" 0 'exhausted retries must fail the turn'
  assert_contains "${_out}" 'failed after 2 retries'
  rm -rf "${_d}"
}

test_stream_assemble_reconstructs_response() {
  _resp=$(hsh stream-assemble <<'EOF'
event: message_start
data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"m","content":[],"stop_reason":null,"usage":{"input_tokens":25,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: ping
data: {"type":"ping"}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"bash","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"ls\"}"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}

event: message_stop
data: {"type":"message_stop"}
EOF
)
  assert_eq 'Hello world' "$(printf '%s' "${_resp}" | jq -r '.content[0].text')" 'text deltas concatenate'
  assert_eq 'ls' "$(printf '%s' "${_resp}" | jq -r '.content[1].input.command')" 'tool input parses from partial json'
  assert_eq 'tool_use' "$(printf '%s' "${_resp}" | jq -r '.stop_reason')" 'stop_reason from message_delta'
  assert_eq '42' "$(printf '%s' "${_resp}" | jq -r '.usage.output_tokens')" 'usage merges the output side'
}
