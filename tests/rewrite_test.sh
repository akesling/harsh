#!/usr/bin/env sh
# PreToolUse input-rewrite channel: a hook may replace tool_input by writing a
# new payload to $HARSH_HOOK_REWRITE_OUT; the engine adopts its .tool_input,
# chains rewrites across ordered hooks, ignores garbage, and is a no-op when no
# hook rewrites (backward compatible).

# Install a hook (at path $1) that prepends `echo $2; ` to the bash command —
# runnable and composable, so the marker $2 shows up in the command's output
# and chained rewriters nest visibly.
install_rewriter() {
  install_hook "$1" <<EOF
#!/usr/bin/env sh
set -u
_p=\$(cat)
_cmd=\$(printf '%s' "\${_p}" | jq -r '.tool_input.command // empty')
[ -n "\${_cmd}" ] || exit 0
printf '%s' "\${_p}" | jq -c --arg c "echo ${2}; \${_cmd}" '.tool_input.command = \$c' > "\${HARSH_HOOK_REWRITE_OUT}"
exit 0
EOF
}

# Run a bash tool call through the engine via the mock and return what actually
# executed (the tool_result content).
ran_command() {
  _s=$(hnew "$1")
  hsh -q ask "${_s}" "go [[tool:bash:${2}]]" >/dev/null 2>&1
  hsh assemble "${_s}" | jq -r '.[].content[] | select(.type=="tool_result") | .content'
}

test_hook_rewrites_tool_input() {
  install_rewriter PreToolUse/50-rw.sh REWMARK
  _out=$(ran_command rw1 'echo base-out')
  assert_contains "${_out}" 'REWMARK'
  assert_contains "${_out}" 'base-out'
}

test_no_rewrite_is_unchanged() {
  # No rewriting hook installed -> the original command runs verbatim.
  _out=$(ran_command rw2 'echo plain-output')
  assert_contains "${_out}" 'plain-output'
  assert_not_contains "${_out}" 'REWMARK'
}

test_rewrites_chain_in_filename_order() {
  # 10 wraps first, 20 wraps the result, so the executed command is
  # "echo BEE; echo AYE; <base>" — both markers run, 20's outermost.
  install_rewriter PreToolUse/10-a.sh AYE
  install_rewriter PreToolUse/20-b.sh BEE
  _out=$(ran_command rw3 'echo BASEOUT')
  assert_contains "${_out}" 'AYE'
  assert_contains "${_out}" 'BEE'
  assert_contains "${_out}" 'BASEOUT'
}

test_invalid_rewrite_is_ignored() {
  # A hook that writes garbage to the slot must not corrupt the call; the
  # original command still runs.
  install_hook PreToolUse/50-bad.sh <<'EOF'
#!/usr/bin/env sh
set -u
cat >/dev/null
printf 'not json at all' > "${HARSH_HOOK_REWRITE_OUT}"
exit 0
EOF
  _out=$(ran_command rw4 'echo still-here')
  assert_contains "${_out}" 'still-here'
}

test_rewrite_then_deny_still_blocks() {
  # An ordered rewriter (10) followed by a denier (20): the deny wins and the
  # tool never runs.
  install_rewriter PreToolUse/10-rw.sh REWMARK
  install_hook PreToolUse/20-deny.sh <<'EOF'
#!/usr/bin/env sh
cat >/dev/null
echo "nope"; exit 2
EOF
  _s=$(hnew rw5)
  hsh -q ask "${_s}" 'go [[tool:bash:something]]' >/dev/null 2>&1
  _res=$(hsh assemble "${_s}" | jq -r '.[].content[] | select(.type=="tool_result") | .content')
  assert_contains "${_res}" 'blocked by hook'
  assert_not_contains "${_res}" 'REWMARK'
}
