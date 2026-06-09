#!/usr/bin/env sh
# resume ID — switch the interactive session. Validates the target, writes it to
# $HARSH_SESSION_OUT (the REPL/TUI loop reads that file and switches to it), then
# shows the resumed session. Lives in commands/repl/ so it is offered only on the
# interactive surfaces. Its argument is the TARGET to switch to, not the current
# session — so the usage says "ID", not "SESSION", to opt out of the loop's
# auto-fill of the current session as $1.
set -u
[ "${1:-}" = --describe ] && { printf 'resume ID\tSwitch to another session (interactive).\n'; exit 0; }
[ -n "${1:-}" ] || { printf 'usage: /resume <ID>   (see /sessions)\n' >&2; exit 1; }
[ -n "${HARSH_SESSION_OUT:-}" ] || { printf 'resume only works inside the REPL/TUI.\n' >&2; exit 1; }
_dir=$(sh "${HARSH_SELF}" path "$1")
if [ -d "${_dir}" ] && [ -f "${_dir}/manifest.csv" ]; then
  printf '%s' "$1" > "${HARSH_SESSION_OUT}"   # ask the loop to switch
  printf '[resumed: %s]\n' "$(basename "${_dir}")"
  sh "${HARSH_SELF}" show "${_dir}"
else
  printf 'no such session: %s\n' "$1" >&2; exit 1
fi
