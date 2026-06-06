#!/usr/bin/env sh
# The hooks system: every event, blocking vs. context, and per-tool scoping.
# Each test installs hooks into its own sandbox hooks dir (HARSH_HOOKS_DIR).

test_sessionstart_injects_context() {
  install_hook SessionStart/10.sh <<'EOF'
echo "BOOT-CTX"
EOF
  s=$(hnew)
  assert_contains "$(hsh show "$s")" 'BOOT-CTX'
}

test_userpromptsubmit_injects_context() {
  install_hook UserPromptSubmit/10.sh <<'EOF'
echo "UPS-CTX"
EOF
  s=$(hnew)
  hsh -q send "$s" 'hello'
  out=$(hsh show "$s")
  assert_contains "$out" 'UPS-CTX'
  assert_contains "$out" 'hello'
}

test_userpromptsubmit_block_rejects_prompt() {
  install_hook UserPromptSubmit/10.sh <<'EOF'
echo "no thanks"; exit 2
EOF
  s=$(hnew)
  before=$(hsh manifest "$s" | wc -l)
  assert_fails hsh -q send "$s" 'please block me'
  assert_eq "$(hsh manifest "$s" | wc -l)" "$before" 'no entry recorded'
}

test_pretooluse_allow_and_posttooluse_feedback() {
  install_hook PostToolUse/10.sh <<'EOF'
echo "POST-FB"
EOF
  s=$(hnew)
  hsh -q ask "$s" 'go [[tool:bash:echo preok]]' >/dev/null
  res=$(hsh assemble "$s" | jq -r '[.[].content[]|select(.type=="tool_result")][0].content')
  assert_contains "$res" 'preok'
  assert_contains "$res" 'POST-FB'
}

test_pretooluse_block_skips_tool() {
  install_hook PreToolUse/bash/10.sh <<'EOF'
echo "denied here"; exit 2
EOF
  s=$(hnew)
  hsh -q ask "$s" 'go [[tool:bash:echo shouldnotrun]]' >/dev/null
  res=$(hsh assemble "$s" | jq -r '[.[].content[]|select(.type=="tool_result")][0]')
  assert_contains "$res" 'blocked by hook'
  assert_contains "$res" 'denied here'
  assert_eq "$(printf '%s' "$res" | jq -r '.is_error')" 'true'
}

test_pretooluse_is_tool_scoped() {
  # A hook under PreToolUse/bash/ must NOT fire for a different tool (ls).
  install_hook PreToolUse/bash/10.sh <<'EOF'
echo "denied here"; exit 2
EOF
  s=$(hnew)
  hsh -q ask "$s" 'go [[tool:ls:.]]' >/dev/null
  res=$(hsh assemble "$s" | jq -r '[.[].content[]|select(.type=="tool_result")][0].content')
  assert_not_contains "$res" 'blocked by hook'
}

test_stop_hook_forces_another_turn() {
  install_hook Stop/10.sh <<'EOF'
S="$HARSH_HOOKS_DIR/.stopped"
if [ ! -f "$S" ]; then : > "$S"; echo "GO-AGAIN"; exit 2; fi
EOF
  s=$(hnew)
  hsh -q ask "$s" 'first' >/dev/null
  assert_contains "$(hsh show "$s")" 'GO-AGAIN'
}

test_hooks_command_lists_installed() {
  install_hook PreToolUse/bash/42-x.sh <<'EOF'
exit 0
EOF
  out=$(hsh hooks)
  assert_contains "$out" 'PreToolUse'
  assert_contains "$out" 'bash/42-x.sh'
}
