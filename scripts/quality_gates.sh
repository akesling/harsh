#!/usr/bin/env sh
# scripts/quality_gates.sh — run every harsh quality check. Exits non-zero if
# any gate fails, so it works as a pre-commit / CI gate. Pure POSIX sh.
#
#   scripts/quality_gates.sh           run all gates
#
# Gates: shellcheck (POSIX sh) · syntax parse across installed shells ·
#        tool schema validity · a hermetic end-to-end mock loop.
set -u
if [ -n "${ZSH_VERSION:-}" ]; then
  emulate sh 2>/dev/null || setopt sh_word_split 2>/dev/null || true
fi
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT" || { echo "cannot cd to project root"; exit 1; }

fail=0
pass()    { printf '  ok    %s\n' "$1"; }
bad()     { printf '  FAIL  %s\n' "$1"; fail=1; }
skip()    { printf '  skip  %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# Collect every shell script we ship into the positional params ($@), so later
# loops can use "$@" without word-splitting pitfalls (no arrays in POSIX sh).
set -- harsh.sh harsh_tui.sh install.sh
for f in tools/*.sh scripts/*.sh tests/*.sh hooks/*/*.sh hooks/*/*/*.sh; do
  [ -f "$f" ] && set -- "$@" "$f"
done

# ---------------------------------------------------------------------------
section "shellcheck (POSIX sh)"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --shell=sh "$@"; then pass "no findings"; else bad "shellcheck findings above"; fi
else
  skip "shellcheck not installed"
fi

# ---------------------------------------------------------------------------
section "syntax parse across shells"
any_shell=0
for shb in sh bash zsh dash ash busybox; do
  command -v "$shb" >/dev/null 2>&1 || continue
  any_shell=1
  ok=1
  for f in "$@"; do
    "$shb" -n "$f" 2>/dev/null || { ok=0; break; }
  done
  if [ "$ok" = 1 ]; then pass "$shb"; else bad "$shb: $f failed to parse"; fi
done
[ "$any_shell" = 1 ] || bad "no POSIX shell found to parse with"

# ---------------------------------------------------------------------------
section "tool schemas"
sok=1
for t in tools/*.sh; do
  b=$(basename "$t" .sh)
  [ "$b" = tool ] && continue
  sh "$t" --schema 2>/dev/null | jq -e '.name and .input_schema' >/dev/null 2>&1 \
    || { bad "invalid schema: $b"; sok=0; }
done
sh tools/tool.sh schemas 2>/dev/null | jq -e 'type=="array" and length>0' >/dev/null 2>&1 \
  || { bad "aggregated schemas not a non-empty array"; sok=0; }
[ "$sok" = 1 ] && pass "all tool schemas valid"

# ---------------------------------------------------------------------------
section "test suite (tests/run.sh)"
# The harness is hermetic — every test runs in its own tempdir, so this never
# touches the real sessions/, logs/, or hooks/ directories.
out="$(sh tests/run.sh 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  pass "$(printf '%s\n' "$out" | tail -1)"
else
  bad "test failures:"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
section "result"
if [ "$fail" = 0 ]; then
  printf 'ALL GATES PASSED\n'; exit 0
else
  printf 'GATES FAILED\n'; exit 1
fi
