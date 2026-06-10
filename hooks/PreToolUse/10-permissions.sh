#!/usr/bin/env sh
# PreToolUse/10-permissions.sh — the tool permission gate.
#
# A declarative, layered policy decides allow / ask / deny for every tool call.
# This is a POLICY gate, not a sandbox: matching `bash` commands governs an
# honest-but-imprudent model, not an adversarial one (`sh -c`, eval, base64 all
# defeat substring rules). For real containment pair it with a rewriter that
# wraps execution (see PreToolUse/20-sandbox.sh) or a sandboxing tools/bash.sh.
#
# Layers (first match wins): session grants ($session_dir/permissions.json) >
# project (.harsh/permissions.json) > user (~/.config/harsh/permissions.json) >
# built-in default. The gate is dormant unless you opt in — set
# HARSH_PERMISSIONS_MODE=allow|ask|deny or drop a policy file — so installing
# the hook changes nothing until configured. See hooks/lib/permissions.sh.
set -u
_self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=/dev/null
. "${_self_dir}/../lib/permissions.sh"

_payload=$(cat)
_dir=$(printf '%s' "${_payload}" | jq -r '.session_dir // ""')
_tool=$(printf '%s' "${_payload}" | jq -r '.tool_name // ""')

# Dormant until opted in.
perm_enabled "${_dir}" || exit 0

_pol=$(perm_merged_policy "${_dir}")
_verdict=$(perm_evaluate "${_pol}" "${_payload}")
_decision=$(printf '%s' "${_verdict}" | jq -r '.decision')
_reason=$(printf '%s' "${_verdict}" | jq -r '.reason // ""')
_rule=$(printf '%s' "${_verdict}" | jq -r '.rule')

# The most salient argument, for prompts and the audit trail.
_arg=$(printf '%s' "${_payload}" | jq -r '
  .tool_input | (.command // .path // .pattern // .name // (.|tojson)) | tostring
  | gsub("[\n\t]"; " ") | .[0:80]')

# audit MODE DECISION — append one comma-free line to the session audit log.
_audit() {
  [ -n "${_dir}" ] || return 0
  _ats=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _aarg=$(printf '%s' "${_arg}" | tr ',\n\t' '   ')
  printf '%s,%s,%s,%s,%s,%s\n' "${_ats}" "${_tool}" "${_aarg}" "$2" "${_rule}" "$1" \
    >> "${_dir}/permissions.log"
}

# Grant for the rest of this session by appending a rule to the session policy.
_grant() {
  [ -n "${_dir}" ] || return 0
  _gf="${_dir}/permissions.json"
  [ -f "${_gf}" ] || printf '{"rules":[]}' > "${_gf}"
  _tmp="${_dir}/.permissions.tmp.$$"
  jq -c --arg t "${_tool}" --arg d "$1" \
     '.rules = ([{tool:$t, decision:$d}] + (.rules // []))' "${_gf}" > "${_tmp}" \
    && mv "${_tmp}" "${_gf}"
}

case "${_decision}" in
  allow) _audit allow allow; exit 0 ;;
  deny)
    _audit policy deny
    [ -n "${_reason}" ] && printf '%s\n' "${_reason}" \
      || printf 'refused by policy (rule: %s). Ask the user to run it, or choose a permitted action.\n' "${_rule}"
    exit 2 ;;
  ask)
    # Resolve "ask" interactively. The prompt seam: read from $HARSH_PERMISSIONS_TTY
    # if set (tests drive it through a file), else /dev/tty. No TTY at all ->
    # fall back to the policy's noninteractive verb (ships as deny: fail closed).
    _tty=${HARSH_PERMISSIONS_TTY:-/dev/tty}
    if [ ! -r "${_tty}" ] || { [ -z "${HARSH_PERMISSIONS_TTY:-}" ] && [ ! -c /dev/tty ]; }; then
      _ni=$(printf '%s' "${_pol}" | jq -r '.noninteractive // "deny"')
      if [ "${_ni}" = allow ]; then
        _audit noninteractive allow; exit 0
      fi
      _audit noninteractive deny
      printf 'refused: %s needs approval but no terminal is available (non-interactive policy: deny). Re-run interactively or pre-authorize in a permissions policy.\n' "${_tool}"
      exit 2
    fi
    # Prompt on the terminal (block-redirect so a missing /dev/tty stays silent
    # — under the test seam the answer still comes from $HARSH_PERMISSIONS_TTY).
    { printf '\n  permission: %s %s\n  [y]es once · [a]lways (this session) · [n]o : ' \
        "${_tool}" "${_arg}" > /dev/tty; } 2>/dev/null || true
    IFS= read -r _ans < "${_tty}" || _ans=n
    case "${_ans}" in
      y|Y|yes)      _audit ask-yes allow; exit 0 ;;
      a|A|always)   _grant allow; _audit ask-always allow; exit 0 ;;
      *)
        _audit ask-no deny
        printf 'refused: the user declined this %s call. Do not retry it; consider an alternative or ask them what to do.\n' "${_tool}"
        exit 2 ;;
    esac ;;
  *)
    # Unknown verb in a policy file — fail closed and say why (to the log).
    _audit error deny
    printf 'refused: permission policy produced an unknown decision (%s) for rule %s.\n' "${_decision}" "${_rule}"
    exit 2 ;;
esac
