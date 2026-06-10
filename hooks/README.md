# hooks

Directory-layout hooks for harsh, modeled on Claude Code. Drop an executable
`*.sh` into the directory for an event and harsh runs it at that point in the
loop, feeding the event payload as JSON on **stdin**.

```
hooks/
├── lib/                 shared helpers, sourced by hooks (not an event dir)
├── SessionStart/        once, when a new session is created
├── UserPromptSubmit/    before a user message is recorded
├── PreToolUse/          before a tool call runs (gate / rewrite)
│   └── <tool>/          ... only before that specific tool (e.g. bash/)
├── PostToolUse/         after a tool call runs
├── PreCompact/          before a session is compacted (summarize + view rewrite)
└── Stop/                when the agent finishes a turn (end of run)
```

(`lib/` is a plain helper directory, not an event — harsh only runs `*.sh`
directly under an event dir or its `<tool>/` subdir, so files in `lib/` are
sourced by hooks, never fired as hooks.)

A hook directly in `PreToolUse/` runs before **every** tool call. A hook in
`PreToolUse/<tool>/` (e.g. `PreToolUse/bash/`) runs **only** before that tool.
Within a directory, hooks run in sorted filename order (so prefix them `10-`,
`20-`, …). Hooks are invoked as `sh hook.sh`, so they need not be executable.

## Contract (per hook)

| Exit code | Meaning |
|---|---|
| `0` | allow / success. stdout is collected as **context** |
| `2` | **block**. stdout is the reason; no further hooks run |
| other | non-blocking error — logged to `logs/hooks.log`, ignored |

What blocking does per event:

- **UserPromptSubmit** `exit 2` → the prompt is rejected (not recorded).
- **PreToolUse** `exit 2` → the tool is **not run**; the reason is fed back to
  the model as an error tool result.
- **Stop** `exit 2` → the agent does **not** stop; the reason is injected as a
  new user message and it takes another turn (capped to avoid loops).
- **PreCompact** `exit 2` → the compaction is skipped. On allow, stdout is
  appended to the summarizer instruction (e.g. "keep the build commands").
- **SessionStart / PostToolUse** are context-only; their stdout is injected
  (opening context / appended to the tool result) and exit 2 isn't special.

## Rewriting tool input (PreToolUse)

A `PreToolUse` hook can **rewrite** the call instead of just allowing or
blocking it. When harsh runs the hook it sets `HARSH_HOOK_REWRITE_OUT` to a
file path; write a replacement payload (the full event JSON, with an edited
`.tool_input`) there and harsh runs the tool with the new input:

```sh
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
printf '%s' "$payload" | jq -c --arg c "firejail -- $cmd" '.tool_input.command=$c' \
  > "$HARSH_HOOK_REWRITE_OUT"
exit 0          # allow, with the rewritten input
```

Rewrites **chain in filename order**: each hook sees the previous one's output,
so you can authorize intent in one hook and wrap it for execution in the next.
A hook that writes nothing (or invalid JSON) leaves the input untouched. This
is what makes sandboxing composable — see `PreToolUse/20-sandbox.sh`. (The
channel is generic: any event with `HARSH_HOOK_REWRITE_OUT` set can rewrite its
payload; harsh wires it for `PreToolUse` today.)

## Payload (stdin JSON)

```jsonc
// PreToolUse / PostToolUse
{ "event": "PreToolUse", "session_dir": "...", "tool_name": "bash",
  "tool_input": { "command": "ls" } }
// PostToolUse additionally has: "tool_output": "...", "is_error": false
// UserPromptSubmit
{ "event": "UserPromptSubmit", "session_dir": "...", "prompt": "..." }
// SessionStart / Stop / PreCompact
{ "event": "SessionStart", "session_dir": "..." }
```

Parse it with jq, e.g. `cmd=$(jq -r '.tool_input.command // ""')`.

## Shipped hooks

- **`PreToolUse/10-permissions.sh`** — the tool **permission gate**: a
  declarative, layered policy (session grants → project `.harsh/permissions.json`
  → user `~/.config/harsh/permissions.json` → built-in default) decides
  allow / ask / deny per call. "ask" prompts on the terminal and can persist a
  session grant; with no terminal it fails **closed**. It is dormant until you
  opt in (set `HARSH_PERMISSIONS_MODE=allow|ask|deny` or drop a policy file),
  so installing it changes nothing until configured. Shared logic lives in
  `hooks/lib/permissions.sh`; inspect/manage it with `harsh.sh permissions`.
  This is a **policy** gate, not a sandbox — it governs an honest model's
  *intent*; it cannot contain an adversarial one.
- **`PreToolUse/20-sandbox.sh`** — an opt-in (`HARSH_SANDBOX=1`) **rewriter**
  that wraps the `bash` command in `sandbox-exec`/`bwrap` for confined
  execution: the enforcement wall beneath the permission policy brain. A
  starting point with deliberately loose profiles — tighten for your threat
  model.
- **`SessionStart/10-context.sh`** — injects cwd/git context at session start.

List what's installed with `harsh.sh hooks`.
