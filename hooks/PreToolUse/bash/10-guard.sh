#!/usr/bin/env sh
# PreToolUse/bash/10-guard.sh — block obviously destructive shell commands.
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
