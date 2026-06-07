#!/usr/bin/env sh
# The hooks system: every event, blocking vs. context, and per-tool scoping.
# Each test installs hooks into its own sandbox hooks dir (HARSH_HOOKS_DIR).

test_sessionstart_injects_context() {
  install_hook SessionStart/10.sh <<'EOF'
echo "BOOT-CTX"
EOF
  _s=$(hnew)
  assert_contains "$(hsh show "${_s}")" 'BOOT-CTX'
}

test_userpromptsubmit_injects_context() {
  install_hook UserPromptSubmit/10.sh <<'EOF'
echo "UPS-CTX"
EOF
  _s=$(hnew)
  hsh -q send "${_s}" 'hello'
  _out=$(hsh show "${_s}")
  assert_contains "${_out}" 'UPS-CTX'
  assert_contains "${_out}" 'hello'
}

test_userpromptsubmit_block_rejects_prompt() {
  install_hook UserPromptSubmit/10.sh <<'EOF'
echo "no thanks"; exit 2
EOF
  _s=$(hnew)
  _before=$(hsh manifest "${_s}" | wc -l)
  assert_fails hsh -q send "${_s}" 'please block me'
  assert_eq "$(hsh manifest "${_s}" | wc -l)" "${_before}" 'no entry recorded'
}

test_pretooluse_allow_and_posttooluse_feedback() {
  install_hook PostToolUse/10.sh <<'EOF'
echo "POST-FB"
EOF
  _s=$(hnew)
  hsh -q ask "${_s}" 'go [[tool:bash:echo preok]]' >/dev/null
  _res=$(hsh assemble "${_s}" | jq -r '[.[].content[]|select(.type=="tool_result")][0].content')
  assert_contains "${_res}" 'preok'
  assert_contains "${_res}" 'POST-FB'
}

test_pretooluse_block_skips_tool() {
  install_hook PreToolUse/bash/10.sh <<'EOF'
echo "denied here"; exit 2
EOF
  _s=$(hnew)
  hsh -q ask "${_s}" 'go [[tool:bash:echo shouldnotrun]]' >/dev/null
  _res=$(hsh assemble "${_s}" | jq -r '[.[].content[]|select(.type=="tool_result")][0]')
  assert_contains "${_res}" 'blocked by hook'
  assert_contains "${_res}" 'denied here'
  assert_eq "$(printf '%s' "${_res}" | jq -r '.is_error')" 'true'
}

test_pretooluse_is_tool_scoped() {
  # A hook under PreToolUse/bash/ must NOT fire for a different tool (ls).
  install_hook PreToolUse/bash/10.sh <<'EOF'
echo "denied here"; exit 2
EOF
  _s=$(hnew)
  hsh -q ask "${_s}" 'go [[tool:ls:.]]' >/dev/null
  _res=$(hsh assemble "${_s}" | jq -r '[.[].content[]|select(.type=="tool_result")][0].content')
  assert_not_contains "${_res}" 'blocked by hook'
}

test_stop_hook_forces_another_turn() {
  install_hook Stop/10.sh <<'EOF'
_s="${HARSH_HOOKS_DIR}/.stopped"
if [ ! -f "${_s}" ]; then : > "${_s}"; echo "GO-AGAIN"; exit 2; fi
EOF
  _s=$(hnew)
  hsh -q ask "${_s}" 'first' >/dev/null
  assert_contains "$(hsh show "${_s}")" 'GO-AGAIN'
}

test_hooks_command_lists_installed() {
  install_hook PreToolUse/bash/42-x.sh <<'EOF'
exit 0
EOF
  _out=$(hsh hooks)
  assert_contains "${_out}" 'PreToolUse'
  assert_contains "${_out}" 'bash/42-x.sh'
}
