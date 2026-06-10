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
#                  "rewrite": {"command": "git $1 --dry-run"},  # optional, see below
#                  "reason": "…" } ] }             # shown to the model on deny
# First matching rule wins. Policies layer session > project > user > built-in:
# rules concatenate in that order, scalars take the highest layer that sets one.
#
# Glob capture + rewrite: each `*` in a `match` glob is a capture group; the
# matched substrings become $1, $2, … (numbered across match fields in key
# order). A rule's optional `rewrite` is a field->template map whose $N refs are
# replaced with those captures and merged over the tool_input, so an allowed
# call runs rewritten (e.g. match {"command":"git push *"} + rewrite
# {"command":"git push --dry-run $1"}). Rewrite rides any decision that ends in
# "allow".
#
# Scope override (mainly for tests / relocating policy): HARSH_PERMISSIONS_USER
# and HARSH_PERMISSIONS_PROJECT name the user/project policy files; they default
# to ~/.config/harsh/permissions.json and ./.harsh/permissions.json.

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

# Scope -> policy-file path. The three persistable scopes plus their env
# overrides (so tests never touch the real ~/.config or repo cwd).
perm_user_file()    { printf '%s' "${HARSH_PERMISSIONS_USER:-${XDG_CONFIG_HOME:-${HOME}/.config}/harsh/permissions.json}"; }
perm_project_file() { printf '%s' "${HARSH_PERMISSIONS_PROJECT:-.harsh/permissions.json}"; }
perm_session_file() { printf '%s/permissions.json' "$1"; }
# perm_scope_file SCOPE SESSION_DIR
perm_scope_file() {
  case "$1" in
    session) perm_session_file "$2" ;;
    project) perm_project_file ;;
    user|forever) perm_user_file ;;
    *) return 1 ;;
  esac
}

# perm_policy_paths SESSION_DIR — print the layer files that exist, highest
# priority (session) first. Order matters to perm_merged_policy.
perm_policy_paths() {
  for _pp in "$(perm_session_file "$1")" "$(perm_project_file)" "$(perm_user_file)"; do
    [ -f "${_pp}" ] && printf '%s\n' "${_pp}"
  done
}

# perm_merged_policy SESSION_DIR — print the effective merged policy (built-in
# under any files found, session layer on top). HARSH_PERMISSIONS_MODE, if set
# to allow|ask|deny, overrides the merged `default`.
perm_merged_policy() {
  _pm_dir=$1
  # Emit built-in (lowest) .. session (highest); jq reduces so later files'
  # rules take precedence (prepended) and later scalars win.
  { perm_builtin_policy
    # perm_policy_paths is highest-first; reverse so session is applied last.
    _pm_rev=""
    for _f in $(perm_policy_paths "${_pm_dir}"); do _pm_rev="${_f}
${_pm_rev}"; done
    for _f in ${_pm_rev}; do cat "${_f}"; done
  } | jq -s --arg mode "${HARSH_PERMISSIONS_MODE:-}" '
      reduce .[] as $p ({default:"ask", noninteractive:"deny", rules:[]};
        { default: ($p.default // .default),
          noninteractive: ($p.noninteractive // .noninteractive),
          rules: (($p.rules // []) + .rules) })
      | if ($mode|length) > 0 then .default = $mode else . end'
}

# perm_evaluate POLICY_JSON PAYLOAD_JSON — print
# {decision, reason, rule, rewrite, caps}. caps are the matched rule's glob
# captures ($1..) and rewrite is its template (or null).
perm_evaluate() {
  printf '%s' "$2" | jq -c --argjson pol "$1" '
    def globre: ( gsub("(?<c>[.+?^${}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; "(.*)") );
    def fieldstr($ti; $k): ($ti[$k] | if type=="string" then . else tojson end);
    .tool_name as $tn | (.tool_input // {}) as $ti
    | ( ($pol.rules // [])
        | map( . as $r
               | select( ($tn | test("^(" + $r.tool + ")$"))
                         and ( ($r.match // {}) | to_entries
                               | all( . as $m | fieldstr($ti; $m.key)
                                      | test("^" + ($m.value | globre) + "$") ) ) ) )
        | first ) as $hit
    | if $hit then
        ( [ (($hit.match // {}) | to_entries[]) as $m
            | ( fieldstr($ti; $m.key) | match("^" + ($m.value | globre) + "$")
                | .captures | map(.string // "") ) ]
          | add // [] ) as $caps
        | {decision: $hit.decision, reason: ($hit.reason // null), rule: $hit.tool,
           rewrite: ($hit.rewrite // null), caps: $caps}
      else {decision: ($pol.default // "ask"), reason: null, rule: "default",
            rewrite: null, caps: []} end'
}

# perm_apply_rewrite TOOL_INPUT_JSON REWRITE_JSON CAPS_JSON — print the new
# tool_input: each $N in the rewrite templates replaced with capture N, merged
# over the original input (untouched fields survive).
perm_apply_rewrite() {
  printf '%s' "$1" | jq -c --argjson rw "$2" --argjson caps "$3" '
    def subst($caps): reduce range($caps|length; 0; -1) as $i
      (.; gsub("\\$" + ($i|tostring) + "(?![0-9])"; $caps[$i-1]));
    . * ( $rw | with_entries(.value |= subst($caps)) )'
}

# perm_enabled SESSION_DIR — true when the gate should enforce at all: a mode is
# set, or any policy file exists. Otherwise the gate is dormant (allow), so
# dropping the hook in changes nothing until you opt in.
perm_enabled() {
  [ -n "${HARSH_PERMISSIONS_MODE:-}" ] && return 0
  [ -n "$(perm_policy_paths "$1")" ] && return 0
  return 1
}

# perm_add_rule SCOPE SESSION_DIR RULE_JSON — prepend a rule to the scope's
# policy file (creating it and its parent dir), so the newest grant wins.
perm_add_rule() {
  _ar_file=$(perm_scope_file "$1" "$2") || return 1
  _ar_dir=$(dirname "${_ar_file}")
  [ -d "${_ar_dir}" ] || mkdir -p "${_ar_dir}" || return 1
  [ -f "${_ar_file}" ] || printf '{"rules":[]}' > "${_ar_file}"
  _ar_tmp="${_ar_file}.tmp.$$"
  jq -c --argjson r "$3" '.rules = ([$r] + (.rules // []))' "${_ar_file}" > "${_ar_tmp}" \
    && mv "${_ar_tmp}" "${_ar_file}"
}
