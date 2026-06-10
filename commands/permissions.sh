#!/usr/bin/env sh
# permissions — inspect and manage the tool permission policy for a session.
#
#   permissions SESSION              show the effective merged policy + layers
#   permissions SESSION test TOOL [ARG]   dry-run a decision
#   permissions SESSION allow TOOL   add a session grant (always-allow TOOL)
#   permissions SESSION deny  TOOL   add a session deny
#   permissions SESSION clear        drop all session grants
#   permissions SESSION log          print the session's decision audit log
#
# Reads the same hooks/lib/permissions.sh the gate uses, so what this prints is
# exactly what the gate enforces. Session grants live in the session dir, so
# they travel with the conversation and the `permissions log` audit composes
# with the rest of the session record.
set -u
[ "${1:-}" = --describe ] && { printf 'permissions SESSION [test|allow|deny|clear|log] [ARGS]\tInspect/manage the tool permission policy.\n'; exit 0; }
[ -n "${1:-}" ] || { printf 'usage: permissions SESSION [test|allow|deny|clear|log] [ARGS]\n' >&2; exit 1; }

_dir=$(sh "${HARSH_SELF}" path "$1"); shift
[ -d "${_dir}" ] || { printf 'permissions: no such session: %s\n' "${_dir}" >&2; exit 1; }

# Locate hooks/lib/permissions.sh: prefer the configured hooks dir, fall back to
# the one beside harsh.sh.
for _cand in "${HARSH_HOOKS_DIR:-}/lib/permissions.sh" "${SELF_DIR:-}/hooks/lib/permissions.sh"; do
  [ -f "${_cand}" ] && { _lib=${_cand}; break; }
done
[ -n "${_lib:-}" ] || { printf 'permissions: cannot find hooks/lib/permissions.sh\n' >&2; exit 1; }
# shellcheck source=/dev/null
. "${_lib}"

_gf="${_dir}/permissions.json"
_sub=${1:-show}; [ $# -gt 0 ] && shift

case "${_sub}" in
  show)
    printf 'mode: %s\n' "${HARSH_PERMISSIONS_MODE:-<unset> (policy default)}"
    if perm_enabled "${_dir}"; then printf 'gate: ENABLED\n'; else printf 'gate: dormant (set HARSH_PERMISSIONS_MODE or add a policy file)\n'; fi
    printf 'layers (highest first):\n'
    _any=0
    for _p in $(perm_policy_paths "${_dir}"); do printf '  %s\n' "${_p}"; _any=1; done
    [ "${_any}" = 0 ] && printf '  (none — built-in default only)\n'
    printf 'effective policy:\n'
    perm_merged_policy "${_dir}" | jq . | sed 's/^/  /'
    ;;
  test)
    [ -n "${1:-}" ] || { printf 'usage: permissions SESSION test TOOL [ARG]\n' >&2; exit 1; }
    _tool=$1; _arg=${2:-}
    # Build a payload; route ARG to the field the tool actually uses.
    _payload=$(jq -nc --arg s "${_dir}" --arg t "${_tool}" --arg a "${_arg}" \
      '{session_dir:$s, tool_name:$t,
        tool_input: ( if $a=="" then {} else {command:$a,path:$a,pattern:$a,name:$a} end )}')
    perm_evaluate "$(perm_merged_policy "${_dir}")" "${_payload}" | jq .
    ;;
  allow|deny)
    [ -n "${1:-}" ] || { printf 'usage: permissions SESSION %s TOOL\n' "${_sub}" >&2; exit 1; }
    [ -f "${_gf}" ] || printf '{"rules":[]}' > "${_gf}"
    _tmp="${_dir}/.permissions.tmp.$$"
    jq -c --arg t "$1" --arg d "${_sub}" '.rules = ([{tool:$t, decision:$d}] + (.rules // []))' \
      "${_gf}" > "${_tmp}" && mv "${_tmp}" "${_gf}"
    printf 'added session %s for %s\n' "${_sub}" "$1"
    ;;
  clear)
    [ -f "${_gf}" ] && rm -f "${_gf}"
    printf 'cleared session grants\n'
    ;;
  log)
    if [ -f "${_dir}/permissions.log" ]; then
      printf 'timestamp,tool,arg,decision,rule,mode\n'
      cat "${_dir}/permissions.log"
    else
      printf '(no decisions logged yet)\n'
    fi
    ;;
  *) printf 'permissions: unknown subcommand: %s\n' "${_sub}" >&2; exit 1 ;;
esac
