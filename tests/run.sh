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
set -u
if [ -n "${ZSH_VERSION:-}" ]; then
  emulate sh 2>/dev/null || setopt sh_word_split 2>/dev/null || true
fi
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
TESTS="$ROOT/tests"
LIB="$TESTS/lib.sh"
filter=${1:-}

command -v jq >/dev/null 2>&1 || { echo "tests: jq is required" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

total=0; passed=0; failed=0
for file in "$TESTS"/*_test.sh; do
  [ -f "$file" ] || continue
  base=$(basename "$file" .sh)
  # Discover test functions by scanning the file (portable: no `declare -F`).
  grep -E '^[[:space:]]*test_[A-Za-z0-9_]+[[:space:]]*\(\)' "$file" \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*\(\).*$//' > "$tmp/fns" || true
  printf '\n# %s\n' "$base"
  while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    if [ -n "$filter" ]; then
      case "$base:$fn" in *"$filter"*) : ;; *) continue ;; esac
    fi
    total=$((total + 1))

    # Per-test sandbox: a config that inherits the real one but redirects all
    # writable state into a throwaway tempdir.
    td=$(mktemp -d)
    mkdir -p "$td/hooks"
    {
      printf '. %s/harsh.conf\n' "$ROOT"
      printf 'HARSH_SESSIONS_DIR=%s/sessions\n' "$td"
      printf 'HARSH_LOG_DIR=%s/logs\n' "$td"
      printf 'HARSH_HOOKS_DIR=%s/hooks\n' "$td"
    } > "$td/conf"

    if (
        export HARSH_CONFIG="$td/conf" HARSH_MOCK=1 HARSH_HOOKS_DIR="$td/hooks"
        # shellcheck source=/dev/null
        . "$LIB"
        # shellcheck source=/dev/null
        . "$file"
        "$fn"
      ) > "$tmp/out" 2>&1
    then
      passed=$((passed + 1)); printf '  ok    %s\n' "$fn"
    else
      failed=$((failed + 1)); printf '  FAIL  %s\n' "$fn"
      sed 's/^/        /' "$tmp/out"
    fi
    rm -rf "$td"
  done < "$tmp/fns"
done

printf '\n%d passed, %d failed, %d total\n' "$passed" "$failed" "$total"
[ "$failed" = 0 ]
