#!/usr/bin/env sh
# compact — summarize the live conversation, then rewrite the manifest so the
# next request sees [summary, pending prompt] instead of the whole history.
#
# Deliberately a drop-in command, not an engine primitive: compaction is pure
# *policy* over two engine mechanisms —
#   remanifest SESSION   rewrite the live view from a spec (new CSV generation
#                        + composed entries), retiring the old view to
#                        manifest-<ts>.csv; entry files never move
#   run-hooks EVENT …    fire PreCompact through the engine's hook runner
# Nothing is deleted: every entry file stays in the session directory and
# every manifest generation is preserved, so `show` replays the session's full
# evolution (including compactions) and any rewrite can be undone by
# rewriting again. Edit this file to change the summarization scheme; delete
# it to opt out (the run loop's auto-trigger degrades to a warning).
set -u
[ "${1:-}" = --describe ] && { printf 'compact SESSION\tSummarize the conversation; rewrite the live view to [summary, pending prompt].\n'; exit 0; }
[ -n "${1:-}" ] || { printf 'usage: compact SESSION\n' >&2; exit 1; }
_sess=$1
_dir=$(sh "${HARSH_SELF}" path "${_sess}")
[ -d "${_dir}" ] || { printf 'compact: no such session: %s\n' "${_dir}" >&2; exit 1; }
[ -s "${_dir}/manifest.csv" ] || { printf 'nothing to compact in %s\n' "${_dir}"; exit 0; }

# Walk the live manifest: collect the trailing run of plain user-text rows
# (a prompt the model has not seen yet — it must survive verbatim; a summary
# can only stand in for content the model has already processed), and note
# whether anything before it exists to summarize at all.
_pend=""; _answered=0
# shellcheck disable=SC2034  # named for clarity; only role/type/file are used
while IFS=, read -r _seq _role _type _name _file _ts _status; do
  [ -n "${_file}" ] || continue
  if [ "${_role}/${_type}" = "user/text" ]; then
    _pend="${_pend}${_file}
"
  else
    _pend=""; _answered=1
  fi
done < "${_dir}/manifest.csv"
[ "${_answered}" = 1 ] || { printf 'nothing to compact (no completed turns)\n'; exit 0; }

# PreCompact — a hook may block compaction (exit 2) or emit extra guidance
# that is appended to the summarizer instruction.
_hp=$(jq -nc --arg e PreCompact --arg s "${_dir}" '{event:$e,session_dir:$s}')
if ! _hint=$(sh "${HARSH_SELF}" run-hooks PreCompact "${_hp}"); then
  printf '[blocked] compaction blocked by hook: %s\n' "${_hint}" >&2
  exit 1
fi

_instr='Below is the transcript of a conversation. Summarize it completely. The summary will REPLACE the conversation as the assistant'\''s only context, so be comprehensive: the user'\''s goals and constraints, every decision made and why, the current state of the work, exact file paths/commands/facts that matter, and what remains to be done. Reply with the summary only.'
[ -n "${_hint}" ] && _instr="${_instr}
${_hint}"

# Summarize in a scratch sub-session, agent.sh-style: the live transcript
# (assemble — the view the model would have seen, not the full replay log)
# rides in one user message. Tools and hooks point at an empty dir (a pure
# prose turn; no SessionStart noise), and auto-compaction is off so the
# summarizer can never recurse into itself.
_transcript=$(sh "${HARSH_SELF}" assemble "${_sess}" | jq -r '
  .[] | "## " + .role + "\n"
      + (.content | map(
           if .type == "text" then .text
           elif .type == "tool_use" then "[tool_use " + (.name // "") + ": " + (.input | tojson) + "]"
           elif .type == "tool_result" then "[tool_result: " + (.content | tostring) + "]"
           else "[" + .type + "]" end) | join("\n")) + "\n"')
_empty=$(mktemp -d 2>/dev/null || echo "/tmp/harsh_compact.$$"); mkdir -p "${_empty}"
_scratch=$(HARSH_HOOKS_DIR="${_empty}" sh "${HARSH_SELF}" new \
  "compact-$(basename "${_dir}")-$(date -u +%Y%m%dT%H%M%SZ)")
if ! HARSH_HOOKS_DIR="${_empty}" HARSH_TOOLS_DIR="${_empty}" HARSH_COMPACT_AT=0 \
     sh "${HARSH_SELF}" -q ask "${_scratch}" "${_instr}

${_transcript}" >/dev/null; then
  rm -rf "${_empty}"
  printf 'compact: summarizer run failed (see %s)\n' "${_scratch}" >&2
  exit 1
fi
rm -rf "${_empty}"
_sum=$(sh "${HARSH_SELF}" final "${_scratch}")
[ -n "${_sum}" ] || { printf 'compact: empty summary (see %s)\n' "${_scratch}" >&2; exit 1; }

# The new view: the summary first, then the pending prompt verbatim. One spec
# in, one retired generation out; the engine derives the rows.
_gen=$(printf '%s' "${_pend}" | jq -R 'select(length > 0)' | jq -s \
  --arg sum "Summary of the conversation so far (earlier turns were compacted away; the full record remains in this session's log and prior manifest generations):

${_sum}" '
  { manifest: (["@summary"] + .),
    entries: { summary: { role: "user",
                          block: {type:"text", text:$sum},
                          meta:  {context:"compact"} } } }' \
  | sh "${HARSH_SELF}" remanifest "${_sess}") || exit 1
printf '[harsh] compacted: live view rewritten (retired: %s · summarizer: %s)\n' \
  "$(basename "${_gen}")" "$(basename "${_scratch}")"
