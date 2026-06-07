#!/usr/bin/env sh
# usage — tally token usage from a session's response log: full-price input,
# cache reads (~0.1x) and writes (~1.25x), output, the cache-hit rate, and an
# approximate cost against the uncached equivalent. Lets you confirm prompt
# caching is working and see what it saves. Reads the per-session response log
# under HARSH_LOG_DIR; mock turns carry no usage and simply count as zero.
set -u
[ "${1:-}" = --describe ] && { printf 'usage SESSION\tToken usage + cache stats from the response log.\n'; exit 0; }
[ -n "${1:-}" ] || { printf 'usage: usage SESSION\n' >&2; exit 1; }
_dir=$(sh "${HARSH_SELF}" path "$1") || exit 1
_log="${HARSH_LOG_DIR}/$(basename "${_dir}").response.log"
[ -f "${_log}" ] || { printf 'no usage recorded yet (%s)\n' "${_log}"; exit 0; }

# Per-1M-token input/output dollar prices for the configured model (0 = unknown,
# in which case cost is reported as n/a).
case "${HARSH_MODEL}" in
  *opus*)   _in=5; _out=25 ;;
  *sonnet*) _in=3; _out=15 ;;
  *haiku*)  _in=1; _out=5  ;;
  *)        _in=0; _out=0  ;;
esac

jq -rs --argjson in "${_in}" --argjson out "${_out}" --arg model "${HARSH_MODEL}" '
  def z: . // 0;
  def r4: (. * 10000 | round) / 10000;
  [ .[] | .usage // empty ] as $u
  | ([ $u[].input_tokens | z ] | add // 0)            as $input
  | ([ $u[].cache_read_input_tokens | z ] | add // 0) as $cr
  | ([ $u[].cache_creation_input_tokens | z ] | add // 0) as $cw
  | ([ $u[].output_tokens | z ] | add // 0)           as $output
  | ($input + $cr + $cw)                              as $ptotal
  | ((($input * $in) + ($cr * $in * 0.1) + ($cw * $in * 1.25) + ($output * $out)) / 1000000) as $cost
  | ((($ptotal * $in) + ($output * $out)) / 1000000)  as $uncached
  | "calls: \($u | length)",
    "input (full price): \($input)",
    "cache reads (0.1x): \($cr)",
    "cache writes (1.25x): \($cw)",
    "output: \($output)",
    "cache hit rate: \(if $ptotal > 0 then (100 * $cr / $ptotal | round) else 0 end)%",
    (if $in > 0
     then "est. cost: $\($cost | r4)  (uncached: $\($uncached | r4)" +
          (if $uncached > 0 then ", saved \(100 * (1 - ($cost / $uncached)) | round)%)" else ")" end)
     else "est. cost: n/a (unknown pricing for \($model))" end)
' "${_log}"
