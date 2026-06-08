#!/usr/bin/env sh
# edit tool — literal string replacement in a file.
set -u
if [ "${1:-}" = --schema ]; then
  cat <<'EOF'
{"name":"edit","description":"Replace an exact string in a file. By default the old string must be unique; set all=true to replace every occurrence.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file."},"old":{"type":"string","description":"Exact text to find."},"new":{"type":"string","description":"Replacement text."},"all":{"type":"boolean","description":"Replace all occurrences (default false)."}},"required":["path","old","new"]}}
EOF
  exit 0
fi
_input=$(cat)
_path=$(printf '%s' "${_input}" | jq -r '.path // empty')
[ -n "${_path}" ] || { echo "error: missing 'path'"; exit 1; }
[ -f "${_path}" ] || { echo "error: no such file: ${_path}"; exit 1; }

_errf=$(mktemp 2>/dev/null || echo /tmp/harsh_edit.$$)
_new=$(mktemp 2>/dev/null || echo "/tmp/harsh_edit_new.$$")
# Read the file raw (-Rs), split on the literal old string, rejoin. jq's
# split/join are literal (not regex), which keeps this safe for any content.
# Output with -j (no added newline) straight to a temp file so the result is
# byte-exact — command substitution would strip the file's trailing newline.
jq -Rsj --argjson in "${_input}" '
  ($in.old) as $old | ($in.new) as $new | ($in.all // false) as $all |
  (split($old)) as $p | ($p | length - 1) as $count |
  if $count == 0 then error("old string not found in file")
  elif ($all | not) and $count > 1
    then error("old string is not unique (" + ($count|tostring) + " matches); set all=true or add context")
  elif $all then ($p | join($new))
  else ($p[0] + $new + ($p[1:] | join($old))) end
' "${_path}" > "${_new}" 2>"${_errf}"
_rc=$?
if [ "${_rc}" -ne 0 ]; then
  echo "error: $(sed 's/^jq: error.*: //' "${_errf}")"
  rm -f "${_errf}" "${_new}"
  exit 1
fi
rm -f "${_errf}"

# Render a unified diff of the change (old vs. new) before committing it to disk,
# so the result shows *what* changed rather than just that something did. Large
# diffs are capped to keep the model's context lean; HARSH_EDIT_DIFF=0 opts out.
if [ "${HARSH_EDIT_DIFF:-1}" != 0 ] && command -v diff >/dev/null 2>&1; then
  _label=${_path#./}; _label=${_label#/}
  # --label gives clean a/… b/… headers (GNU & BSD diff). If an old diff lacks
  # it, the command fails, _diff stays empty, and we just print "edited <path>".
  _diff=$(diff -u \
    --label "a/${_label}" --label "b/${_label}" \
    "${_path}" "${_new}" 2>/dev/null)
fi

# Write the result back through the EXISTING file rather than mv'ing the temp
# over it: mv would replace the inode and so reset the file's mode/ownership to
# the temp file's defaults (e.g. dropping a +x bit). Truncating the original in
# place via redirection preserves its permissions, owner, and any hard links.
cat "${_new}" > "${_path}"
rm -f "${_new}"

# stdout is the *model-facing* tool result — keep it terse. A full diff here
# would burn context for no benefit (the model already knows what it asked to
# change). The human-facing diff goes to fd 3, a display side-channel the REPL
# captures separately and never sends to the model. If fd 3 isn't open (tool
# run standalone), the diff is simply dropped.
echo "edited ${_path}"

# Is fd 3 open for writing? If not, there's no display channel — skip the diff.
if [ "${HARSH_EDIT_DIFF:-1}" != 0 ] && [ -n "${_diff:-}" ] && { : >&3; } 2>/dev/null; then
  _max=${HARSH_EDIT_DIFF_MAX:-200}
  _n=$(printf '%s\n' "${_diff}" | grep -c .)
  if [ "${_n}" -gt "${_max}" ]; then
    _diff=$(printf '%s\n' "${_diff}" | head -n "${_max}")
    _trunc=$((_n - _max))
  fi

  # Color the display diff unless suppressed. The REPL forwards fd 3 to the
  # terminal, so this is what the user sees.
  if [ -z "${NO_COLOR:-}" ] && [ "${HARSH_EDIT_DIFF_COLOR:-1}" != 0 ]; then
    if command -v delta >/dev/null 2>&1; then
      printf '%s\n' "${_diff}" | delta --paging=never >&3
    elif command -v diff-so-fancy >/dev/null 2>&1; then
      printf '%s\n' "${_diff}" | diff-so-fancy >&3
    else
      # Built-in ANSI styling: green adds, red dels, cyan hunks, bold-dim file
      # headers, dim context. Markers are kept so it still reads as a diff if
      # colors are stripped downstream.
      printf '%s\n' "${_diff}" | awk '
        BEGIN {
          grn="\033[32m"; red="\033[31m"; cyn="\033[36m";
          bld="\033[1m"; dim="\033[2m"; rst="\033[0m";
        }
        /^\+\+\+/ || /^---/ { print bld dim $0 rst; next }
        /^@@/                { print cyn $0 rst; next }
        /^\+/                { print grn $0 rst; next }
        /^-/                 { print red $0 rst; next }
                             { print dim $0 rst }
      ' >&3
    fi
  else
    printf '%s\n' "${_diff}" >&3
  fi

  if [ -n "${_trunc:-}" ]; then
    printf '... (%s more diff lines truncated; set HARSH_EDIT_DIFF_MAX to raise)\n' \
      "${_trunc}" >&3
  fi
fi
