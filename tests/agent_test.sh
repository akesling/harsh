#!/usr/bin/env sh
# Sub-agents as a tool (tools/agent.sh): a child session runs the task and only
# its final message comes back, with a depth guard. Mock model is in effect, so
# the child's final text is "[mock] You said: <task>".

# Call the agent tool with a JSON body, wiring HARSH_SELF the way harsh.sh would.
agent_call() {
  printf '%s' "$1" | HARSH_SELF="${ROOT}/harsh.sh" sh "${ROOT}/tools/tool.sh" call agent
}

test_agent_returns_child_final_message() {
  _out=$(agent_call '{"task":"do the thing"}')
  assert_contains "${_out}" '[mock] You said: do the thing'
}

test_agent_creates_inspectable_child_session() {
  agent_call '{"task":"hello","label":"greet"}' >/dev/null 2>&1
  assert_contains "$(hsh sessions)" 'agent-greet'
}

test_agent_requires_a_task() {
  printf '{}' | HARSH_SELF="${ROOT}/harsh.sh" sh "${ROOT}/tools/tool.sh" call agent >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'missing task should error'
}

test_agent_depth_guard_refuses_deep_recursion() {
  printf '{"task":"x"}' | HARSH_AGENT_DEPTH=3 HARSH_SELF="${ROOT}/harsh.sh" \
    sh "${ROOT}/tools/tool.sh" call agent >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'depth >= cap should be refused'
}

test_agent_errors_without_harsh_self() {
  printf '{"task":"x"}' | env -u HARSH_SELF sh "${ROOT}/tools/tool.sh" call agent >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'no HARSH_SELF should error'
}

# --- the supporting harness pieces -----------------------------------------

test_final_returns_last_assistant_text() {
  _s=$(hnew finaltest)
  hsh -q ask "${_s}" 'first thing' >/dev/null
  assert_contains "$(hsh final "${_s}")" '[mock] You said: first thing'
}

test_final_empty_session_is_blank() {
  assert_eq "$(hsh final "$(hnew emptyf)")" ''
}

test_harness_exports_self_to_tools() {
  _s=$(hnew selftest)
  # $HARSH_SELF stays literal here on purpose — the child's bash tool expands it.
  # shellcheck disable=SC2016
  hsh -q ask "${_s}" 'go [[tool:bash:printf SELF=%s $HARSH_SELF]]' >/dev/null
  _res=$(hsh assemble "${_s}" | jq -r '[.[].content[]|select(.type=="tool_result").content][0]')
  assert_contains "${_res}" 'harsh.sh'
}