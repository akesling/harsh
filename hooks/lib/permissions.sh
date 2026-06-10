#!/usr/bin/env sh
# hooks/lib/permissions.sh — shared permission-policy helpers, sourced by the
# PreToolUse permission gate and by commands/permissions.sh so the two never
# disagree about what the effective policy is. Pure jq + POSIX sh.
#
# A policy is JSON:
#   { "default": "ask",            # verb for an unmatched tool: allow|ask|deny
#     "noninteractive": "deny",    # what an "ask" becomes with no TTY
#     "rules": [ { "tool": "read|grep",            # regex over the tool name
#                  "match": {"command": "git *"},  # field -> shell glob (all must match)
#                  "decision": "allow",            # allow|ask|deny
#                  "reason": "…" } ] }             # shown to the model on deny
# First matching rule wins. Policies layer session > project > user > built-in:
# rules concatenate in that order, scalars take the highest layer that sets one.

# Built-in default policy: read-only tools flow; obviously destructive shell
# commands are refused with a model-readable reason (this subsumes the old
# PreToolUse/bash/10-guard.sh example); everything else asks.
perm_builtin_policy() {
  cat <<'JSON'
{
  "default": "ask",
  "noninteractive": "deny",
  "rules": [
    {"tool": "read|grep|ls|skills", "decision": "allow"},
    {"tool": "bash", "match": {"command": "*rm -rf /*"}, "decision": "deny",
     "reason": "refused: 'rm -rf /' is destructive. Ask the user to run it themselves, or target a specific, narrower path."},
    {"tool": "bash", "match": {"command": "*rm -fr /*"}, "decision": "deny",
     "reason": "refused: destructive recursive force-remove rooted at /."},
    {"tool": "bash", "match": {"command": "*mkfs*"}, "decision": "deny",
     "reason": "refused: filesystem-format command."},
    {"tool": "bash", "match": {"command": "*dd if=*of=/dev/*"}, "decision": "deny",
     "reason": "refused: raw write to a device node."},
    {"tool": "bash", "match": {"command": ":(){ :|:&};:*"}, "decision": "deny",
     "reason": "refused: fork bomb."}
  ]
}
JSON
}

# perm_policy_paths SESSION_DIR — print the layer files to consult, lowest
# priority last (user, then project, then session — the merge reverses to make
# session win). Only existing files are printed.
perm_policy_paths() {
  _pp_sess=$1
  _pp_user="${XDG_CONFIG_HOME:-${HOME}/.config}/harsh/permissions.json"
  _pp_proj=".harsh/permissions.json"
  for _pp in "${_pp_sess}/permissions.json" "${_pp_proj}" "${_pp_user}"; do
    [ -f "${_pp}" ] && printf '%s\n' "${_pp}"
  done
}

# perm_merged_policy SESSION_DIR — print the effective merged policy (built-in
# under any files found, session layer on top). HARSH_PERMISSIONS_MODE, if set
# to allow|ask|deny, overrides the merged `default`.
perm_merged_policy() {
  _pm_dir=$1
  # Concatenate built-in (lowest) .. session (highest). jq reduces them so
  # later files' rules take precedence (prepended) and later scalars win.
  { perm_builtin_policy
    # reverse perm_policy_paths order so session ends up last/highest
    _pm_files=$(perm_policy_paths "${_pm_dir}")
    _pm_rev=""
    for _f in ${_pm_files}; do _pm_rev="${_f}
${_pm_rev}"; done
    for _f in ${_pm_rev}; do cat "${_f}"; done
  } | jq -s --arg mode "${HARSH_PERMISSIONS_MODE:-}" '
      reduce .[] as $p ({default:"ask", noninteractive:"deny", rules:[]};
        { default: ($p.default // .default),
          noninteractive: ($p.noninteractive // .noninteractive),
          rules: (($p.rules // []) + .rules) })
      | if ($mode|length) > 0 then .default = $mode else . end'
}

# perm_evaluate POLICY_JSON PAYLOAD_JSON — print {decision, reason, rule}.
perm_evaluate() {
  printf '%s' "$2" | jq -c --argjson pol "$1" '
    def globre: ( gsub("(?<c>[.+?^${}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") );
    def gmatch($pat): test("^" + ($pat | globre) + "$");
    .tool_name as $tn | (.tool_input // {}) as $ti
    | ( ($pol.rules // [])
        | map( . as $r
               | select( ($tn | test("^(" + $r.tool + ")$"))
                         and ( ($r.match // {}) | to_entries
                               | all( . as $m
                                      | ($ti[$m.key] | if type=="string" then . else tojson end)
                                      | gmatch($m.value) ) ) ) )
        | first ) as $hit
    | if $hit then {decision: $hit.decision, reason: ($hit.reason // null), rule: $hit.tool}
      else {decision: ($pol.default // "ask"), reason: null, rule: "default"} end'
}

# perm_enabled SESSION_DIR — true when the gate should enforce at all: a mode is
# set, or any policy file exists. Otherwise the gate is dormant (allow), so
# dropping the hook in changes nothing until you opt in.
perm_enabled() {
  [ -n "${HARSH_PERMISSIONS_MODE:-}" ] && return 0
  [ -n "$(perm_policy_paths "$1")" ] && return 0
  return 1
}
