#!/usr/bin/env sh
# manifest — print a session's manifest.csv.
set -u
[ "${1:-}" = --describe ] && { printf 'manifest SESSION\tPrint the session manifest.csv.\n'; exit 0; }
cat "$(sh "$HARSH_SELF" path "$1")/manifest.csv"
