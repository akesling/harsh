#!/usr/bin/env sh
# PreToolUse/10-permissions.sh — the tool permission gate.
#
# A declarative, layered policy decides allow / ask / deny for every tool call,
# and may rewrite the call (glob-captured arguments) before it runs. This is a
# POLICY gate, not a sandbox: matching `bash` commands governs an honest model,
# not an adversarial one (`sh -c`, eval, base64 defeat substring rules). For
# real containment pair it with a rewriter that wraps execution (see
# PreToolUse/20-sandbox.sh) or a sandboxing tools/bash.sh.
#
# Layers (first match wins): session ($session_dir/permissions.json) > project
# (.harsh/permissions.json) > user (~/.config/harsh/permissions.json) > built-in
# default. Dormant unless you opt in — set HARSH_PERMISSIONS_MODE=allow|ask|deny
# or drop a policy file. See hooks/lib/permissions.sh.
set -u
_self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=/dev/null
. "${_self_dir}/../lib/permissions.sh"

_payload=$(cat)
_dir=$(printf '%s' "${_payload}" | jq -r '.session_dir // ""')
_tool=$(printf '%s' "${_payload}" | jq -r '.tool_name // ""')

perm_enabled "${_dir}" || exit 0   # dormant until opted in

_pol=$(perm_merged_policy "${_dir}")
_verdict=$(perm_evaluate "${_pol}" "${_payload}")
_decision=$(printf '%s' "${_verdict}" | jq -r '.decision')
_reason=$(printf '%s' "${_verdict}" | jq -r '.reason // ""')
_rule=$(printf '%s' "${_verdict}" | jq -r '.rule')
_rewrite=$(printf '%s' "${_verdict}" | jq -c '.rewrite')
_caps=$(printf '%s' "${_verdict}" | jq -c '.caps')

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

# Apply a rule's rewrite (if any) to tool_input and emit it on the rewrite
# channel, so an allowed-with-rewrite call runs transformed.
_emit_rule_rewrite() {
  { [ "${_rewrite}" != null ] && [ -n "${HARSH_HOOK_REWRITE_OUT:-}" ]; } || return 0
  _ti=$(printf '%s' "${_payload}" | jq -c '.tool_input')
  _newti=$(perm_apply_rewrite "${_ti}" "${_rewrite}" "${_caps}")
  printf '%s' "${_payload}" | jq -c --argjson ti "${_newti}" '.tool_input = $ti' \
    > "${HARSH_HOOK_REWRITE_OUT}"
}

# Emit a manual one-off rewrite of the primary command field.
_emit_manual_rewrite() {
  [ -n "${HARSH_HOOK_REWRITE_OUT:-}" ] || return 0
  printf '%s' "${_payload}" | jq -c --arg c "$1" '.tool_input.command = $c' \
    > "${HARSH_HOOK_REWRITE_OUT}"
}

case "${_decision}" in
  allow) _emit_rule_rewrite; _audit allow allow; exit 0 ;;
  deny)
    _audit policy deny
    [ -n "${_reason}" ] && printf '%s\n' "${_reason}" \
      || printf 'refused by policy (rule: %s). Ask the user to run it, or choose a permitted action.\n' "${_rule}"
    exit 2 ;;
  ask)
    # Resolve "ask" interactively. Prompt seam: read from $HARSH_PERMISSIONS_TTY
    # if set (tests drive it through a file), else /dev/tty. No TTY at all ->
    # the policy's noninteractive verb (ships as deny: fail closed).
    _tty=${HARSH_PERMISSIONS_TTY:-/dev/tty}
    if [ ! -r "${_tty}" ] || { [ -z "${HARSH_PERMISSIONS_TTY:-}" ] && [ ! -c /dev/tty ]; }; then
      _ni=$(printf '%s' "${_pol}" | jq -r '.noninteractive // "deny"')
      if [ "${_ni}" = allow ]; then
        _emit_rule_rewrite; _audit noninteractive allow; exit 0
      fi
      _audit noninteractive deny
      printf 'refused: %s needs approval but no terminal is available (non-interactive policy: deny). Re-run interactively or pre-authorize in a permissions policy.\n' "${_tool}"
      exit 2
    fi
    # Hold the prompt source open on fd 3 so successive reads (the menu choice,
    # then an edited command) advance through it instead of re-reading line 1.
    exec 3< "${_tty}" || { _audit noninteractive deny; printf 'refused: cannot open terminal for approval.\n'; exit 2; }
    { printf '\n  permission: %s %s\n  [y]es once · [e]dit · [s]ession · [p]roject · [f]orever · [n]o : ' \
        "${_tool}" "${_arg}" > /dev/tty; } 2>/dev/null || true
    IFS= read -r _ans <&3 || _ans=n
    case "${_ans}" in
      y|Y|yes)      _emit_rule_rewrite; _audit ask-yes allow; exit 0 ;;
      e|E|edit)
        # Manual one-off rewrite: read the replacement command from the same seam.
        { printf '  rewrite command to: ' > /dev/tty; } 2>/dev/null || true
        IFS= read -r _newcmd <&3 || _newcmd=""
        if [ -n "${_newcmd}" ]; then
          _emit_manual_rewrite "${_newcmd}"; _audit ask-edit allow; exit 0
        fi
        _audit ask-edit-empty deny
        printf 'refused: no replacement command given.\n'; exit 2 ;;
      s|S|session)  perm_add_rule session "${_dir}" "$(jq -nc --arg t "${_tool}" '{tool:$t,decision:"allow"}')"; _emit_rule_rewrite; _audit ask-session allow; exit 0 ;;
      p|P|project)  perm_add_rule project "${_dir}" "$(jq -nc --arg t "${_tool}" '{tool:$t,decision:"allow"}')"; _emit_rule_rewrite; _audit ask-project allow; exit 0 ;;
      f|F|forever)  perm_add_rule user    "${_dir}" "$(jq -nc --arg t "${_tool}" '{tool:$t,decision:"allow"}')"; _emit_rule_rewrite; _audit ask-forever allow; exit 0 ;;
      *)
        _audit ask-no deny
        printf 'refused: the user declined this %s call. Do not retry it; consider an alternative or ask them what to do.\n' "${_tool}"
        exit 2 ;;
    esac ;;
  *)
    _audit error deny
    printf 'refused: permission policy produced an unknown decision (%s) for rule %s.\n' "${_decision}" "${_rule}"
    exit 2 ;;
esac
