# Changelog

## Unreleased

### Added
- **Tool permissions, built entirely as hooks** (no policy logic in the core):
  `hooks/PreToolUse/10-permissions.sh` is a declarative, layered gate
  (session grants → project `.harsh/permissions.json` → user config → built-in
  default) deciding allow / ask / deny per call. `ask` prompts on the terminal
  (`y`/`a`/`n`), persists session grants, and fails **closed** with no
  terminal; denials teach the model; every decision is audited to
  `permissions.log` in the session dir. Dormant until opted in via
  `HARSH_PERMISSIONS_MODE` or a policy file. Manage with `harsh.sh permissions`
  (`/permissions` in the REPL). Replaces the old `PreToolUse/bash/10-guard.sh`
  example, whose rules became the default policy.
- **PreToolUse input rewriting**: a hook may rewrite a tool call's input by
  writing a replacement payload to `HARSH_HOOK_REWRITE_OUT`. Rewrites chain in
  filename order, so authorization and execution-wrapping compose. Generic and
  backward-compatible (no-op when the var is unset).
- **`hooks/PreToolUse/20-sandbox.sh`** (opt-in `HARSH_SANDBOX=1`): a rewriter
  that wraps `bash` commands in `sandbox-exec`/`bwrap` for confined execution —
  the enforcement wall beneath the permission policy brain, and the worked
  example of rewrite-based sandboxing.

### Fixed
- `harsh.sh hooks` now lists `PreCompact` hooks (was omitted).

## 0.2.0 — 2026-06-09

The "double down on the core" release: the fzf TUI is gone, and the engine
grew the features an agent loop actually needs at scale.

### Added
- **Sessions are now an immutable log + a live view**: entry files are
  append-only (never moved, renumbered, or deleted) and `manifest.csv` is the
  ordered view over them that `assemble` reads. The new `remanifest`
  primitive rewrites the view from one spec (ordered refs + composed
  entries), retiring the outgoing view as `manifest-<ts>.csv` — so any
  context-editing scheme is non-destructive and undoable, and copying the
  session directory copies its entire evolution.
- **Context compaction**: `harsh.sh compact SESSION` (also `/compact` in the
  REPL) summarizes the live conversation in an auditable `compact-*` scratch
  session and rewrites the view to `[summary, pending prompt]`. The loop
  auto-compacts when the last turn's context passes `HARSH_COMPACT_AT` tokens
  (default 150000; 0 disables); a pending, unanswered prompt survives
  verbatim. Compaction is a **drop-in command** (`commands/compact.sh`)
  holding pure policy over `remanifest` + `run-hooks` (which lets commands
  fire hook events through the engine).
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
