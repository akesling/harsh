# Changelog

## 0.2.0 — 2026-06-09

The "double down on the core" release: the fzf TUI is gone, and the engine
grew the features an agent loop actually needs at scale.

### Added
- **Context compaction**: `harsh.sh compact SESSION` (also `/compact` in the
  REPL) summarizes the conversation, archives the full history inside the
  session directory (`archive/<timestamp>/`), and restarts from the summary.
  The loop auto-compacts when the last turn's context passes
  `HARSH_COMPACT_AT` tokens (default 150000; 0 disables); a pending,
  unanswered prompt survives. Compaction is a **drop-in command**
  (`commands/compact.sh`) holding the summarization policy; the engine
  contributes the invariant-bearing primitives it composes: `archive`
  (move history aside, keep a pending prompt), `send -m` (synthetic
  metadata-tagged entry), and `run-hooks` (fire hook events from commands).
- **PreCompact hook event**: exit 2 blocks a compaction; stdout adds guidance
  to the summarizer instruction.
- **Streaming** (`HARSH_STREAM=1`, Anthropic only): replies print live,
  token-by-token; the canonical session record is reconstructed from the SSE
  stream (`harsh.sh stream-assemble` exposes the transform for tests).
- **Retry with backoff**: transient API failures (network, 408/429/5xx —
  including Anthropic's 529 overloaded) retry up to `HARSH_RETRIES` times,
  starting at `HARSH_RETRY_DELAY` seconds and doubling.
- **Truncation handling**: a `max_tokens` stop no longer reads as a clean
  finish — the loop warns and re-steps (bounded) so the model continues the
  cut-off reply. Default `HARSH_MAX_TOKENS` raised 4096 → 8192.
- CI now *runs* the test suite under dash, bash, zsh, and busybox sh
  (`HARSH_TEST_SH`), plus macOS — the portability claim is executed, not just
  parsed. New quality gate rejects `awk` in shipped code.

### Removed
- **The fzf TUI** (`harsh_tui.sh`, the `tui` command). The dependency-free
  line REPL is the interactive mode; fzf is no longer used anywhere.

### Fixed
- `write` tool: a call missing `content` now errors instead of clobbering the
  target file with the literal string `null`.
- `read` tool: non-numeric `offset`/`limit` are errors instead of a silent
  empty read; awk dependency removed (STYLE.md violation).
- `edit` tool: built-in diff colorizer rewritten in sed (no awk).
- `grep` tool: output truncation at 200 lines is now announced.
- `bash` tool: non-numeric `timeout` is an error.
- `tools/tool.sh`: tool names are sanitized against path traversal, matching
  the command dispatcher.
- API key is passed to curl via a private header file, never argv (was
  visible in `ps` during requests).
- `install.sh`: `--help` no longer prints a stray `set -u` / drops its first
  line; options missing a value fail cleanly; `--uninstall` refuses to delete
  a non-launcher file; re-installing to a new `--share` warns about a stale
  kept config.
- CI preview deploys: the PR number is resolved server-side from the run's
  head SHA — the artifact value was spoofable, letting a malicious PR hijack
  another PR's preview alias and sticky comment. All GitHub Actions are now
  SHA-pinned, with Dependabot keeping them fresh.
- `commands/verbose.sh` no longer crashes under `set -u` when SEQ is omitted.

## 0.1.0

Initial release: the core loop (`harsh.sh`), session-as-directory storage,
drop-in tools/skills/hooks/commands, Anthropic + OpenAI providers, prompt
caching, sub-agents, the line REPL, the fzf TUI, installer, hermetic test
suite, and the source-tour site.
