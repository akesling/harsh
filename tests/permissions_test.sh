#!/usr/bin/env sh
# The permission gate (hooks/PreToolUse/10-permissions.sh): declarative layered
# policy, allow/ask/deny, interactive "ask" via the TTY seam with session-grant
# persistence, fail-closed when non-interactive, audit trail, and end-to-end
# enforcement through the engine.

GATE="${ROOT}/hooks/PreToolUse/10-permissions.sh"

# Keep the project/user policy scopes inside the test tempdir so tests never
# touch the real ~/.config/harsh or the repo's cwd .harsh/.
_perm_isolate=$(mktemp -d)
export HARSH_PERMISSIONS_USER="${_perm_isolate}/user.json"
export HARSH_PERMISSIONS_PROJECT="${_perm_isolate}/project/.harsh.json"

# pg DIR TOOL ARG  — invoke the gate directly with a payload; env (mode, TTY
# seam) is set by the caller. Captures stdout; returns the gate's exit code.
pg() {
  _pgdir=$1; _pgtool=$2; _pgarg=${3:-}
  jq -nc --arg s "${_pgdir}" --arg t "${_pgtool}" --arg a "${_pgarg}" \
    '{session_dir:$s, tool_name:$t,
      tool_input: (if $a=="" then {} else {command:$a,path:$a,pattern:$a,name:$a} end)}' \
  | sh "${GATE}"
}

# pgrw DIR TOOL ARG OUTFILE — like pg but captures the rewrite-channel output.
pgrw() {
  _pgdir=$1; _pgtool=$2; _pgarg=$3; _pgout=$4
  jq -nc --arg s "${_pgdir}" --arg t "${_pgtool}" --arg a "${_pgarg}" \
    '{session_dir:$s, tool_name:$t, tool_input:{command:$a}}' \
  | HARSH_HOOK_REWRITE_OUT="${_pgout}" sh "${GATE}"
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

test_ask_session_persists_grant() {
  _d=$(mktemp -d); printf 's\n' > "${_d}/ans"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_d}/ans" pg "${_d}" bash 'make' >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'session grant allows'
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

test_session_grant_via_prompt() {
  _d=$(mktemp -d); printf 's\n' > "${_d}/ans"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_d}/ans" pg "${_d}" bash 'x' >/dev/null
  assert_contains "$(cat "${_d}/permissions.json")" '"tool":"bash"'
  rm -rf "${_d}"
}

test_grants_are_per_session() {
  # A session grant in one session's dir must not authorize another session.
  _a=$(mktemp -d); _b=$(mktemp -d)
  printf 's\n' > "${_a}/ans"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_a}/ans" pg "${_a}" bash 'x' >/dev/null
  # Session B has no grant -> still fails closed. (Project/user scopes are
  # isolated to the test tempdir and empty here.)
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY=/nonexistent pg "${_b}" bash 'x' >/dev/null; _rc=$?
  assert_eq 2 "${_rc}" 'a session grant does not leak across sessions'
  rm -rf "${_a}" "${_b}"
}

# --- new: persistence scopes, manual edit, glob-capture rewrite -------------

test_project_scope_persists_and_shares() {
  # "project" grant lands in the project file and authorizes a *different*
  # session (project policy is not per-session).
  _a=$(mktemp -d); _b=$(mktemp -d); printf 'p\n' > "${_a}/ans"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_a}/ans" pg "${_a}" bash 'x' >/dev/null
  assert_contains "$(cat "${HARSH_PERMISSIONS_PROJECT}")" '"tool":"bash"'
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY=/nonexistent pg "${_b}" bash 'y' >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'project grant authorizes another session'
  rm -f "${HARSH_PERMISSIONS_PROJECT}"; rm -rf "${_a}" "${_b}"
}

test_forever_scope_persists_to_user() {
  _d=$(mktemp -d); printf 'f\n' > "${_d}/ans"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_d}/ans" pg "${_d}" bash 'x' >/dev/null
  assert_contains "$(cat "${HARSH_PERMISSIONS_USER}")" '"tool":"bash"'
  rm -f "${HARSH_PERMISSIONS_USER}"; rm -rf "${_d}"
}

test_manual_edit_rewrites_this_call() {
  _d=$(mktemp -d); _rw=$(mktemp)
  printf 'e\necho EDITED\n' > "${_d}/ans"
  HARSH_PERMISSIONS_MODE=ask HARSH_PERMISSIONS_TTY="${_d}/ans" \
    pgrw "${_d}" bash 'original-cmd' "${_rw}" >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'edit allows the call'
  assert_eq 'echo EDITED' "$(jq -r '.tool_input.command' "${_rw}")" 'manual edit replaced the command'
  rm -f "${_rw}"; rm -rf "${_d}"
}

test_rule_rewrite_applies_glob_captures() {
  _d=$(mktemp -d); _rw=$(mktemp)
  # shellcheck disable=SC2016  # $1 is a rewrite-template ref, not a shell var
  printf '%s' '{"rules":[{"tool":"bash","match":{"command":"git push *"},"decision":"allow","rewrite":{"command":"git push --dry-run $1"}}]}' \
    > "${_d}/permissions.json"
  pgrw "${_d}" bash 'git push origin main' "${_rw}" >/dev/null; _rc=$?
  assert_eq 0 "${_rc}" 'rewrite rule allows'
  assert_eq 'git push --dry-run origin main' "$(jq -r '.tool_input.command' "${_rw}")" \
    'glob captures substitute into the rewrite'
  rm -f "${_rw}"; rm -rf "${_d}"
}

test_rule_rewrite_runs_through_the_engine() {
  install_real_gate
  _s=$(hnew permrw)
  _dir=$(hsh path "${_s}")
  printf '%s' '{"rules":[{"tool":"bash","match":{"command":"*"},"decision":"allow","rewrite":{"command":"echo REWRITTEN-BY-POLICY"}}]}' \
    > "${_dir}/permissions.json"
  HARSH_PERMISSIONS_MODE=ask hsh -q ask "${_s}" 'go [[tool:bash:whatever]]' >/dev/null 2>&1
  _res=$(hsh assemble "${_s}" | jq -r '.[].content[] | select(.type=="tool_result") | .content')
  assert_contains "${_res}" 'REWRITTEN-BY-POLICY'
}

test_command_rewrite_subcommand_authors_a_rule() {
  _s=$(hnew permcmd)
  # shellcheck disable=SC2016  # $1 is a rewrite-template ref, not a shell var
  hsh permissions "${_s}" rewrite bash 'npm *' 'npm $1 --offline' --scope session >/dev/null
  _v=$(hsh permissions "${_s}" test bash 'npm install foo' | jq -c '{decision, cmd: .rewrite.command, caps}')
  assert_contains "${_v}" '"decision":"allow"'
  # shellcheck disable=SC2016  # asserting the literal template text
  assert_contains "${_v}" 'npm $1 --offline'
  assert_contains "${_v}" '["install foo"]'
}

test_command_scope_flag_targets_the_right_file() {
  _s=$(hnew permscope)
  hsh permissions "${_s}" allow write --scope project >/dev/null
  assert_contains "$(cat "${HARSH_PERMISSIONS_PROJECT}")" '"tool":"write"'
  [ -f "$(hsh path "${_s}")/permissions.json" ] && fail 'project grant must not write the session file'
  rm -f "${HARSH_PERMISSIONS_PROJECT}"
}
