#!/usr/bin/env sh
# Context compaction: the drop-in `compact` command summarizes + archives and
# restarts the session (composing the engine's `archive` and `send -m`
# primitives); the auto-trigger in cmd_run fires on the previous turn's usage
# and resolves the command like any other; a pending (unanswered) prompt
# survives; PreCompact hooks can block.

test_compact_archives_and_restarts_from_summary() {
  _s=$(hnew cmp)
  hsh -q ask "${_s}" 'first topic' >/dev/null
  hsh -q ask "${_s}" 'second topic' >/dev/null
  hsh -q compact "${_s}" || fail "compact failed"
  _dir=$(hsh path "${_s}")
  # The full history moved into archive/<ts>/ (4 entries + manifest copy)…
  set -- "${_dir}"/archive/*/[0-9]*.json
  [ -e "$1" ] || fail "no archived entries"
  assert_eq 4 "$#" 'all entries archived'
  set -- "${_dir}"/archive/*/manifest.csv
  [ -e "$1" ] || fail "manifest not archived"
  # …and the live session restarts as exactly one summary entry.
  _msgs=$(hsh assemble "${_s}")
  assert_eq 1 "$(printf '%s' "${_msgs}" | jq 'length')" 'one message after compaction'
  assert_contains "$(printf '%s' "${_msgs}" | jq -r '.[0].content[0].text')" 'compacted away'
}

test_compact_is_noop_on_fresh_session() {
  _s=$(hnew cmpempty)
  hsh compact "${_s}" >/dev/null 2>&1 || fail "compact on empty session should succeed"
  set -- "$(hsh path "${_s}")"/[0-9]*.json
  [ -e "$1" ] && fail "no entries should be created"
  return 0
}

test_autocompact_triggers_and_keeps_pending_prompt() {
  _s=$(hnew cmpauto)
  hsh -q ask "${_s}" 'seed turn' >/dev/null
  # Mock usage totals 15 tokens; a threshold of 5 forces compaction on the next
  # run, after the new prompt is already recorded — that prompt must survive.
  _out=$(HARSH_COMPACT_AT=5 hsh ask "${_s}" 'pending prompt survives' 2>&1) || fail "run failed: ${_out}"
  assert_contains "${_out}" 'compacting context'
  _dir=$(hsh path "${_s}")
  [ -d "${_dir}/archive" ] || fail "no archive created"
  _msgs=$(hsh assemble "${_s}")
  assert_contains "$(printf '%s' "${_msgs}" | jq -r '.[0].content | map(.text) | join(" ")')" \
    'pending prompt survives'
}

test_autocompact_disabled_with_zero() {
  _s=$(hnew cmpoff)
  hsh -q ask "${_s}" 'seed' >/dev/null
  _out=$(HARSH_COMPACT_AT=0 hsh ask "${_s}" 'again' 2>&1) || fail "run failed"
  assert_not_contains "${_out}" 'compacting context'
  [ -d "$(hsh path "${_s}")/archive" ] && fail "archive should not exist"
  return 0
}

test_precompact_hook_blocks_compaction() {
  install_hook PreCompact/10.sh <<'EOF'
echo "not now"; exit 2
EOF
  _s=$(hnew cmphook)
  hsh -q ask "${_s}" 'a turn' >/dev/null
  set -- "$(hsh path "${_s}")"/[0-9]*.json; _before=$#
  _out=$(hsh compact "${_s}" 2>&1); _rc=$?
  assert_ne "${_rc}" 0 'blocked compaction must fail'
  assert_contains "${_out}" 'blocked'
  set -- "$(hsh path "${_s}")"/[0-9]*.json; _after=$#
  assert_eq "${_before}" "${_after}" 'entries untouched when blocked'
}

test_precompact_hook_context_reaches_summarizer() {
  install_hook PreCompact/10.sh <<'EOF'
echo "FOCUS-ON-THE-BUILD"
EOF
  _s=$(hnew cmphint)
  hsh -q ask "${_s}" 'a turn' >/dev/null
  hsh -q compact "${_s}" || fail "compact failed"
  # The mock echoes the summarizer request back, so the hook's guidance is
  # visible in the stored summary.
  assert_contains "$(hsh assemble "${_s}" | jq -r '.[0].content[0].text')" 'FOCUS-ON-THE-BUILD'
}

test_compact_is_a_drop_in_command_not_a_primitive() {
  # compact resolves through the command dispatcher (and so appears on both
  # surfaces, including /compact in the REPL) instead of being reserved.
  assert_contains "$(hsh commands)" 'compact SESSION'
  assert_contains "$(hsh commands repl)" 'compact SESSION'
}

test_missing_compact_command_degrades_gracefully() {
  # Point the commands dir somewhere empty: the auto-trigger must warn and
  # keep running with the full context, not die.
  _d=$(mktemp -d); mkdir -p "${_d}/cmds" "${_d}/s"
  printf '. %s/harsh.conf\nHARSH_COMMANDS_DIR=%s/cmds\nHARSH_SESSIONS_DIR=%s/s\nHARSH_LOG_DIR=%s/l\n' \
    "${ROOT}" "${_d}" "${_d}" "${_d}" > "${_d}/conf"
  _s=$(HARSH_CONFIG="${_d}/conf" sh "${ROOT}/harsh.sh" new nocompact)
  HARSH_CONFIG="${_d}/conf" sh "${ROOT}/harsh.sh" -q ask "${_s}" 'seed' >/dev/null
  _out=$(HARSH_CONFIG="${_d}/conf" HARSH_COMPACT_AT=5 sh "${ROOT}/harsh.sh" ask "${_s}" 'again' 2>&1); _rc=$?
  assert_eq 0 "${_rc}" 'run must succeed without a compact command'
  assert_contains "${_out}" 'no compact command'
  rm -rf "${_d}"
}

test_summarizer_scratch_session_is_inspectable() {
  _s=$(hnew cmpscratch)
  hsh -q ask "${_s}" 'a turn' >/dev/null
  hsh -q compact "${_s}" || fail "compact failed"
  # The summarizer ran as a normal harsh session, prefixed compact-, so the
  # whole compaction is auditable with the usual tools.
  _sdir=$(dirname "$(hsh path cmpscratch)")
  set -- "${_sdir}"/compact-cmpscratch-*
  [ -d "$1" ] || fail "no compact- scratch session found"
}
