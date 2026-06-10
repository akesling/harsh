# commands

Extensible CLI verbs for harsh, the same way `tools/`, `skills/`, and `hooks/`
are directories the config points at. Drop an executable `NAME.sh` here and
`harsh.sh NAME` (and `ha NAME`) runs it. The shipped derived commands (`show`,
`final`, `outline`, `verbose`, `manifest`, `sessions`, `request`, `tools`,
`schemas`, `tool`, `skills`, `hooks`, `config`, `version`) are themselves just
instances of this mechanism.

## Two tiers

`harsh.sh` keeps a small set of **engine primitives** in-process — they mutate
session state or drive the loop and can't be externalized: `init`/`new`,
`send`, `step`, `run`, `ask`, `skill`, `assemble`, `archive`, `path`,
`run-hooks`, plus `repl`. These are **reserved**: a command file can't shadow
them. Everything else is a command in this directory, built *on* the
primitives.

`compact` is the worked example of that split: the engine owns the
invariant-bearing writes (`archive` moves the answered history aside keeping a
pending prompt; `send -m META` records a synthetic, metadata-tagged entry) and
the hook runner (`run-hooks EVENT PAYLOAD` — context on stdout, exit 2 =
blocked), while `commands/compact.sh` holds the *policy*: what the summarizer
is asked, in a scratch sub-session, with what visible. Edit the file to change
the policy; delete it to opt out (the run loop's auto-trigger degrades to a
warning).

## Contract

A command is `NAME.sh`, invoked as `sh NAME.sh ARGS…`:

- **Describe:** `NAME.sh --describe` prints one line, `NAME ARGS<TAB>one-line
  help`. Used by `harsh.sh commands` and `harsh.sh help`. (Required.)

### Surfaces (by directory)

Placement decides where a command is available — no flags to interpret, the same
way hooks narrow scope with a subdirectory:

```
commands/NAME.sh        available everywhere   (CLI + REPL /NAME)       ← default
commands/cli/NAME.sh    CLI only               (harsh.sh NAME)
commands/repl/NAME.sh   REPL only              (/NAME)
```

`commands/cli/tool.sh` is CLI-only because it reads JSON on stdin, so it's never
offered as a `/slash`. The slash resolver looks in `commands/` then
`commands/repl/`; the CLI dispatcher looks in `commands/` then `commands/cli/`.
`harsh.sh commands` lists the CLI set; `harsh.sh commands repl` lists the REPL
set (and powers `/help`). Drop a file in the right directory and it appears on
the right surface(s) automatically.
- **Run:** receives the args after the command word; stdin/stdout/exit code pass
  through unchanged.
- **Environment** (exported by harsh): `HARSH_SELF` (path to `harsh.sh`),
  `HARSH_CONFIG`, `HARSH_TOOLS_DIR`, `HARSH_SKILLS_DIR`, `HARSH_HOOKS_DIR`,
  `HARSH_SESSIONS_DIR`, `HARSH_LOG_DIR`, `HARSH_LIB_DIR`, the model/API vars, and
  `HARSH_VERSION`.
- **Build on primitives** by calling back through `$HARSH_SELF`, e.g.
  `dir=$(sh "$HARSH_SELF" path "$1")`, `sh "$HARSH_SELF" assemble "$1"`,
  `sh "$HARSH_SELF" final "$1"`.
- **Shared look:** `. "$HARSH_LIB_DIR/render.sh"` for the palette + `fmt_markdown`
  (see `verbose.sh`).

Dependencies stay jq + curl + a POSIX shell (no awk).

## Example

```sh
#!/usr/bin/env sh
# cost — approximate size of a conversation.
set -u
[ "${1:-}" = --describe ] && { printf 'cost SESSION\tApproximate size of a conversation.\n'; exit 0; }
dir=$(sh "$HARSH_SELF" path "$1")
printf 'entries: %s  bytes: %s\n' \
  "$(sh "$HARSH_SELF" manifest "$1" | grep -c .)" "$(cat "$dir"/[0-9]*.json | wc -c | tr -d ' ')"
```

`harsh.sh cost SESSION` now works and shows up in `harsh.sh help`.
