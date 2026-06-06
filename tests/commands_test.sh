#!/usr/bin/env sh
# Extensible commands: shipped derived commands live in $HARSH_COMMANDS_DIR and
# resolve through the dispatcher; custom ones drop in; engine primitives can't
# be shadowed. (The moved commands — show/final/outline/etc. — are also covered
# by loop_test/agent_test, which exercise them via the resolver.)

# A sandbox config that points the commands dir at $1 (and inherits the rest).
mkconf() {
  printf '. %s/harsh.conf\nHARSH_COMMANDS_DIR=%s\nHARSH_SESSIONS_DIR=%s/s\nHARSH_LOG_DIR=%s/l\n' \
    "$ROOT" "$1" "$2" "$2"
}

test_commands_listing_includes_shipped() {
  out=$(hsh commands)
  assert_contains "$out" 'show'
  assert_contains "$out" 'final'
  assert_contains "$out" 'sessions'
}

test_help_lists_commands_section() {
  out=$(hsh help)
  assert_contains "$out" 'Commands (extensible'
  assert_contains "$out" 'outline'
}

test_shipped_command_resolves_through_dispatcher() {
  s=$(hnew cmdres)
  hsh -q ask "$s" 'hello commands' >/dev/null
  # `final` now lives in commands/ but is reached as a normal subcommand.
  assert_contains "$(hsh final "$s")" '[mock] You said: hello commands'
}

test_custom_command_resolves() {
  d=$(mktemp -d); mkdir -p "$d/cmds"
  cat > "$d/cmds/greet.sh" <<'EOF'
#!/usr/bin/env sh
[ "$1" = --describe ] && { printf 'greet\tsay hi\n'; exit 0; }
echo "hello from custom command"
EOF
  conf="$d/conf"; mkconf "$d/cmds" "$d" > "$conf"
  out=$(HARSH_CONFIG="$conf" sh "$ROOT/harsh.sh" greet)
  assert_contains "$out" 'hello from custom command'
  # and it shows up in the listing
  assert_contains "$(HARSH_CONFIG="$conf" sh "$ROOT/harsh.sh" commands)" 'greet'
  rm -rf "$d"
}

test_primitive_cannot_be_shadowed() {
  d=$(mktemp -d); mkdir -p "$d/cmds"
  # Drop a 'path.sh' that would print SHADOW if it ran; the built-in must win.
  printf '#!/usr/bin/env sh\necho SHADOW\n' > "$d/cmds/path.sh"
  conf="$d/conf"; mkconf "$d/cmds" "$d" > "$conf"
  s=$(HARSH_CONFIG="$conf" sh "$ROOT/harsh.sh" new shadowtest)
  out=$(HARSH_CONFIG="$conf" sh "$ROOT/harsh.sh" path shadowtest)
  assert_not_contains "$out" 'SHADOW'
  assert_contains "$out" 'shadowtest'
  rm -rf "$d"
}

test_repl_exposes_command_with_session_filled_in() {
  s=$(hnew replcmd)
  hsh -q ask "$s" 'distinctive marker' >/dev/null
  # /final is a commands/ verb the REPL did not hardcode; it should resolve and
  # have the current session filled in automatically.
  out=$(printf '%s\n' '/final' '/quit' | hsh repl replcmd 2>&1)
  assert_contains "$out" 'distinctive marker'
}

test_repl_exposes_sessionless_command() {
  # /version takes no SESSION; it should run without one being injected.
  out=$(printf '%s\n' '/version' '/quit' | hsh repl rv 2>&1)
  assert_contains "$out" 'harsh '
}

test_repl_help_lists_all_commands() {
  out=$(printf '%s\n' '/help' '/quit' | hsh repl rh 2>&1)
  assert_contains "$out" '/final'
  assert_contains "$out" '/schemas'
}

test_tool_is_cli_only_not_a_slash() {
  s=$(hnew toolslash)
  # /tool must NOT run (it reads stdin); the following line must survive as a
  # normal message rather than being eaten by the tool's `cat`.
  out=$(printf '%s\n' '/tool bash' 'SURVIVES-as-message' '/quit' | hsh repl toolslash 2>&1)
  assert_contains "$out" 'CLI-only'
  assert_contains "$(hsh show toolslash)" 'SURVIVES-as-message'
}

test_cli_only_command_hidden_from_repl_help() {
  out=$(printf '%s\n' '/help' '/quit' | hsh repl rh2 2>&1)
  assert_not_contains "$out" '/tool '
  assert_contains "$out" '/show'
}

test_commands_repl_filters_cli_only() {
  # "tool NAME" is unique to the cli-only `tool` command (vs. plural "tools").
  assert_not_contains "$(hsh commands repl)" 'tool NAME'
  # but plain `commands` (CLI) still lists it, and the CLI can run it
  assert_contains "$(hsh commands)" 'tool NAME'
}

test_tool_still_works_on_cli() {
  out=$(printf '{"command":"echo cli-tool-ok"}' | hsh tool bash)
  assert_contains "$out" 'cli-tool-ok'
}

# --- surfaces are directories ----------------------------------------------

test_cli_subdir_command_is_cli_only() {
  d=$(mktemp -d); mkdir -p "$d/cmds/cli"
  cat > "$d/cmds/cli/dbg.sh" <<'EOF'
#!/usr/bin/env sh
[ "$1" = --describe ] && { printf 'dbg\tdebug thing\n'; exit 0; }
echo "dbg ran"
EOF
  conf="$d/conf"; mkconf "$d/cmds" "$d" > "$conf"
  assert_contains "$(HARSH_CONFIG="$conf" sh "$ROOT/harsh.sh" dbg)" 'dbg ran'
  assert_contains "$(HARSH_CONFIG="$conf" sh "$ROOT/harsh.sh" commands)" 'dbg'
  assert_not_contains "$(HARSH_CONFIG="$conf" sh "$ROOT/harsh.sh" commands repl)" 'dbg'
  rm -rf "$d"
}

test_repl_subdir_command_not_runnable_on_cli() {
  d=$(mktemp -d); mkdir -p "$d/cmds/repl"
  cat > "$d/cmds/repl/banner.sh" <<'EOF'
#!/usr/bin/env sh
[ "$1" = --describe ] && { printf 'banner\tshow a banner\n'; exit 0; }
echo "banner ran"
EOF
  conf="$d/conf"; mkconf "$d/cmds" "$d" > "$conf"
  HARSH_CONFIG="$conf" sh "$ROOT/harsh.sh" banner >/dev/null 2>&1; rc=$?
  assert_ne "$rc" 0 'repl-only command should not run as a CLI verb'
  assert_not_contains "$(HARSH_CONFIG="$conf" sh "$ROOT/harsh.sh" commands)" 'banner'
  rm -rf "$d"
}

test_unknown_command_errors() {
  hsh frobnicate-nope >/dev/null 2>&1; rc=$?
  assert_ne "$rc" 0 'unknown command should fail'
}

test_command_name_traversal_is_rejected() {
  hsh '../tool' >/dev/null 2>&1; rc=$?
  assert_ne "$rc" 0 'path-traversal command name should fail'
}
