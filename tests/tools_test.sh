#!/usr/bin/env sh
# The built-in tools, exercised directly through the dispatcher.

test_write_then_read_with_offset() {
  _d=$(mktemp -d); _f="${_d}/x.txt"
  tool write "$(jq -nc --arg p "${_f}" '{path:$p,content:"a\nb\nc\n"}')" >/dev/null
  _out=$(tool read "$(jq -nc --arg p "${_f}" '{path:$p,offset:2,limit:1}')")
  assert_contains "${_out}" 'b'
  assert_not_contains "${_out}" 'c'
  rm -rf "${_d}"
}

test_edit_nonunique_is_error() {
  _d=$(mktemp -d); _f="${_d}/x.txt"; printf 'b\nb\n' > "${_f}"
  assert_fails tool edit "$(jq -nc --arg p "${_f}" '{path:$p,old:"b",new:"c"}')"
  rm -rf "${_d}"
}

test_edit_all_replaces_every_occurrence() {
  _d=$(mktemp -d); _f="${_d}/x.txt"; printf 'b\nb\n' > "${_f}"
  tool edit "$(jq -nc --arg p "${_f}" '{path:$p,old:"b",new:"c",all:true}')" >/dev/null
  assert_not_contains "$(cat "${_f}")" 'b'
  rm -rf "${_d}"
}

test_edit_literal_special_chars() {
  _d=$(mktemp -d); _f="${_d}/x.txt"; printf 'one\n' > "${_f}"
  tool edit "$(jq -nc --arg p "${_f}" '{path:$p,old:"one",new:"a/b&c.*"}')" >/dev/null
  assert_contains "$(cat "${_f}")" 'a/b&c.*'
  rm -rf "${_d}"
}

test_bash_runs_command() {
  assert_contains "$(tool bash '{"command":"echo bashok"}')" 'bashok'
}

test_bash_missing_command_errors() {
  assert_fails tool bash '{}'
}

test_every_tool_schema_is_valid() {
  for _t in "${ROOT}"/tools/*.sh; do
    _b=$(basename "${_t}" .sh); [ "${_b}" = tool ] && continue
    sh "${_t}" --schema | jq -e '.name and .input_schema.type=="object"' >/dev/null \
      || fail "invalid schema: ${_b}"
  done
}

test_dispatcher_lists_and_aggregates() {
  assert_contains "$(sh "${ROOT}/tools/tool.sh" list)" 'bash'
  assert_eq "$(sh "${ROOT}/tools/tool.sh" schemas | jq 'type=="array" and length>0')" 'true'
}
