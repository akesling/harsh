#!/usr/bin/env sh
# config — show the effective configuration (the exported HARSH_* env, key redacted).
set -u
[ "${1:-}" = --describe ] && { printf 'config\tShow effective configuration.\n'; exit 0; }
printf 'config file: %s\n' "${HARSH_CONFIG:-<defaults>}"
set | grep '^HARSH_' | grep -v API_KEY
