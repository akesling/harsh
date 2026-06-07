#!/usr/bin/env sh
# outline — one row per user prompt with a cheap summary of the response it got.
# Output TSV: SEQ<TAB>PROMPT<TAB>SUMMARY. jq-only; works under HARSH_MOCK.
set -u
[ "${1:-}" = --describe ] && { printf 'outline SESSION\tPrint a prompt-by-prompt outline: SEQ<TAB>PROMPT<TAB>SUMMARY.\n'; exit 0; }
_dir=$(sh "${HARSH_SELF}" path "$1")
set -- "${_dir}"/[0-9]*.json
[ -e "$1" ] || exit 0
# Tag each entry with its sequence (the filename prefix), then fold the blocks
# after each user/text prompt into that prompt's row.
for _f in "$@"; do
  _seq=$(basename "${_f}"); _seq=${_seq%%-*}
  jq -c --arg seq "${_seq}" '{seq:$seq, role:.role, block:.block}' "${_f}"
done | jq -rs '
  reduce .[] as $e ([];
    if ($e.role=="user" and $e.block.type=="text")
    then . + [{seq:$e.seq, prompt:$e.block.text, replies:[], tools:0}]
    elif (length==0) then .
    else
      .[-1] as $cur |
      (.[0:-1]) + [
        if ($e.role=="assistant" and $e.block.type=="text")
        then ($cur | .replies += [$e.block.text])
        elif ($e.role=="assistant" and $e.block.type=="tool_use")
        then ($cur | .tools += 1)
        else $cur end
      ]
    end)
  | .[]
  | (.prompt | gsub("[\n\t]";" ") | gsub("^ +| +$";"")) as $p
  | (if (.replies | length) > 0
      then (.replies[0] | gsub("[\n\t]";" ") | gsub("^ +| +$";""))
     elif .tools > 0
      then "ran " + (.tools|tostring) + " tool" + (if .tools==1 then "" else "s" end)
     else "(no response)" end) as $s
  | [.seq, ($p[0:100]), ($s[0:100])] | @tsv'
