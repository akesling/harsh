#!/usr/bin/env sh
# tests/lib.sh — assertions and helpers, sourced into each isolated test shell.
#
# The runner (tests/run.sh) gives every test its own tempdir and exports a
# sandbox config via HARSH_CONFIG (sessions/logs/hooks all redirected into the
# tempdir) plus HARSH_MOCK=1 and HARSH_HOOKS_DIR. ROOT is the project root,
# published by the runner. Nothing here touches the real sessions/ or logs/.

# Which shell runs the harness-under-test. CI sets this to dash/bash/zsh/
# "busybox sh" so the portability claim is tested, not just parsed. Left
# unquoted on purpose so a two-word value ("busybox sh") splits.
: "${HARSH_TEST_SH:=sh}"

# Run the harness with the sandbox config (taken from HARSH_CONFIG in the env).
# shellcheck disable=SC2086
hsh() { ${HARSH_TEST_SH} "${ROOT}/harsh.sh" "$@"; }

# Run a tool by name with a JSON argument:  tool NAME '{"...":...}'
# shellcheck disable=SC2086
tool() { printf '%s' "$2" | ${HARSH_TEST_SH} "${ROOT}/tools/tool.sh" call "$1"; }

# Create a fresh session and print its directory.
hnew() { hsh new "${1:-tc}"; }

# Install a hook. Path is relative to the sandbox hooks dir; body on stdin:
#   install_hook PreToolUse/bash/10.sh <<'EOF'
#   echo deny; exit 2
#   EOF
install_hook() {
  _p="${HARSH_HOOKS_DIR}/$1"
  mkdir -p "$(dirname "${_p}")"
  cat > "${_p}"
}

# --- assertions: each prints and exits non-zero on failure -------------------
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

assert_eq() { [ "$1" = "$2" ] || fail "${3:-eq}: expected [$1], got [$2]"; }
assert_ne() { [ "$1" != "$2" ] || fail "${3:-ne}: both are [$1]"; }
assert_contains() {
  case "$1" in *"$2"*) : ;; *) fail "${3:-contains}: [$2] not found in [$1]" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "${3:-not_contains}: [$2] unexpectedly found in [$1]" ;; *) : ;; esac
}
# assert a command succeeds / fails
assert_ok()   { "$@" >/dev/null 2>&1 || fail "expected success: $*"; }
assert_fails() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }
