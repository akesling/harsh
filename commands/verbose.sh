#!/usr/bin/env sh
# verbose — expand one entry (#SEQ) in full: the tool's complete input/output.
# Accepts "7", "0007", or "#0007". Uses the shared renderer for the palette.
set -u
[ "${1:-}" = --describe ] && { printf 'verbose SESSION SEQ\tExpand one entry (#SEQ) in full — tool input/output.\n'; exit 0; }
# shellcheck source=/dev/null
. "${HARSH_LIB_DIR}/render.sh"
_dir=$(sh "${HARSH_SELF}" path "$1"); _want=$2
_want=${_want#\#}                       # tolerate a leading '#'
case "${_want}" in *[!0-9]*|'') printf 'usage: verbose SESSION #SEQ\n' >&2; exit 1 ;; esac
_want=$(printf '%04d' "${_want}")       # normalize to the zero-padded filename form
for _f in "${_dir}/${_want}"-*.json; do
  [ -e "${_f}" ] || { printf 'no such entry: #%s\n' "${_want}" >&2; exit 1; }
  _name=$(jq -r '.block.name // ""' "${_f}")
  _btype=$(jq -r '.block.type' "${_f}")
  printf '%s#%s %s%s%s\n' "${C_DIM}" "${_want}" "${_btype}" \
    "$( [ -n "${_name}" ] && printf ' · %s' "${_name}" )" "${C_RST}"
  case "${_btype}" in
    tool_use)    jq -r '.block.input | tojson' "${_f}" | gutter "${C_GUT}" "${C_DIM}" ;;
    tool_result) jq -r '.block.content | tostring' "${_f}" | gutter "${C_GUT}" "${C_RES}" ;;
    text)        jq -r '.block.text' "${_f}" | fmt_markdown | body ;;
    *)           jq -r '.block | tojson' "${_f}" | gutter "${C_GUT}" ;;
  esac
  exit 0
done
