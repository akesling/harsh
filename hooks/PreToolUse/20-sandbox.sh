#!/usr/bin/env sh
# PreToolUse/20-sandbox.sh — EXAMPLE rewriter: wrap the bash tool's command so
# it runs under an OS sandbox, demonstrating the PreToolUse input-rewrite
# channel and the policy/enforcement split.
#
# The permission gate (10-permissions.sh) is the policy brain — it authorizes
# the model's *intent*. This hook is the enforcement wall: it runs AFTER the
# gate (filename order 10 < 20), so a denied call never reaches it, and an
# allowed call is rewritten to execute confined. Rewriting (not refusing) is
# what makes containment composable: the model still runs its command, it just
# can't escape the box.
#
# Opt-in (HARSH_SANDBOX=1) and best-effort: with no sandbox tool installed it
# leaves the command untouched (and says so to hooks.log) rather than implying
# a safety it isn't providing. A STARTING POINT — the profiles are deliberately
# loose; tighten them for your threat model, or move enforcement into a
# sandboxing tools/bash.sh for a wall a hook-ordering mistake can't bypass.
set -u
[ "${HARSH_SANDBOX:-0}" = 1 ] || exit 0
[ -n "${HARSH_HOOK_REWRITE_OUT:-}" ] || exit 0   # engine too old to accept rewrites

_payload=$(cat)
[ "$(printf '%s' "${_payload}" | jq -r '.tool_name // ""')" = bash ] || exit 0
_cmd=$(printf '%s' "${_payload}" | jq -r '.tool_input.command // ""')
[ -n "${_cmd}" ] || exit 0

# Already wrapped? (idempotent if another layer got here first.)
case "${_cmd}" in *"sandbox-exec "*|*"bwrap "*) exit 0 ;; esac

# Single-quote a string for safe embedding as one shell word.
_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

_inner=$(_sq "${_cmd}")
if command -v sandbox-exec >/dev/null 2>&1; then
  # macOS Seatbelt: reads anywhere; writes confined to the cwd subtree and the
  # usual scratch dirs; everything else denied. (Loose by design — tighten me.)
  _prof='(version 1)(allow default)(deny file-write*)(allow file-write* (subpath (param "WD")) (subpath "/tmp") (subpath "/private/tmp") (subpath "/dev"))'
  _wrapped="sandbox-exec -p $(_sq "${_prof}") -D WD=\"\$PWD\" sh -c ${_inner}"
elif command -v bwrap >/dev/null 2>&1; then
  # bubblewrap: read-only root, writable cwd + /tmp. Add --unshare-net to cut
  # network. Loose by design.
  _wrapped="bwrap --ro-bind / / --bind \"\$PWD\" \"\$PWD\" --bind /tmp /tmp --dev /dev --proc /proc --chdir \"\$PWD\" sh -c ${_inner}"
else
  printf '[sandbox] no sandbox-exec/bwrap found — running unconfined\n' >&2
  exit 0
fi

printf '%s' "${_payload}" | jq -c --arg c "${_wrapped}" '.tool_input.command = $c' \
  > "${HARSH_HOOK_REWRITE_OUT}"
printf '[sandbox] wrapped the command for confined execution\n'
exit 0
