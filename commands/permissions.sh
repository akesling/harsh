#!/usr/bin/env sh
# permissions — inspect and manage the tool permission policy for a session.
#
#   permissions SESSION                       show effective merged policy + layers
#   permissions SESSION test TOOL [ARG]        dry-run a decision
#   permissions SESSION allow TOOL [--scope S] add an allow grant (default scope: session)
#   permissions SESSION deny  TOOL [--scope S] add a deny grant
#   permissions SESSION rewrite TOOL GLOB TMPL [--scope S]
#                                              add an allow+rewrite rule: when the
#                                              command matches GLOB (shell *), run
#                                              TMPL with $1..$N = the * captures
#   permissions SESSION clear [--scope S]      drop a scope's grants (default session)
#   permissions SESSION log                    print the session's decision audit log
#
# Scope S is session (default) | project (.harsh/) | user/forever (~/.config/).
# Reads the same hooks/lib/permissions.sh the gate uses, so what this prints is
# exactly what the gate enforces.
set -u
[ "${1:-}" = --describe ] && { printf 'permissions SESSION [test|allow|deny|rewrite|clear|log] [ARGS] [--scope S]\tInspect/manage the tool permission policy.\n'; exit 0; }
[ -n "${1:-}" ] || { printf 'usage: permissions SESSION [test|allow|deny|rewrite|clear|log] [ARGS]\n' >&2; exit 1; }

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

_sub=${1:-show}; [ $# -gt 0 ] && shift

# Pull an optional `--scope S` out of the args (preserving the rest, spaces and
# all) via an N-rotation: take from the front, re-append to the back, exactly
# once per original arg; --scope and its value drop out.
_scope=session
_argc=$#
while [ "${_argc}" -gt 0 ]; do
  _a=$1; shift; _argc=$((_argc - 1))
  if [ "${_a}" = --scope ]; then _scope=${1:-session}; shift 2>/dev/null && _argc=$((_argc - 1)); continue; fi
  set -- "$@" "${_a}"
done
case "${_scope}" in session|project|user|forever) : ;; *) printf 'permissions: bad scope: %s (session|project|user)\n' "${_scope}" >&2; exit 1 ;; esac

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
    [ -n "${1:-}" ] || { printf 'usage: permissions SESSION %s TOOL [--scope S]\n' "${_sub}" >&2; exit 1; }
    perm_add_rule "${_scope}" "${_dir}" "$(jq -nc --arg t "$1" --arg d "${_sub}" '{tool:$t, decision:$d}')" \
      || { printf 'permissions: failed to write %s policy\n' "${_scope}" >&2; exit 1; }
    printf 'added %s %s for %s\n' "${_scope}" "${_sub}" "$1"
    ;;
  rewrite)
    { [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ]; } \
      || { printf 'usage: permissions SESSION rewrite TOOL GLOB TEMPLATE [--scope S]\n' >&2; exit 1; }
    # An allow rule that also rewrites: match the command against GLOB (shell *,
    # each capturing $1..) and run TEMPLATE with those captures substituted.
    _r=$(jq -nc --arg t "$1" --arg g "$2" --arg m "$3" \
      '{tool:$t, match:{command:$g}, decision:"allow", rewrite:{command:$m}}')
    perm_add_rule "${_scope}" "${_dir}" "${_r}" \
      || { printf 'permissions: failed to write %s policy\n' "${_scope}" >&2; exit 1; }
    printf 'added %s rewrite for %s: %s -> %s\n' "${_scope}" "$1" "$2" "$3"
    ;;
  clear)
    _cf=$(perm_scope_file "${_scope}" "${_dir}")
    [ -f "${_cf}" ] && rm -f "${_cf}"
    printf 'cleared %s grants\n' "${_scope}"
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
