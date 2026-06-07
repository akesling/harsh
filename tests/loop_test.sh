#!/usr/bin/env sh
# Core agent loop, on-disk format, and Messages-API assembly. Runs under the
# mock model (HARSH_MOCK=1), so no network or API key is involved.

test_plain_text_turn() {
  _s=$(hnew)
  hsh -q ask "${_s}" 'hello there' >/dev/null
  assert_contains "$(hsh show "${_s}")" '[mock] You said: hello there'
}

test_tool_call_turn_runs_and_records_output() {
  _s=$(hnew)
  hsh -q ask "${_s}" 'run [[tool:bash:echo loopmarker]]' >/dev/null
  _res=$(hsh assemble "${_s}" | jq -r '[.[].content[]|select(.type=="tool_result")][0]')
  assert_contains "${_res}" 'loopmarker'
  assert_eq "$(printf '%s' "${_res}" | jq -r '.is_error')" 'false' 'tool not flagged as error'
}

test_wire_format_alternates_and_groups() {
  _s=$(hnew)
  hsh -q ask "${_s}" 'go [[tool:bash:echo x]]' >/dev/null
  assert_eq "$(hsh assemble "${_s}" | jq -r '[.[].role]|join(",")')" \
            'user,assistant,user,assistant' 'roles alternate'
  # the tool-calling assistant message carries text + tool_use
  assert_eq "$(hsh assemble "${_s}" | jq -c '.[1].content|map(.type)')" '["text","tool_use"]'
  # the following user message carries the tool_result
  assert_eq "$(hsh assemble "${_s}" | jq -c '.[2].content|map(.type)')" '["tool_result"]'
}

test_assemble_empty_session_is_empty_array() {
  assert_eq "$(hsh assemble "$(hnew)")" '[]'
}

test_manifest_has_columns() {
  _s=$(hnew)
  hsh -q send "${_s}" 'hi'
  _line=$(hsh manifest "${_s}" | head -1)
  assert_contains "${_line}" '0001,user,text,'
  assert_contains "${_line}" ',ok'
}
