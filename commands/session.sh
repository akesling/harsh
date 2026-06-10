#!/usr/bin/env sh
# session SESSION — print the current session's directory (the REPL fills in
# the current session). A thin reader over the `path` primitive.
set -u
[ "${1:-}" = --describe ] && { printf 'session SESSION\tPrint the current session directory.\n'; exit 0; }
sh "${HARSH_SELF}" path "$1"
