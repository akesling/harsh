#!/usr/bin/env sh
# SessionStart/10-context.sh — inject a little project context at session start.
#
# Runs once when a new session is created. Whatever it prints to stdout becomes
# the conversation's opening context (added as a user/text entry the model sees
# on the first turn). Keep it short. Exit code is ignored for this event.
set -u

printf '## Session context\n\n'
printf -- '- **Directory:** %s\n' "$(pwd)"

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _branch=$(git branch --show-current 2>/dev/null)
  [ -n "${_branch}" ] || _branch="(detached HEAD)"
  printf -- '- **Git branch:** %s\n' "${_branch}"

  _head=$(git log -1 --pretty='%h %s' 2>/dev/null)
  [ -n "${_head}" ] && printf -- '- **HEAD:** %s\n' "${_head}"

  _changes=$(git status --short 2>/dev/null | head -n 20)
  if [ -n "${_changes}" ]; then
    _n=$(printf '%s\n' "${_changes}" | grep -c .)
    printf -- '- **Uncommitted changes** (%s):\n\n' "${_n}"
    # shellcheck disable=SC2016  # backticks here are literal markdown fences
    printf '```\n%s\n```\n' "${_changes}"
  else
    printf -- '- **Working tree:** clean\n'
  fi
fi
exit 0