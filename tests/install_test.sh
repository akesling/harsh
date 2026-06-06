#!/usr/bin/env sh
# Install path: harsh finds its directories purely from the config, regardless
# of cwd or launcher, and install.sh produces a working `ha`.

test_dirs_resolved_from_config_anywhere() {
  d=$(mktemp -d)
  cat > "$d/conf" <<EOF
HARSH_TOOLS_DIR=$ROOT/tools
HARSH_SKILLS_DIR=$ROOT/skills
HARSH_HOOKS_DIR=$ROOT/hooks
HARSH_SESSIONS_DIR=$d/sessions
HARSH_LOG_DIR=$d/logs
EOF
  # Invoked from an unrelated cwd, with only the config to go on, harsh must
  # still locate its tools.
  out=$(cd / && HARSH_CONFIG="$d/conf" sh "$ROOT/harsh.sh" tools)
  assert_contains "$out" 'bash'
  assert_contains "$out" 'edit'
  rm -rf "$d"
}

test_installer_copies_runtime_and_runs() {
  d=$(mktemp -d)
  sh "$ROOT/install.sh" --prefix "$d/bin" --share "$d/share" \
     --config "$d/cfg/harsh.conf" --data "$d/data" >/dev/null 2>&1 \
     || fail "installer exited non-zero"
  # the runtime was copied into the install root
  [ -f "$d/share/harsh.sh" ]         || fail "harsh.sh not copied"
  [ -f "$d/share/tools/bash.sh" ]    || fail "tools not copied"
  [ -f "$d/share/hooks/README.md" ]  || fail "hooks not copied"
  [ -f "$d/share/lib/render.sh" ]    || fail "lib not copied"
  # the launcher execs the COPY, not the checkout
  assert_contains "$(cat "$d/bin/ha")" "$d/share/harsh.sh"
  # and it runs
  assert_contains "$(HARSH_MOCK=1 sh "$d/bin/ha" tools)" 'bash'
  rm -rf "$d"
}

test_installer_preserves_existing_sessions() {
  d=$(mktemp -d)
  mkdir -p "$d/share/sessions/keepme"
  : > "$d/share/sessions/keepme/manifest.csv"
  sh "$ROOT/install.sh" --prefix "$d/bin" --share "$d/share" \
     --config "$d/cfg/harsh.conf" >/dev/null 2>&1
  [ -f "$d/share/sessions/keepme/manifest.csv" ] || fail "reinstall clobbered a session"
  rm -rf "$d"
}

test_installer_link_mode_uses_checkout() {
  d=$(mktemp -d)
  sh "$ROOT/install.sh" --link --prefix "$d/bin" \
     --config "$d/cfg/harsh.conf" --data "$d/data" >/dev/null 2>&1
  [ -f "$d/share/harsh.sh" ] && fail "--link should not copy"
  assert_contains "$(cat "$d/bin/ha")" "$ROOT/harsh.sh"
  rm -rf "$d"
}

test_installer_uninstall_removes_launcher() {
  d=$(mktemp -d)
  sh "$ROOT/install.sh" --prefix "$d/bin" --share "$d/share" \
     --config "$d/cfg/harsh.conf" --data "$d/data" >/dev/null 2>&1
  sh "$ROOT/install.sh" --prefix "$d/bin" --share "$d/share" \
     --config "$d/cfg/harsh.conf" --uninstall >/dev/null 2>&1
  [ -e "$d/bin/ha" ] && fail "launcher not removed"
  # config + data are intentionally preserved
  [ -f "$d/cfg/harsh.conf" ] || fail "uninstall should keep config"
  rm -rf "$d"
}

test_tui_subcommand_dispatches() {
  printf '/quit\n' | hsh tui ttest >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 0 'ha tui … exits cleanly'
}
