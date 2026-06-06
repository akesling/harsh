#!/usr/bin/env sh
# tool — run a tool by name (JSON input on stdin); the CLI face of the dispatcher.
# Lives in commands/cli/ (CLI-only): it reads stdin, so it is meaningless as an
# interactive /slash and is never offered as one.
set -u
[ "${1:-}" = --describe ] && { printf 'tool NAME\tRun a tool by name (JSON input on stdin).\n'; exit 0; }
# $HARSH_TOOLS_DIR is provided by the harness when commands run.
[ -n "${1:-}" ] || { printf 'usage: tool NAME  (JSON on stdin)\n' >&2; exit 2; }
exec sh "$HARSH_TOOLS_DIR/tool.sh" call "$1"
