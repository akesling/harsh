#!/usr/bin/env sh
# SessionStart/10-context.sh — inject a little project context at session start.
#
# Runs once when a new session is created. Whatever it prints to stdout becomes
# the conversation's opening context (added as a user/text entry the model sees
# on the first turn). Keep it short. Exit code is ignored for this event.
set -u
printf 'Session working directory: %s\n' "$(pwd)"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Git branch: %s\n' "$(git branch --show-current 2>/dev/null)"
  changes=$(git status --short 2>/dev/null | head -n 20)
  [ -n "$changes" ] && printf 'Uncommitted changes:\n%s\n' "$changes"
fi
exit 0
