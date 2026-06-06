#!/usr/bin/env sh
# The dependency-free REPL, driven non-interactively (piped stdin).

test_repl_quit_exits_clean() {
  printf '/quit\n' | hsh repl rt >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 0 'exit code'
}

test_repl_eof_exits_clean() {
  : | hsh repl rt >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 0 'exit code'
}

test_repl_message_is_recorded() {
  printf '%s\n' 'hi there' '/quit' | hsh repl rt >/dev/null 2>&1
  assert_contains "$(hsh show rt)" 'hi there'
}

test_repl_slash_skill_runs() {
  printf '%s\n' '/review' '/quit' | hsh repl rt >/dev/null 2>&1
  # the review skill's instructions get injected as a user message
  assert_contains "$(hsh show rt)" 'review'
}
