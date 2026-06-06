# harsh

An agent harness like no other. **Pure portable shell.**

The core is a single script (`harsh.sh`) that drives an LLM agent loop over a
session directory: one file per turn / tool call, plus a `manifest.csv` of
lightweight metadata. Maximum dependencies are **jq**, **curl**, and a
bash-like shell — `bash`, `zsh`, and `ash` are all supported. A chat-style TUI
(`harsh_tui.sh`) turns it into a usable chat/coding interface, with fzf used
only as an optional turn-browser.

```
harsh/
├── harsh.sh          # the core — fully functional on its own
├── harsh_tui.sh      # chat-style TUI (fzf optional, only for /browse)
├── harsh.conf        # configuration (sourced by harsh.sh)
├── tools/            # one file per tool, + tool.sh dispatcher
│   ├── tool.sh       # every tool call runs through this
│   ├── bash.sh  read.sh  write.sh  edit.sh  ls.sh  grep.sh  skills.sh
├── skills/           # callable skills (Skills tool + /slash commands)
│   └── <name>/SKILL.md
├── hooks/            # directory-layout hooks (Claude Code style)
│   └── <Event>/[<tool>/]*.sh
├── tests/            # hermetic test harness (run.sh + *_test.sh)
├── scripts/          # dev tooling (quality_gates.sh)
├── sessions/         # one directory per conversation
│   └── <session>/
│       ├── manifest.csv          # one line per entry (metadata)
│       └── NNNN-role-type[-name].json   # one file per entry
└── logs/             # request/response logs
```

## Design

### Conversation = a folder of files + a manifest

Each conversation entry is a single JSON file holding one content **block**
tagged with its role:

```json
{ "role": "assistant", "block": { "type": "tool_use", "id": "...", "name": "bash", "input": {"command": "ls"} } }
```

Files are named `NNNN-<role>-<type>[-<name>].json` and sort in conversation
order. `harsh.sh assemble` groups consecutive same-role blocks into the
Anthropic Messages API `messages[]` array — so the on-disk granularity is "one
per turn/tool call" while the wire format stays correct.

`manifest.csv` carries only lightweight metadata, one comma-free line per entry:

```
seq,role,type,name,file,timestamp,status
```

A process interested in marginal additions can simply `tail -f manifest.csv`
and react to each new line.

### Tools

Every tool is an executable `tools/NAME.sh` that:

- prints its schema (an Anthropic tool definition) with `--schema`, and
- reads a JSON object on stdin and writes a text result to stdout when run.

`tools/tool.sh` is the dispatcher every call goes through
(`tool.sh schemas`, `tool.sh call NAME`). Built-in tools: `bash`, `read`,
`write`, `edit`, `ls`, `grep`, `skills`, and `agent` (sub-agents, below).

### Sub-agents

Sub-agents fall out of the design as *just another tool* — no special awareness
in `harsh.sh`. `tools/agent.sh` takes `{task, label?}`, creates a fresh child
session, runs harsh's normal loop there to completion, and returns only the
child's **final** message. The parent's context stays clean: it sees the
summary, not the child's intermediate steps.

It works because the harness exports two things tools can rely on: `HARSH_SELF`
(the path to `harsh.sh`) and `HARSH_CONFIG` (the resolved config), so a tool can
re-invoke harsh with the identical configuration. Result extraction uses the
`harsh.sh final SESSION` command (jq-only). Child sessions are written under the
normal sessions dir, prefixed `agent-`, so they remain fully inspectable. A
depth guard (`HARSH_AGENT_DEPTH`, cap `HARSH_AGENT_MAX_DEPTH`, default 3) rides
along in the environment so sub-agents can't recurse forever.

### Skills

A skill is `skills/NAME/SKILL.md` with YAML front-matter (`name`,
`description`) and instructions. The **skills** tool loads a skill on demand;
in the TUI a skill is also reachable as a `/NAME` slash command, à la Claude
Code.

### Hooks

Hooks let you observe and gate the loop, Claude-Code style, with a pure
directory layout — no config file to parse. Drop an executable `*.sh` into the
directory for an event and harsh runs it at that point, feeding the event as
JSON on stdin:

```
hooks/
├── SessionStart/        once, when a session is created (inject opening context)
├── UserPromptSubmit/    before a prompt is recorded (gate it / add context)
├── PreToolUse/          before any tool call
│   └── bash/            ... only before the `bash` tool (per-tool scoping)
├── PostToolUse/         after a tool call (append feedback)
└── Stop/                when a turn ends (force another turn)
```

A hook's **exit code** is its decision: `2` blocks (its stdout is the reason),
`0` allows (stdout is collected as context), anything else is a logged,
non-blocking error. Blocking means: reject the prompt (`UserPromptSubmit`), skip
the tool and feed the reason back to the model (`PreToolUse`), or keep going
(`Stop`). A hook in `PreToolUse/` runs before every tool; one in
`PreToolUse/<tool>/` runs only before that tool. List installed hooks with
`harsh.sh hooks`. Full contract and payload shapes: `hooks/README.md`. Ships
with `PreToolUse/bash/10-guard.sh` (blocks destructive commands) and
`SessionStart/10-context.sh` (injects cwd/git context).

