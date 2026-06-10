#!/usr/bin/env sh
# scripts/quality_gates.sh — run every harsh quality check. Exits non-zero if
# any gate fails, so it works as a pre-commit / CI gate. Pure POSIX sh.
#
#   scripts/quality_gates.sh           run all gates
#
# Gates: shellcheck (POSIX sh) · syntax parse across installed shells ·
#        tool schema validity · a hermetic end-to-end mock loop · the site's
#        Bun unit tests (deps auto-installed; skipped when bun/site are absent).
set -u
if [ -n "${ZSH_VERSION:-}" ]; then
  emulate sh 2>/dev/null || setopt sh_word_split 2>/dev/null || true
fi
_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "${_root}" || { echo "cannot cd to project root"; exit 1; }

_fail=0
pass()    { printf '  ok    %s\n' "$1"; }
bad()     { printf '  FAIL  %s\n' "$1"; _fail=1; }
skip()    { printf '  skip  %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# Collect every shell script we ship into the positional params ($@), so later
# loops can use "$@" without word-splitting pitfalls (no arrays in POSIX sh).
set -- harsh.sh install.sh
for _f in tools/*.sh commands/*.sh commands/*/*.sh lib/*.sh scripts/*.sh tests/*.sh hooks/*/*.sh hooks/*/*/*.sh; do
  [ -f "${_f}" ] && set -- "$@" "${_f}"
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
_any_shell=0
for _shb in sh bash zsh dash ash busybox; do
  command -v "${_shb}" >/dev/null 2>&1 || continue
  _any_shell=1
  _ok=1; _perr=""
  for _f in "$@"; do
    # busybox is a multi-call binary: `busybox -n FILE` reads -n as an applet
    # name, not a flag — parse through its `sh` applet instead.
    if [ "${_shb}" = busybox ]; then
      _perr=$(busybox sh -n "${_f}" 2>&1) || { _ok=0; break; }
    else
      _perr=$("${_shb}" -n "${_f}" 2>&1) || { _ok=0; break; }
    fi
  done
  if [ "${_ok}" = 1 ]; then
    pass "${_shb}"
  else
    bad "${_shb}: ${_f} failed to parse"
    [ -n "${_perr}" ] && printf '%s\n' "${_perr}" | sed 's/^/        /'
  fi
done
[ "${_any_shell}" = 1 ] || bad "no POSIX shell found to parse with"

# ---------------------------------------------------------------------------
# STYLE.md: shipped harness/tool/command code is jq + curl + POSIX sh only — no
# awk. Tests and dev scripts are exempt. Comments are stripped first so prose
# that merely *mentions* awk doesn't trip the gate.
section "no awk in shipped code"
_aok=1
for _f in harsh.sh install.sh tools/*.sh commands/*.sh commands/*/*.sh lib/*.sh hooks/*/*.sh hooks/*/*/*.sh; do
  [ -f "${_f}" ] || continue
  if sed 's/#.*//' "${_f}" | grep -E '(^|[[:space:];|&(])awk([[:space:]]|$)' >/dev/null 2>&1; then
    bad "awk invoked in shipped file: ${_f}"; _aok=0
  fi
done
[ "${_aok}" = 1 ] && pass "shipped code is awk-free"

# ---------------------------------------------------------------------------
section "tool schemas"
_sok=1
for _t in tools/*.sh; do
  _b=$(basename "${_t}" .sh)
  [ "${_b}" = tool ] && continue
  sh "${_t}" --schema 2>/dev/null | jq -e '.name and .input_schema' >/dev/null 2>&1 \
    || { bad "invalid schema: ${_b}"; _sok=0; }
done
sh tools/tool.sh schemas 2>/dev/null | jq -e 'type=="array" and length>0' >/dev/null 2>&1 \
  || { bad "aggregated schemas not a non-empty array"; _sok=0; }
[ "${_sok}" = 1 ] && pass "all tool schemas valid"

# ---------------------------------------------------------------------------
section "test suite (tests/run.sh)"
# The harness is hermetic — every test runs in its own tempdir, so this never
# touches the real sessions/, logs/, or hooks/ directories.
_out="$(sh tests/run.sh 2>&1)"; _rc=$?
if [ "${_rc}" = 0 ]; then
  pass "$(printf '%s\n' "${_out}" | tail -1)"
else
  bad "test failures:"
  printf '%s\n' "${_out}" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# The source-tour site (site/) is a Bun/TypeScript project with its own unit
# tests. Run them when bun and site/ are both present; otherwise skip, so the
# shell-only gate still runs anywhere. Fresh clones need three steps in order:
# install deps, build (app.ts imports src/generated.json — an ignored build
# artifact build.ts produces, so the tests can't load without it), then test.
# --frozen-lockfile matches CI and refuses to mutate bun.lock, so a stale
# lockfile fails loudly. The chain stops at the first failure; on any failure
# the combined output (which names the failing step) is shown.
section "site build + unit tests (bun)"
if [ ! -f site/package.json ]; then
  skip "no site/ project"
elif ! command -v bun >/dev/null 2>&1; then
  skip "bun not installed"
else
  _bout=$( (cd site \
            && bun install --frozen-lockfile \
            && bun run build \
            && bun test) 2>&1 ); _brc=$?
  if [ "${_brc}" = 0 ]; then
    _bsum=$(printf '%s\n' "${_bout}" | grep -iE 'ran [0-9]+ test|[0-9]+ pass' | tail -1)
    pass "${_bsum:-bun build + test passed}"
  else
    bad "site build/test failed:"
    printf '%s\n' "${_bout}" | sed 's/^/    /'
  fi
fi

# ---------------------------------------------------------------------------
section "result"
if [ "${_fail}" = 0 ]; then
  printf 'ALL GATES PASSED\n'; exit 0
else
  printf 'GATES FAILED\n'; exit 1
fi
