#!/usr/bin/env sh
# Install path: harsh finds its directories purely from the config, regardless
# of cwd or launcher, and install.sh produces a working `ha`.

test_dirs_resolved_from_config_anywhere() {
  _d=$(mktemp -d)
  cat > "${_d}/conf" <<EOF
HARSH_TOOLS_DIR=${ROOT}/tools
HARSH_SKILLS_DIR=${ROOT}/skills
HARSH_HOOKS_DIR=${ROOT}/hooks
HARSH_SESSIONS_DIR=${_d}/sessions
HARSH_LOG_DIR=${_d}/logs
EOF
  # Invoked from an unrelated cwd, with only the config to go on, harsh must
  # still locate its tools.
  _out=$(cd / && HARSH_CONFIG="${_d}/conf" sh "${ROOT}/harsh.sh" tools)
  assert_contains "${_out}" 'bash'
  assert_contains "${_out}" 'edit'
  rm -rf "${_d}"
}

test_installer_copies_runtime_and_runs() {
  _d=$(mktemp -d)
  sh "${ROOT}/install.sh" --prefix "${_d}/bin" --share "${_d}/share" \
     --config "${_d}/cfg/harsh.conf" --data "${_d}/data" >/dev/null 2>&1 \
     || fail "installer exited non-zero"
  # the runtime was copied into the install root
  [ -f "${_d}/share/harsh.sh" ]         || fail "harsh.sh not copied"
  [ -f "${_d}/share/tools/bash.sh" ]    || fail "tools not copied"
  [ -f "${_d}/share/hooks/README.md" ]  || fail "hooks not copied"
  [ -f "${_d}/share/lib/render.sh" ]    || fail "lib not copied"
  # the launcher execs the COPY, not the checkout
  assert_contains "$(cat "${_d}/bin/ha")" "${_d}/share/harsh.sh"
  # and it runs
  assert_contains "$(HARSH_MOCK=1 sh "${_d}/bin/ha" tools)" 'bash'
  rm -rf "${_d}"
}

test_installer_preserves_existing_sessions() {
  _d=$(mktemp -d)
  mkdir -p "${_d}/share/sessions/keepme"
  : > "${_d}/share/sessions/keepme/manifest.csv"
  sh "${ROOT}/install.sh" --prefix "${_d}/bin" --share "${_d}/share" \
     --config "${_d}/cfg/harsh.conf" >/dev/null 2>&1
  [ -f "${_d}/share/sessions/keepme/manifest.csv" ] || fail "reinstall clobbered a session"
  rm -rf "${_d}"
}

test_installer_link_mode_uses_checkout() {
  _d=$(mktemp -d)
  sh "${ROOT}/install.sh" --link --prefix "${_d}/bin" \
     --config "${_d}/cfg/harsh.conf" --data "${_d}/data" >/dev/null 2>&1
  [ -f "${_d}/share/harsh.sh" ] && fail "--link should not copy"
  assert_contains "$(cat "${_d}/bin/ha")" "${ROOT}/harsh.sh"
  rm -rf "${_d}"
}

test_installer_uninstall_removes_launcher() {
  _d=$(mktemp -d)
  sh "${ROOT}/install.sh" --prefix "${_d}/bin" --share "${_d}/share" \
     --config "${_d}/cfg/harsh.conf" --data "${_d}/data" >/dev/null 2>&1
  sh "${ROOT}/install.sh" --prefix "${_d}/bin" --share "${_d}/share" \
     --config "${_d}/cfg/harsh.conf" --uninstall >/dev/null 2>&1
  [ -e "${_d}/bin/ha" ] && fail "launcher not removed"
  # config + data are intentionally preserved
  [ -f "${_d}/cfg/harsh.conf" ] || fail "uninstall should keep config"
  rm -rf "${_d}"
}

test_tui_subcommand_dispatches() {
  printf '/quit\n' | hsh tui ttest >/dev/null 2>&1; _rc=$?
  assert_eq "${_rc}" 0 'ha tui … exits cleanly'
}
