#!/usr/bin/env sh
# schemas — print the tools[] JSON array (the tool schemas sent to the model).
set -u
[ "${1:-}" = --describe ] && { printf 'schemas\tPrint the tools[] JSON array.\n'; exit 0; }
exec sh "$HARSH_TOOLS_DIR/tool.sh" schemas
