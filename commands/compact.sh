#!/usr/bin/env sh
# compact — summarize a conversation, archive its history, continue from the
# summary.
#
# Deliberately a drop-in command, not an engine primitive: the summarization
# *policy* (what the summary asks for, what model sees it, how) is replaceable
# by editing this file — or removable to opt out of compaction entirely. The
# engine contributes only the invariant-bearing pieces it owns:
#   archive SESSION     move the answered history into archive/<ts>/,
#                       preserving a pending prompt (prints the archive dir)
#   send -m META …      record the summary as a synthetic entry with metadata
#   run-hooks EVENT …   fire PreCompact through the engine's hook runner
# The run loop auto-invokes this command when the context passes
# HARSH_COMPACT_AT tokens; it is equally callable as `harsh.sh compact` or
# /compact in the REPL.
set -u
[ "${1:-}" = --describe ] && { printf 'compact SESSION\tSummarize + archive the conversation; restart from the summary.\n'; exit 0; }
[ -n "${1:-}" ] || { printf 'usage: compact SESSION\n' >&2; exit 1; }
_sess=$1
_dir=$(sh "${HARSH_SELF}" path "${_sess}")
[ -d "${_dir}" ] || { printf 'compact: no such session: %s\n' "${_dir}" >&2; exit 1; }
set -- "${_dir}"/[0-9]*.json
[ -e "$1" ] || { printf 'nothing to compact in %s\n' "${_dir}"; exit 0; }

# Anything to archive? The last entry that is NOT plain user text marks the
# end of the answered conversation; without one there are only unanswered
# prompts — don't pay for a summary of nothing.
_cut=""
for _f in "${_dir}"/[0-9]*.json; do
  [ "$(jq -r '.role + "/" + .block.type' "${_f}")" = "user/text" ] || _cut=${_f}
done
[ -n "${_cut}" ] || { printf 'nothing to compact (no completed turns)\n'; exit 0; }

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

# Summarize in a scratch sub-session, agent.sh-style: the rendered transcript
# rides in one user message. Tools and hooks point at an empty dir (a pure
# prose turn; no SessionStart noise), and auto-compaction is off so the
# summarizer can never recurse into itself.
_transcript=$(sh "${HARSH_SELF}" show "${_sess}")
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

# Archive the answered history (a pending prompt survives in place), then
# record the summary as a synthetic, metadata-tagged entry.
_arch=$(sh "${HARSH_SELF}" archive "${_sess}")
[ -n "${_arch}" ] || { printf 'compact: nothing was archived\n' >&2; exit 1; }
sh "${HARSH_SELF}" -q send -m '{"context":"compact"}' "${_sess}" \
  "Summary of the conversation so far (earlier turns were compacted away; their full record is archived):

${_sum}" || exit 1
printf '[harsh] compacted into a summary (archive: %s · summarizer: %s)\n' \
  "${_arch}" "$(basename "${_scratch}")"
