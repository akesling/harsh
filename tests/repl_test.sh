#!/usr/bin/env sh
# The dependency-free REPL, driven non-interactively (piped stdin).

test_repl_quit_exits_clean() {
  printf '/quit\n' | hsh repl rt >/dev/null 2>&1; _rc=$?
  assert_eq "${_rc}" 0 'exit code'
}

test_repl_eof_exits_clean() {
  : | hsh repl rt >/dev/null 2>&1; _rc=$?
  assert_eq "${_rc}" 0 'exit code'
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

test_repl_sessions_lists_past_sessions() {
  hsh new alpha-sess >/dev/null
  printf '%s\n' '/sessions' '/quit' | hsh repl rt >/dev/null 2>&1
  _out=$(printf '%s\n' '/sessions' '/quit' | hsh repl rt 2>&1)
  assert_contains "${_out}" 'alpha-sess'
}

test_repl_resume_switches_session() {
  # Seed a target session with a distinctive message.
  printf '%s\n' 'marker-in-target' '/quit' | hsh repl tgt-sess >/dev/null 2>&1
  # From a different session, /resume should switch and show the target.
  _out=$(printf '%s\n' '/resume tgt-sess' '/session' '/quit' | hsh repl other-sess 2>&1)
  assert_contains "${_out}" 'tgt-sess'
  assert_contains "${_out}" 'marker-in-target'
}

test_show_is_styled_not_raw() {
  # `show` (used by /resume) must replay with speaker headers, not the old
  # bare "[role/type] text" dump. Force color so the styled path is exercised.
  _s=$(hnew styled)
  hsh -q ask "${_s}" 'styled marker' >/dev/null
  _out=$(HARSH_COLOR=1 hsh show "${_s}")
  assert_contains "${_out}" 'styled marker'
  assert_contains "${_out}" 'you'            # speaker header
  assert_contains "${_out}" 'harsh'          # assistant header
  assert_not_contains "${_out}" '[user/text]'
  assert_not_contains "${_out}" '[assistant/text]'
}

test_repl_resume_unknown_is_reported() {
  _out=$(printf '%s\n' '/resume nope-nonexistent' '/quit' | hsh repl rt 2>&1)
  assert_contains "${_out}" 'no such session'
}

test_repl_resume_without_arg_shows_usage() {
  _out=$(printf '%s\n' '/resume' '/quit' | hsh repl rt 2>&1)
  assert_contains "${_out}" 'usage'
}

test_verbose_expands_entry_by_seq() {
  _s=$(hnew vexp)
  hsh -q ask "${_s}" 'go [[tool:bash:echo verbosemarker]]' >/dev/null
  # the collapsed REPL line hides tool output, but `verbose SEQ` brings it back.
  # the tool_result is the highest-numbered entry; find it from the manifest.
  _seq=$(awk -F, '$3=="tool_result"{s=$1} END{print s}' "${_s}/manifest.csv")
  assert_contains "$(hsh verbose "${_s}" "${_seq}")" 'verbosemarker'
}

test_verbose_tolerates_hash_and_unpadded_seq() {
  _s=$(hnew vexp2)
  hsh -q ask "${_s}" 'go [[tool:bash:echo hashok]]' >/dev/null
  _seq=$(awk -F, '$3=="tool_result"{s=$1} END{print s}' "${_s}/manifest.csv")
  _unpadded=$(printf '%s' "${_seq}" | sed 's/^0*//')
  assert_contains "$(hsh verbose "${_s}" "#${_unpadded}")" 'hashok'
}

test_verbose_bad_seq_is_error() {
  _s=$(hnew vexp3)
  hsh verbose "${_s}" 'notanumber' >/dev/null 2>&1; _rc=$?
  assert_eq "${_rc}" 1 'non-numeric SEQ is rejected'
}
