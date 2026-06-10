# harsh — style & conventions

House rules for contributing to harsh. Keep it boring, portable, and consistent.
When in doubt, run `scripts/quality_gates.sh` — it encodes most of this.

## Dependencies

The runtime depends on **jq**, **curl**, and a **POSIX shell** — only, ever. No
`awk`, `python`, `perl`, or coreutils-beyond-POSIX in shipped harness/tool/command
code. Push structured work into `jq` rather than awk/sed gymnastics. (A few
*tests* use `awk`; that's tolerated as dev-only — don't add it to shipped code.
`scripts/quality_gates.sh` enforces the no-awk rule over shipped files.)

## Portability

Target POSIX `sh`; it must parse and run under bash, zsh, and ash/dash.

- No arrays, `[[ … ]]`, `local`, or process substitution `<(…)`.
- Normalize zsh with the `emulate sh` guard at the top of executable scripts.
- Use `printf`, not `echo -e`. Prefer `case` over regex when a glob will do.
- Invoke sibling scripts through `sh "$path"` (works without the +x bit / on
  noexec mounts).

## Shell variable style

1. **Locals / script-internal vars are `_snake_case`** with a leading
   underscore: `_dir`, `_cfg`, `_seq`. This includes internal "globals" like
   `_config_file`, `_repo`, and a script's own directory (`_self_dir`).
2. **UPPER_CASE is reserved for *actively communicating* vars** — exported or
   env that crosses a process boundary: `HARSH_*`, `SELF_DIR`, the
   `C_*`/`GUTTER`/`BULLET` palette from `lib/render.sh`, and external env
   (`PATH`, `HOME`, `ZSH_VERSION`, `NO_COLOR`, `XDG_*`).
3. **Brace every non-canonical read**: `${_dir}`, `${HARSH_MODEL}`. Leave the
   canonical/special forms bare: `$1 … $9 $@ $* $# $? $$ $0 $-`, and bare names
   inside `$(( … ))`.
4. **Don't touch jq/awk program internals.** Inside `jq '…$x…'` or `awk '…'`,
   `$x` is a *jq/awk* variable — leave it. Only the shell *value* passed in
   (`--arg foo "${_shellvar}"`) gets braced. Intentional literal `$NAME` in
   output strings (single-quoted, e.g. PATH advice) stays literal — flag it with
   `# shellcheck disable=SC2016`.

`lib/render.sh` is the reference example.

## Comments

Explain *why*, not *what*. Prefer one tight line; reserve multi-line blocks for
genuinely non-obvious behavior (hook firing order, captured-stdout pitfalls,
on-disk format invariants). Keep contracts (`run_hooks`, `resolve_command`) as
short header comments.

## Quality gate

Every change must keep `scripts/quality_gates.sh` green:

- `shellcheck --shell=sh` clean across all shell files (no findings, default
  severity — info counts).
- Parses under every installed shell.
- Tool schemas valid; the hermetic test suite passes.
- The `site/` Bun unit tests pass when `bun` is installed (the gate runs
  `bun install --frozen-lockfile` first, so a stale `bun.lock` fails loudly).
  Optional dep: the step skips cleanly when `bun`/`site/` are absent.

Add a `tests/<area>_test.sh` with `test_*` functions for new behavior. The runner
is hermetic (per-test tempdir) — never touch the real `sessions/` or `logs/`.

## Extension points (directories the config names)

Add a feature by dropping a file in a directory, not by editing the core:

- `tools/NAME.sh` — model-callable tools (`--schema` + JSON on stdin).
- `skills/NAME/SKILL.md` — loadable skill instructions.
- `hooks/<Event>/[<tool>/]*.sh` — observe/gate the loop. See `hooks/README.md`.
- `commands/NAME.sh` (+ `cli/`, `repl/` subdirs for surface) — CLI/REPL verbs.
  See `commands/README.md`.

The engine primitives in `harsh.sh` (`init`, `send`, `step`, `run`, `ask`,
`assemble`, `path`, …) are reserved: commands *read* a session, the engine
*writes* it. Don't externalize writes.
