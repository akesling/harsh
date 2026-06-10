# tests

A hermetic test harness for harsh. Pure POSIX sh; the only dependency beyond
the harness itself is `jq` (and a shell). A couple of tests use `awk` — that's
tolerated here as dev-only tooling; shipped code is awk-free and a quality
gate enforces it.

```sh
tests/run.sh                 # run everything
tests/run.sh hooks           # only tests whose file:function matches "hooks"
tests/run.sh test_stop       # only matching function names
HARSH_TEST_SH=zsh tests/run.sh          # harness-under-test runs under zsh
HARSH_TEST_SH='busybox sh' tests/run.sh # … or busybox (CI runs both + dash/bash)
```

## How it works

`run.sh` discovers `test_*` functions in `tests/*_test.sh` and runs **each one
in its own subshell with its own tempdir**. A generated sandbox config inherits
the real `harsh.conf` but redirects `HARSH_SESSIONS_DIR`, `HARSH_LOG_DIR`, and
`HARSH_HOOKS_DIR` into that tempdir, and `HARSH_MOCK=1` keeps it offline. So a
test run **never touches the real `sessions/`, `logs/`, or `hooks/`** and needs
no API key.

A test passes if its function returns 0; an assertion failure prints a message
and exits non-zero. Helpers live in `lib.sh`:

- `hsh …` — run harsh against the sandbox; `hnew` — make a fresh session
- `tool NAME 'JSON'` — invoke a tool directly
- `install_hook PATH <<'EOF' … EOF` — drop a hook into the sandbox
- `assert_eq` · `assert_contains` · `assert_not_contains` · `assert_ok` ·
  `assert_fails` · `fail`

## Files

| File | Covers |
|---|---|
| `loop_test.sh`     | agent loop, on-disk format, Messages-API assembly |
| `engine_test.sh`   | failure paths: API errors, truncation, parallel tools, HTTP retry (stubbed curl), SSE reconstruction |
| `compact_test.sh`  | compaction: view rewrite + log retention, auto-trigger, pending-prompt survival, PreCompact hooks |
| `remanifest_test.sh` | the manifest-rewrite primitive: reorder/drop/compose, validation, undo |
| `provider_test.sh` | Anthropic + OpenAI request/response shapes |
| `cache_test.sh`    | prompt-cache breakpoints + usage accounting |
| `tools_test.sh`    | each built-in tool + the dispatcher + input validation |
| `hooks_test.sh`    | hook events, blocking, per-tool scoping |
| `commands_test.sh` | the extensible command dispatcher + surfaces |
| `repl_test.sh`     | the non-interactive REPL (paste, escapes, resume) |
| `agent_test.sh`    | sub-agents (the `agent` tool) |
| `install_test.sh`  | install.sh: copy/link/uninstall, config resolution |

Add a file `tests/<name>_test.sh` with `test_*` functions to extend coverage.
`scripts/quality_gates.sh` runs this suite as one of its gates.
