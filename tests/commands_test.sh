#!/usr/bin/env sh
# Extensible commands: shipped derived commands live in $HARSH_COMMANDS_DIR and
# resolve through the dispatcher; custom ones drop in; engine primitives can't
# be shadowed. (The moved commands — show/final/outline/etc. — are also covered
# by loop_test/agent_test, which exercise them via the resolver.)

# A sandbox config that points the commands dir at $1 (and inherits the rest).
mkconf() {
  printf '. %s/harsh.conf\nHARSH_COMMANDS_DIR=%s\nHARSH_SESSIONS_DIR=%s/s\nHARSH_LOG_DIR=%s/l\n' \
    "${ROOT}" "$1" "$2" "$2"
}

test_commands_listing_includes_shipped() {
  _out=$(hsh commands)
  assert_contains "${_out}" 'show'
  assert_contains "${_out}" 'final'
  assert_contains "${_out}" 'sessions'
}

test_sessions_topic_skips_injected_context() {
  # A SessionStart hook injects opening context; the sessions listing must show
  # the first *typed* prompt as the topic, not the injected boilerplate.
  install_hook SessionStart/10.sh <<'EOF'
echo "INJECTED-CONTEXT-BOILERPLATE"
EOF
  _s=$(hnew sesstopic)
  hsh -q send "${_s}" 'my real first prompt' >/dev/null
  _line=$(hsh sessions | grep "$(basename "${_s}")")
  assert_contains "${_line}" 'my real first prompt'
  assert_not_contains "${_line}" 'INJECTED-CONTEXT-BOILERPLATE'
}

test_help_lists_commands_section() {
  _out=$(hsh help)
  assert_contains "${_out}" 'Commands (extensible'
  assert_contains "${_out}" 'outline'
}

test_shipped_command_resolves_through_dispatcher() {
  _s=$(hnew cmdres)
  hsh -q ask "${_s}" 'hello commands' >/dev/null
  # `final` now lives in commands/ but is reached as a normal subcommand.
  assert_contains "$(hsh final "${_s}")" '[mock] You said: hello commands'
}

test_custom_command_resolves() {
  _d=$(mktemp -d); mkdir -p "${_d}/cmds"
  cat > "${_d}/cmds/greet.sh" <<'EOF'
#!/usr/bin/env sh
[ "$1" = --describe ] && { printf 'greet\tsay hi\n'; exit 0; }
echo "hello from custom command"
EOF
  _conf="${_d}/conf"; mkconf "${_d}/cmds" "${_d}" > "${_conf}"
  _out=$(HARSH_CONFIG="${_conf}" sh "${ROOT}/harsh.sh" greet)
  assert_contains "${_out}" 'hello from custom command'
  # and it shows up in the listing
  assert_contains "$(HARSH_CONFIG="${_conf}" sh "${ROOT}/harsh.sh" commands)" 'greet'
  rm -rf "${_d}"
}

test_primitive_cannot_be_shadowed() {
  _d=$(mktemp -d); mkdir -p "${_d}/cmds"
  # Drop a 'path.sh' that would print SHADOW if it ran; the built-in must win.
  printf '#!/usr/bin/env sh\necho SHADOW\n' > "${_d}/cmds/path.sh"
  _conf="${_d}/conf"; mkconf "${_d}/cmds" "${_d}" > "${_conf}"
  _s=$(HARSH_CONFIG="${_conf}" sh "${ROOT}/harsh.sh" new shadowtest)
  _out=$(HARSH_CONFIG="${_conf}" sh "${ROOT}/harsh.sh" path shadowtest)
  assert_not_contains "${_out}" 'SHADOW'
  assert_contains "${_out}" 'shadowtest'
  rm -rf "${_d}"
}

test_repl_exposes_command_with_session_filled_in() {
  _s=$(hnew replcmd)
  hsh -q ask "${_s}" 'distinctive marker' >/dev/null
  # /final is a commands/ verb the REPL did not hardcode; it should resolve and
  # have the current session filled in automatically.
  _out=$(printf '%s\n' '/final' '/quit' | hsh repl replcmd 2>&1)
  assert_contains "${_out}" 'distinctive marker'
}

