#!/usr/bin/env sh
# version — print the harsh version.
set -u
[ "${1:-}" = --describe ] && { printf 'version\tPrint the harsh version.\n'; exit 0; }
printf 'harsh %s\n' "${HARSH_VERSION:-?}"
