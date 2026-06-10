#!/usr/bin/env sh
# The permission gate (hooks/PreToolUse/10-permissions.sh): declarative layered
# policy, allow/ask/deny, interactive "ask" via the TTY seam with session-grant
# persistence, fail-closed when non-interactive, audit trail, and end-to-end
# enforcement through the engine.

GATE="${ROOT}/hooks/PreToolUse/10-permissions.sh"

# pg DIR TOOL ARG  — invoke the gate directly with a payload; env (mode, TTY
# seam) is set by the caller. Captures stdout; returns the gate's exit code.
pg() {
  _pgdir=$1; _pgtool=$2; _pgarg=${3:-}
  jq -nc --arg s "${_pgdir}" --arg t "${_pgtool}" --arg a "${_pgarg}" \
    '{session_dir:$s, tool_name:$t,
      tool_input: (if $a=="" then {} else {command:$a,path:$a,pattern:$a,name:$a} end)}' \
  | sh "${GATE}"
}

# Copy the real gate + its lib into the sandbox hooks dir so the engine runs it.
install_real_gate() {
  mkdir -p "${HARSH_HOOKS_DIR}/PreToolUse" "${HARSH_HOOKS_DIR}/lib"
  cp "${GATE}" "${HARSH_HOOKS_DIR}/PreToolUse/10-permissions.sh"
  cp "${ROOT}/hooks/lib/permissions.sh" "${HARSH_HOOKS_DIR}/lib/permissions.sh"
}

test_dormant_without_optin() {
  _d=$(mktemp -d)
  # No mode, no policy file: gate allows everything silently (rc 0, no output).
  _out=$(pg "${_d}" bash 'rm -rf / now'); _rc=$?
  assert_eq 0 "${_rc}" 'dormant gate allows'
  assert_eq '' "${_out}" 'dormant gate is silent'
  [ -f "${_d}/permissions.log" ] && fail 'dormant gate should not audit'
  rm -rf "${_d}"
}

test_readonly_tools_auto_allow() {
  _d=$(mktemp -d)
  HARSH_PERMISSIONS_MODE=ask pg "${_d}" read x >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'read auto-allowed by the built-in default'
  rm -rf "${_d}"
}

test_destructive_denied_with_teaching_reason() {
  _d=$(mktemp -d)
  _out=$(HARSH_PERMISSIONS_MODE=ask pg "${_d}" bash 'sudo rm -rf / x'); _rc=$?
  assert_eq 2 "${_rc}" 'destructive command denied'
  assert_contains "${_out}" 'destructive'
  assert_contains "${_out}" 'Ask the user'
  rm -rf "${_d}"
}

test_ask_without_tty_fails_closed() {
  _d=$(mktemp -d)
  _out=$(HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY=/nonexistent pg "${_d}" bash 'make'); _rc=$?
  assert_eq 2 "${_rc}" 'ask with no terminal denies (fail closed)'
  assert_contains "${_out}" 'no terminal'
  rm -rf "${_d}"
}

test_noninteractive_allow_policy_opens_the_gate() {
  _d=$(mktemp -d)
  printf '{"noninteractive":"allow","rules":[]}' > "${_d}/permissions.json"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY=/nonexistent pg "${_d}" bash 'make' >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'noninteractive:allow lets unattended calls through'
  rm -rf "${_d}"
}

test_ask_yes_allows_once_without_persisting() {
  _d=$(mktemp -d); printf 'y\n' > "${_d}/ans"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_d}/ans" pg "${_d}" bash 'make' >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'yes allows'
  [ -f "${_d}/permissions.json" ] && fail 'yes must not persist a grant'
  rm -rf "${_d}"
}

test_ask_always_persists_session_grant() {
  _d=$(mktemp -d); printf 'a\n' > "${_d}/ans"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_d}/ans" pg "${_d}" bash 'make' >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'always allows'
  assert_contains "$(cat "${_d}/permissions.json")" '"tool":"bash"'
  # The grant now auto-allows without a terminal.
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY=/nonexistent pg "${_d}" bash 'other' >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'session grant auto-allows subsequent calls'
  rm -rf "${_d}"
}

test_ask_no_denies_and_tells_model() {
  _d=$(mktemp -d); printf 'n\n' > "${_d}/ans"
  _out=$(HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_d}/ans" pg "${_d}" bash 'make'); _rc=$?
  assert_eq 2 "${_rc}" 'no denies'
  assert_contains "${_out}" 'declined'
  rm -rf "${_d}"
}

test_session_layer_overrides_builtin() {
  _d=$(mktemp -d)
  # Session policy denies read, which the built-in would allow. Session wins.
  printf '{"rules":[{"tool":"read","decision":"deny","reason":"no reads here"}]}' > "${_d}/permissions.json"
  _out=$(pg "${_d}" read somefile); _rc=$?
  assert_eq 2 "${_rc}" 'session deny overrides built-in allow'
  assert_contains "${_out}" 'no reads here'
  rm -rf "${_d}"
}

test_mode_override_changes_default() {
  _d=$(mktemp -d)
  # An unmatched tool: mode=deny makes the default deny.
  HARSH_PERMISSIONS_MODE=deny HARSH_PERMISSIONS_TTY=/nonexistent pg "${_d}" write /tmp/x >/dev/null; _rc=$?
  assert_eq 2 "${_rc}" 'mode=deny denies an unmatched tool'
  HARSH_PERMISSIONS_MODE=allow pg "${_d}" write /tmp/x >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'mode=allow allows an unmatched tool'
  rm -rf "${_d}"
}

test_audit_log_records_provenance() {
  _d=$(mktemp -d)
  HARSH_PERMISSIONS_MODE=ask pg "${_d}" read x >/dev/null
  HARSH_PERMISSIONS_MODE=ask pg "${_d}" bash 'rm -rf / x' >/dev/null
  _log=$(cat "${_d}/permissions.log")
  assert_contains "${_log}" 'read,x,allow'
  assert_contains "${_log}" ',deny,bash,policy'
  rm -rf "${_d}"
}

# --- end-to-end through the engine ------------------------------------------

test_engine_blocks_denied_tool_and_model_sees_reason() {
  install_real_gate
  _s=$(hnew permeng)
  # mode=ask + no terminal => bash (unmatched, "ask") fails closed; the refusal
  # becomes the tool_result the model reads.
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY=/nonexistent \
    hsh -q ask "${_s}" 'go [[tool:bash:whoami]]' >/dev/null 2>&1
  _res=$(hsh assemble "${_s}" | jq -r '.[].content[] | select(.type=="tool_result") | .content')
  assert_contains "${_res}" 'blocked by hook'
  assert_contains "${_res}" 'no terminal'
}

test_engine_allows_readonly_tool_under_gate() {
  install_real_gate
  _s=$(hnew permread)
  _out=$(HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY=/nonexistent \
    hsh ask "${_s}" 'go [[tool:ls:.]]' 2>&1)
  _res=$(hsh assemble "${_s}" | jq -r '.[].content[] | select(.type=="tool_result") | .content')
  assert_not_contains "${_res}" 'blocked by hook'
}

test_grants_are_per_session() {
  # A grant in one session's dir must not authorize another session.
  _a=$(mktemp -d); _b=$(mktemp -d)
  printf 'a\n' > "${_a}/ans"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_a}/ans" pg "${_a}" bash 'x' >/dev/null
  # Session B has no grant -> still fails closed.
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY=/nonexistent pg "${_b}" bash 'x' >/dev/null; _rc=$?
  assert_eq 2 "${_rc}" 'a grant does not leak across sessions'
  rm -rf "${_a}" "${_b}"
}