## Install

```sh
git clone <repo> harsh && cd harsh
./install.sh                 # writes a config + an `ha` launcher on your PATH
export ANTHROPIC_API_KEY=sk-ant-...
ha                           # REPL   (HARSH_MOCK=1 ha  to try it offline)
ha tui                       # fzf chat TUI
```

`install.sh` copies the runtime (`harsh.sh`, `harsh_tui.sh`, `tools/`,
`skills/`, `hooks/`) into `~/.local/share/harsh/`, writes
`~/.config/harsh/harsh.conf` naming every directory by absolute path, and drops
an `ha` launcher in `~/.local/bin/`. The launcher just exports `HARSH_CONFIG`
and execs the installed `harsh.sh` — so harsh finds its directories purely from
the config, independent of where or how `ha` is invoked (no `$PATH`/symlink
magic). **After installing, the checkout is disposable.** Sessions and logs
default under the install root; reinstalling refreshes program files but never
touches your sessions.

Layout:

```
~/.local/share/harsh/   harsh.sh, harsh_tui.sh, tools/, skills/, hooks/, sessions/, logs/
~/.config/harsh/harsh.conf
~/.local/bin/ha
```

Flags: `--prefix` (bin dir), `--name` (default `ha`), `--share` (install root),
`--config`, `--data` (session/log dir), `--link` (run from the checkout instead
of copying — handy while hacking on harsh), `--uninstall` (removes the launcher;
keeps your config + data). Deps stay jq + curl + a shell.

Or skip the installer entirely and run `./harsh.sh` straight from the checkout
(it reads the repo-local `harsh.conf`).

## Quick start

```sh
# Configure (or just use env vars)
export ANTHROPIC_API_KEY=sk-ant-...

# Interactive REPL — this is the default mode (no fzf needed)
./harsh.sh

# Or one-shot: create a session, ask, run the loop
sess=$(./harsh.sh new)
./harsh.sh ask "$sess" "List the files here and tell me what this project is."

# Inspect the result
./harsh.sh show "$sess"
./harsh.sh manifest "$sess"
```

### REPL

Running `./harsh.sh` with no command drops into a dependency-free, line-based
REPL — the core's own interactive mode (`harsh_tui.sh` is the richer fzf
front-end). Type a message and press Enter; the agent runs and prints as it
goes. Slash commands: `/tools`, `/skills`, `/SKILL [args]`, `/show`,
`/session`, `/sessions`, `/resume <ID>`, `/new`, `/help`, `/quit` (or
Ctrl-D). `/sessions` lists past conversations and `/resume <ID>` switches to
one. Pass a session name to
resume: `./harsh.sh repl my-session`. It also works non-interactively:

```sh
printf '%s\n' 'list the files' '/quit' | ./harsh.sh repl
```

### TUI

```sh
./harsh_tui.sh            # new session
./harsh_tui.sh <session>  # resume
```

A calm chat interface: a scrolling transcript on top, a real input line at the
bottom. Typing never disturbs the history — the transcript only redraws when a
turn completes. `/help`, `/tools`, `/skills`, and `/SKILL [args]` (e.g.
`/commit`, `/review`) work as slash commands. `/browse` opens an optional fzf
turn-browser if fzf is installed; `/show` redraws; `/quit` or Ctrl-D quits.

## Offline smoke test (no API key)

`HARSH_MOCK=1` swaps the model for a deterministic mock so you can exercise the
full loop, tools, and storage with no key or network. A user message containing
a `[[tool:NAME:ARG]]` marker makes the mock emit that tool call:

```sh
sess=$(HARSH_MOCK=1 ./harsh.sh new)
HARSH_MOCK=1 ./harsh.sh ask "$sess" 'run this: [[tool:bash:echo hello from harsh]]'
HARSH_MOCK=1 ./harsh.sh show "$sess"
```

## Commands

Run `./harsh.sh help` for the full list. Highlights:

| Command | Description |
|---|---|
| `init [NAME]` / `new` | Create a session (prints its directory) |
| `send SESSION TEXT` | Append a user message |
| `step SESSION` | One model turn (runs tools if requested) |
| `run SESSION` | Run the loop to completion |
| `ask SESSION TEXT` | `send` + `run` |
| `skill SESSION NAME [ARGS]` | Load and run a skill |
| `final SESSION` | Print the last assistant message (sub-agent result) |
| `assemble` / `request` / `manifest` / `show` | Inspect state |
| `tools` / `schemas` / `skills` | Discover capabilities |

## Tests & quality gates

```sh
tests/run.sh                 # hermetic test suite (jq only; HARSH_MOCK, offline)
scripts/quality_gates.sh     # shellcheck + cross-shell parse + schemas + tests
```

Every test runs in its own tempdir with a sandbox config, so a run never
touches the real `sessions/`, `logs/`, or `hooks/`. See `tests/README.md`.

## Portability notes

Scripts target POSIX `sh` and avoid arrays, `[[ ]]`, and process substitution.
zsh is normalized with `emulate sh`. Structured work is delegated to `jq` rather
than fragile shell string munging.