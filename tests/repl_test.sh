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

test_repl_bracketed_paste_is_one_prompt() {
  # A multi-line bracketed paste (ESC[200~ … ESC[201~) must become ONE prompt,
  # not one-per-line. Feed the markers literally and check the recorded message.
  _beg=$(printf '\033[200~'); _end=$(printf '\033[201~')
  printf '%sline one\nline two\nline three%s\n/quit\n' "${_beg}" "${_end}" \
    | hsh repl pastesess >/dev/null 2>&1
  # The three lines land in a single user-text entry (count user/text after any
  # injected context): assert all three are present in one block.
  _msg=$(hsh assemble pastesess \
    | jq -r '[.[] | select(.role=="user") | .content[]? | select(.type=="text") | .text]
             | map(select(test("line one"))) | .[0] // ""')
  assert_contains "${_msg}" 'line one'
  assert_contains "${_msg}" 'line two'
  assert_contains "${_msg}" 'line three'
  # And the markers themselves are stripped.
  assert_not_contains "${_msg}" '200~'
  assert_not_contains "${_msg}" '201~'
}

test_repl_paste_works_even_with_rlwrap_optin() {
  # Regression: paste cohesion must not depend on rlwrap being absent. rlwrap is
  # opt-in (HARSH_RLWRAP=1) and CANNOT preserve multi-line pastes, so the native
  # bracketed-paste loop owns paste. Even with the opt-in set, a piped (non-TTY)
  # run takes the native loop and stitches the paste into ONE prompt.
  _beg=$(printf '\033[200~'); _end=$(printf '\033[201~')
  printf '%salpha\nbeta\ngamma%s\n/quit\n' "${_beg}" "${_end}" \
    | HARSH_RLWRAP=1 hsh repl pasteopt >/dev/null 2>&1
  _msg=$(hsh assemble pasteopt \
    | jq -r '[.[] | select(.role=="user") | .content[]? | select(.type=="text") | .text]
             | map(select(test("alpha"))) | .[0] // ""')
  assert_contains "${_msg}" 'alpha'
  assert_contains "${_msg}" 'beta'
  assert_contains "${_msg}" 'gamma'
  assert_not_contains "${_msg}" '200~'
}

test_repl_strips_stray_cursor_escapes_from_typed_line() {
  # Without readline, ↑/↓/←/→ emit CSI escapes (ESC[A, ESC[1~, …) that `read`
  # would capture as literal junk. A TYPED line must have them scrubbed.
  _up=$(printf '\033[A'); _dn=$(printf '\033[B'); _home=$(printf '\033[1~')
  printf '%s%s%shello world%s\n/quit\n' "${_up}" "${_dn}" "${_home}" "${_dn}" \
    | hsh repl navscrub >/dev/null 2>&1
  _msg=$(hsh show navscrub)
  assert_contains "${_msg}" 'hello world'
  assert_not_contains "${_msg}" '[A'
  assert_not_contains "${_msg}" '[B'
  assert_not_contains "${_msg}" '[1~'
}

test_repl_paste_keeps_bracket_content_intact() {
  # The nav-scrub must NOT touch pastes: a pasted snippet may legitimately
  # contain bracket/escape-like text. Bracketed paste is left verbatim.
  _beg=$(printf '\033[200~'); _end=$(printf '\033[201~')
  printf '%sarr[0] = x\nif (a[i] > 0)%s\n/quit\n' "${_beg}" "${_end}" \
    | hsh repl pastebr >/dev/null 2>&1
  _msg=$(hsh show pastebr)
  assert_contains "${_msg}" 'arr[0] = x'
  assert_contains "${_msg}" 'if (a[i] > 0)'
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
