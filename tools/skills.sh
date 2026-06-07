#!/usr/bin/env sh
# skills tool — load a skill's instructions so the agent can follow them.
# Skills live under $HARSH_SKILLS_DIR as NAME/SKILL.md or NAME.md.
set -u
if [ "${1:-}" = --schema ]; then
  # Enumerate available skills into the description so the model can discover them.
  _d=${HARSH_SKILLS_DIR:-./skills}
  _list=""
  if [ -d "${_d}" ]; then
    _base=$(basename "${_d}")
    for _s in "${_d}"/*/SKILL.md "${_d}"/*.md; do
      [ -e "${_s}" ] || continue
      _name=$(basename "$(dirname "${_s}")")
      [ "${_name}" = "${_base}" ] && _name=$(basename "${_s}" .md)
      _list="${_list} ${_name}"
    done
  fi
  jq -nc --arg avail "${_list}" '{
    name:"skills",
    description:("Invoke a named skill to load its expert instructions for a task. Available skills:" + $avail),
    input_schema:{type:"object",
      properties:{
        name:{type:"string",description:"The skill name to load."},
        args:{type:"string",description:"Optional arguments / context for the skill."}},
      required:["name"]}}'
  exit 0
fi
_input=$(cat)
_name=$(printf '%s' "${_input}" | jq -r '.name // empty')
[ -n "${_name}" ] || { echo "error: missing 'name'"; exit 1; }
_d=${HARSH_SKILLS_DIR:-./skills}
for _cand in "${_d}/${_name}/SKILL.md" "${_d}/${_name}.md" "${_d}/${_name}/skill.md"; do
  if [ -f "${_cand}" ]; then
    cat "${_cand}"
    exit 0
  fi
done
echo "error: skill not found: ${_name} (looked in ${_d})"
exit 1
