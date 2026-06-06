#!/usr/bin/env sh
# show — print a session's transcript in a readable, plain form.
set -u
[ "${1:-}" = --describe ] && { printf 'show SESSION\tPrint a readable transcript.\n'; exit 0; }
dir=$(sh "$HARSH_SELF" path "$1")
for f in "$dir"/[0-9]*.json; do
  [ -e "$f" ] || continue
  jq -r '.role as $r | .block as $b |
    "[" + $r + "/" + $b.type + "] " +
    (if $b.type=="text" then $b.text
     elif $b.type=="tool_use" then ($b.name + " " + ($b.input|tojson))
     elif $b.type=="tool_result" then ($b.content|tostring)
     else ($b|tojson) end)' "$f"
done
