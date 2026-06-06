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

test_verbose_expands_entry_by_seq() {
  s=$(hnew vexp)
  hsh -q ask "$s" 'go [[tool:bash:echo verbosemarker]]' >/dev/null
  # the collapsed REPL line hides tool output, but `verbose SEQ` brings it back.
  # the tool_result is the highest-numbered entry; find it from the manifest.
  seq=$(awk -F, '$3=="tool_result"{s=$1} END{print s}' "$s/manifest.csv")
  assert_contains "$(hsh verbose "$s" "$seq")" 'verbosemarker'
}

test_verbose_tolerates_hash_and_unpadded_seq() {
  s=$(hnew vexp2)
  hsh -q ask "$s" 'go [[tool:bash:echo hashok]]' >/dev/null
  seq=$(awk -F, '$3=="tool_result"{s=$1} END{print s}' "$s/manifest.csv")
  unpadded=$(printf '%s' "$seq" | sed 's/^0*//')
  assert_contains "$(hsh verbose "$s" "#$unpadded")" 'hashok'
}

test_verbose_bad_seq_is_error() {
  s=$(hnew vexp3)
  hsh verbose "$s" 'notanumber' >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 1 'non-numeric SEQ is rejected'
}