test_repl_exposes_sessionless_command() {
  # /version takes no SESSION; it should run without one being injected.
  _out=$(printf '%s\n' '/version' '/quit' | hsh repl rv 2>&1)
  assert_contains "${_out}" 'harsh '
}

test_repl_help_lists_all_commands() {
  _out=$(printf '%s\n' '/help' '/quit' | hsh repl rh 2>&1)
  assert_contains "${_out}" '/final'
  assert_contains "${_out}" '/schemas'
}

test_tool_is_cli_only_not_a_slash() {
  _s=$(hnew toolslash)
  # /tool must NOT run (it reads stdin); the following line must survive as a
  # normal message rather than being eaten by the tool's `cat`.
  _out=$(printf '%s\n' '/tool bash' 'SURVIVES-as-message' '/quit' | hsh repl toolslash 2>&1)
  assert_contains "${_out}" 'CLI-only'
  assert_contains "$(hsh show toolslash)" 'SURVIVES-as-message'
}

test_cli_only_command_hidden_from_repl_help() {
  _out=$(printf '%s\n' '/help' '/quit' | hsh repl rh2 2>&1)
  assert_not_contains "${_out}" '/tool '
  assert_contains "${_out}" '/show'
}

test_commands_repl_filters_cli_only() {
  # "tool NAME" is unique to the cli-only `tool` command (vs. plural "tools").
  assert_not_contains "$(hsh commands repl)" 'tool NAME'
  # but plain `commands` (CLI) still lists it, and the CLI can run it
  assert_contains "$(hsh commands)" 'tool NAME'
}

test_tool_still_works_on_cli() {
  _out=$(printf '{"command":"echo cli-tool-ok"}' | hsh tool bash)
  assert_contains "${_out}" 'cli-tool-ok'
}

# --- surfaces are directories ----------------------------------------------

test_cli_subdir_command_is_cli_only() {
  _d=$(mktemp -d); mkdir -p "${_d}/cmds/cli"
  cat > "${_d}/cmds/cli/dbg.sh" <<'EOF'
#!/usr/bin/env sh
[ "$1" = --describe ] && { printf 'dbg\tdebug thing\n'; exit 0; }
echo "dbg ran"
EOF
  _conf="${_d}/conf"; mkconf "${_d}/cmds" "${_d}" > "${_conf}"
  assert_contains "$(HARSH_CONFIG="${_conf}" sh "${ROOT}/harsh.sh" dbg)" 'dbg ran'
  assert_contains "$(HARSH_CONFIG="${_conf}" sh "${ROOT}/harsh.sh" commands)" 'dbg'
  assert_not_contains "$(HARSH_CONFIG="${_conf}" sh "${ROOT}/harsh.sh" commands repl)" 'dbg'
  rm -rf "${_d}"
}

test_repl_subdir_command_not_runnable_on_cli() {
  _d=$(mktemp -d); mkdir -p "${_d}/cmds/repl"
  cat > "${_d}/cmds/repl/banner.sh" <<'EOF'
#!/usr/bin/env sh
[ "$1" = --describe ] && { printf 'banner\tshow a banner\n'; exit 0; }
echo "banner ran"
EOF
  _conf="${_d}/conf"; mkconf "${_d}/cmds" "${_d}" > "${_conf}"
  HARSH_CONFIG="${_conf}" sh "${ROOT}/harsh.sh" banner >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'repl-only command should not run as a CLI verb'
  assert_not_contains "$(HARSH_CONFIG="${_conf}" sh "${ROOT}/harsh.sh" commands)" 'banner'
  rm -rf "${_d}"
}

test_unknown_command_errors() {
  hsh frobnicate-nope >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'unknown command should fail'
}

test_command_name_traversal_is_rejected() {
  hsh '../tool' >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'path-traversal command name should fail'
}