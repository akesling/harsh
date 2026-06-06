#!/usr/bin/env sh
# skills tool — load a skill's instructions so the agent can follow them.
# Skills live under $HARSH_SKILLS_DIR as NAME/SKILL.md or NAME.md.
set -u
if [ "${1:-}" = --schema ]; then
  # Enumerate available skills into the description so the model can discover them.
  d=${HARSH_SKILLS_DIR:-./skills}
  list=""
  if [ -d "$d" ]; then
    base=$(basename "$d")
    for s in "$d"/*/SKILL.md "$d"/*.md; do
      [ -e "$s" ] || continue
      name=$(basename "$(dirname "$s")")
      [ "$name" = "$base" ] && name=$(basename "$s" .md)
      list="$list $name"
    done
  fi
  jq -nc --arg avail "$list" '{
    name:"skills",
    description:("Invoke a named skill to load its expert instructions for a task. Available skills:" + $avail),
    input_schema:{type:"object",
      properties:{
        name:{type:"string",description:"The skill name to load."},
        args:{type:"string",description:"Optional arguments / context for the skill."}},
      required:["name"]}}'
  exit 0
fi
input=$(cat)
name=$(printf '%s' "$input" | jq -r '.name // empty')
[ -n "$name" ] || { echo "error: missing 'name'"; exit 1; }
d=${HARSH_SKILLS_DIR:-./skills}
for cand in "$d/$name/SKILL.md" "$d/$name.md" "$d/$name/skill.md"; do
  if [ -f "$cand" ]; then
    cat "$cand"
    exit 0
  fi
done
echo "error: skill not found: $name (looked in $d)"
exit 1
