#!/usr/bin/env sh
# PreToolUse/bash/10-guard.sh — EXAMPLE: block a few obviously destructive
# shell commands by substring match.
#
# This demonstrates the PreToolUse contract; it is NOT a security boundary.
# Substring matching is trivially bypassed (`rm -fr`, variables, quoting…) and
# the bash tool is an unsandboxed shell regardless. Treat it as a seatbelt
# reminder and write a real policy hook (or wrap the tool) if you need
# enforcement.
#
# This hook lives under PreToolUse/bash/, so harsh runs it ONLY before the
# `bash` tool (a hook directly in PreToolUse/ would run before every tool).
# The full event payload arrives as JSON on stdin:
#   {"event":"PreToolUse","session_dir":...,"tool_name":"bash",
#    "tool_input":{"command":"..."}}
# Exit 2 to DENY — stdout becomes the reason fed back to the model as the tool
# result. Exit 0 to allow.
set -u
_cmd=$(jq -r '.tool_input.command // ""')
case "${_cmd}" in
  *"rm -rf /"* | *":(){ :|:&};:"* | *"mkfs"* | *"dd if="*"of=/dev/"*)
    printf 'refused: command looks destructive: %s\n' "${_cmd}"
    exit 2 ;;
esac
exit 0
