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

test_edit_stdout_is_terse_no_diff() {
  # stdout is the model-facing result — it must stay terse, never the diff.
  _d=$(mktemp -d); _f="${_d}/x.txt"; printf 'one\ntwo\nthree\n' > "${_f}"
  _out=$(tool edit "$(jq -nc --arg p "${_f}" '{path:$p,old:"two",new:"TWO"}')")
  assert_contains "${_out}" 'edited'
  assert_not_contains "${_out}" '@@'    # the diff must NOT reach the model
  assert_not_contains "${_out}" '+TWO'
  rm -rf "${_d}"
}

test_edit_emits_unified_diff_on_fd3() {
  # The rich diff goes to fd 3 (the display side-channel), color-disabled here.
  _d=$(mktemp -d); _f="${_d}/x.txt"; printf 'one\ntwo\nthree\n' > "${_f}"
  _disp="${_d}/disp"
  _out=$(NO_COLOR=1 tool edit \
    "$(jq -nc --arg p "${_f}" '{path:$p,old:"two",new:"TWO"}')" 3>"${_disp}")
  _diff=$(cat "${_disp}")
  assert_contains "${_diff}" '@@'        # a hunk header → it's a real diff
  assert_contains "${_diff}" '-two'
  assert_contains "${_diff}" '+TWO'
  assert_not_contains "${_diff}" '-one'  # unchanged lines aren't churned
  rm -rf "${_d}"
}

test_edit_preserves_trailing_newline() {
  _d=$(mktemp -d); _f="${_d}/x.txt"; printf 'a\nb\nc\n' > "${_f}"
  tool edit "$(jq -nc --arg p "${_f}" '{path:$p,old:"b",new:"B"}')" >/dev/null
  # The file must still end in a newline (a regression the diff made visible).
  assert_eq "$(tail -c1 "${_f}" | od -An -c | tr -d ' ')" '\n' 'trailing newline kept'
  rm -rf "${_d}"
}

test_edit_preserves_file_mode() {
  # Editing must not change the file's permissions. The tool used to mv a temp
  # file over the target, which reset the mode (e.g. dropping a +x bit). It now
  # writes back through the existing file, preserving its mode.
  _d=$(mktemp -d); _f="${_d}/run.sh"; printf '#!/bin/sh\necho hi\n' > "${_f}"
  chmod 755 "${_f}"
  [ -x "${_f}" ] || fail 'precondition: file should be executable'
  tool edit "$(jq -nc --arg p "${_f}" '{path:$p,old:"hi",new:"bye"}')" >/dev/null
  [ -x "${_f}" ] || fail 'edit dropped the executable bit'
  # And the content actually changed.
  assert_contains "$(cat "${_f}")" 'bye'
  rm -rf "${_d}"
}

test_edit_diff_can_be_disabled() {
  _d=$(mktemp -d); _f="${_d}/x.txt"; printf 'one\ntwo\n' > "${_f}"
  _disp="${_d}/disp"
  _out=$(HARSH_EDIT_DIFF=0 tool edit \
    "$(jq -nc --arg p "${_f}" '{path:$p,old:"two",new:"TWO"}')" 3>"${_disp}")
  assert_contains "${_out}" 'edited'
  # With the diff disabled nothing reaches the fd-3 display channel.
  assert_eq "$(cat "${_disp}")" '' 'fd 3 is empty when HARSH_EDIT_DIFF=0'
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
