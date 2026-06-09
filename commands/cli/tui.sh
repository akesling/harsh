#!/usr/bin/env sh
# tui — launch the fzf chat TUI (harsh_tui.sh). Lives in commands/cli/ because it
# hands off to a full-screen interactive program: it is a CLI entry point, not an
# interactive /slash. (repl stays an engine primitive because it runs the agent
# loop in-process; tui merely execs another script, so it is just a command.)
set -u
[ "${1:-}" = --describe ] && { printf 'tui [SESSION]\tLaunch the fzf chat TUI.\n'; exit 0; }
exec sh "${SELF_DIR}/harsh_tui.sh" "$@"
