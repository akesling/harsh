#!/usr/bin/env sh
# tests/run.sh — hermetic test runner for harsh.
#
#   tests/run.sh [FILTER]
#
# Discovers test_* functions in tests/*_test.sh and runs each one in its own
# isolated subshell with a private tempdir: a sandbox config redirects the
# session, log, and hooks directories into that tempdir, so a run never touches
# the real sessions/, logs/, or hooks/. HARSH_MOCK=1 keeps it offline.
# FILTER, if given, restricts to tests whose "file:function" contains it.
# HARSH_TEST_SH selects the shell that runs the harness-under-test (default
# `sh`; e.g. HARSH_TEST_SH=zsh or HARSH_TEST_SH="busybox sh").
set -u
if [ -n "${ZSH_VERSION:-}" ]; then
  emulate sh 2>/dev/null || setopt sh_word_split 2>/dev/null || true
fi
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
_tests="${ROOT}/tests"
_lib="${_tests}/lib.sh"
_filter=${1:-}

command -v jq >/dev/null 2>&1 || { echo "tests: jq is required" >&2; exit 1; }

_tmp=$(mktemp -d)
trap 'rm -rf "${_tmp}"' EXIT INT TERM

_total=0; _passed=0; _failed=0
for _file in "${_tests}"/*_test.sh; do
  [ -f "${_file}" ] || continue
  _base=$(basename "${_file}" .sh)
  # Discover test functions by scanning the file (portable: no `declare -F`).
  grep -E '^[[:space:]]*test_[A-Za-z0-9_]+[[:space:]]*\(\)' "${_file}" \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*\(\).*$//' > "${_tmp}/fns" || true
  printf '\n# %s\n' "${_base}"
  while IFS= read -r _fn; do
    [ -n "${_fn}" ] || continue
    if [ -n "${_filter}" ]; then
      case "${_base}:${_fn}" in *"${_filter}"*) : ;; *) continue ;; esac
    fi
    _total=$((_total + 1))

    # Per-test sandbox: a config that inherits the real one but redirects all
    # writable state into a throwaway tempdir.
    _td=$(mktemp -d)
    mkdir -p "${_td}/hooks"
    {
      printf '. %s/harsh.conf\n' "${ROOT}"
      printf 'HARSH_SESSIONS_DIR=%s/sessions\n' "${_td}"
      printf 'HARSH_LOG_DIR=%s/logs\n' "${_td}"
      printf 'HARSH_HOOKS_DIR=%s/hooks\n' "${_td}"
    } > "${_td}/conf"

    if (
        export HARSH_CONFIG="${_td}/conf" HARSH_MOCK=1 HARSH_HOOKS_DIR="${_td}/hooks"
        # shellcheck source=/dev/null
        . "${_lib}"
        # shellcheck source=/dev/null
        . "${_file}"
        "${_fn}"
      ) > "${_tmp}/out" 2>&1
    then
      _passed=$((_passed + 1)); printf '  ok    %s\n' "${_fn}"
    else
      _failed=$((_failed + 1)); printf '  FAIL  %s\n' "${_fn}"
      sed 's/^/        /' "${_tmp}/out"
    fi
    rm -rf "${_td}"
  done < "${_tmp}/fns"
done

printf '\n%d passed, %d failed, %d total\n' "${_passed}" "${_failed}" "${_total}"
[ "${_failed}" = 0 ]
