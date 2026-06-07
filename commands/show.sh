#!/usr/bin/env sh
# show — replay a session's transcript with the same styling as the live REPL
# (colored speaker headers, markdown prose, collapsed tool lines). Used by
# /resume so a resumed conversation looks just like an ongoing one.
set -u
[ "${1:-}" = --describe ] && { printf 'show SESSION\tReplay a session transcript (styled).\n'; exit 0; }
# shellcheck source=/dev/null
. "${HARSH_LIB_DIR}/render.sh"
_dir=$(sh "${HARSH_SELF}" path "$1")
render_transcript "${_dir}"
