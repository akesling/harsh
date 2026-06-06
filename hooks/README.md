# hooks

Directory-layout hooks for harsh, modeled on Claude Code. Drop an executable
`*.sh` into the directory for an event and harsh runs it at that point in the
loop, feeding the event payload as JSON on **stdin**.

```
hooks/
├── SessionStart/        once, when a new session is created
├── UserPromptSubmit/    before a user message is recorded
├── PreToolUse/          before a tool call runs
│   └── <tool>/          ... only before that specific tool (e.g. bash/)
├── PostToolUse/         after a tool call runs
└── Stop/                when the agent finishes a turn (end of run)
```

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
- **SessionStart / PostToolUse** are context-only; their stdout is injected
  (opening context / appended to the tool result) and exit 2 isn't special.

## Payload (stdin JSON)

```jsonc
// PreToolUse / PostToolUse
{ "event": "PreToolUse", "session_dir": "...", "tool_name": "bash",
  "tool_input": { "command": "ls" } }
// PostToolUse additionally has: "tool_output": "...", "is_error": false
// UserPromptSubmit
{ "event": "UserPromptSubmit", "session_dir": "...", "prompt": "..." }
// SessionStart / Stop
{ "event": "SessionStart", "session_dir": "..." }
```

Parse it with jq, e.g. `cmd=$(jq -r '.tool_input.command // ""')`.

See `PreToolUse/bash/10-guard.sh` and `SessionStart/10-context.sh` for working
examples. List what's installed with `harsh.sh hooks`.
