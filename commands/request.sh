#!/usr/bin/env sh
# request — print the full wire request body a step would send (debug aid), in
# the configured provider's format. Delegates to harsh's `build-request`
# primitive so the provider-specific builder lives in exactly one place.
set -u
[ "${1:-}" = --describe ] && { printf 'request SESSION\tPrint the full request body that would be sent.\n'; exit 0; }
sh "${HARSH_SELF}" build-request "$1"
