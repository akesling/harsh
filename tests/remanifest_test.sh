#!/usr/bin/env sh
# remanifest: the manifest is the live view over an immutable entry log.
# Rewriting it from a spec (ordered refs + composed entries) retires the old
# view as manifest-<ts>.csv, never touches entry files, and validates the
# spec before mutating anything.

# A session with two answered turns: entries 0001..0004.
mksess() {
  _s=$(hnew "$1")
  hsh -q ask "${_s}" 'alpha topic' >/dev/null
  hsh -q ask "${_s}" 'beta topic' >/dev/null
  printf '%s' "${_s}"
}

test_remanifest_reorders_and_drops() {
  _s=$(mksess rmview)
  # New view: only the second exchange, by bare seq.
  printf '{"manifest":["3","4"]}' | hsh remanifest "${_s}" >/dev/null || fail "remanifest failed"
  _msgs=$(hsh assemble "${_s}")
  assert_eq 2 "$(printf '%s' "${_msgs}" | jq 'length')" 'two live messages'
  assert_contains "${_msgs}" 'beta topic'
  assert_not_contains "${_msgs}" 'alpha topic'
  # The dropped entries still exist in the log.
  _dir=$(hsh path "${_s}")
  [ -f "${_dir}/0001-user-text.json" ] || fail "dropped entry file vanished"
  # The outgoing view was retired with all four rows.
  set -- "${_dir}"/manifest-*.csv
  assert_eq 4 "$(grep -c . "$1")" 'retired generation intact'
}

test_remanifest_composes_new_entries_in_place() {
  _s=$(mksess rmnew)
  printf '%s' '{
    "manifest": ["@note", "0003-user-text.json", "4"],
    "entries": {"note": {"role":"user", "block":{"type":"text","text":"PINNED-NOTE"},
                         "meta":{"context":"pin"}}}
  }' | hsh remanifest "${_s}" >/dev/null || fail "remanifest failed"
  _msgs=$(hsh assemble "${_s}")
  # The composed entry leads the view, and was materialized as a normal file.
  assert_eq 'PINNED-NOTE' "$(printf '%s' "${_msgs}" | jq -r '.[0].content[0].text')"
  _dir=$(hsh path "${_s}")
  set -- "${_dir}"/0005-user-text.json
  [ -e "$1" ] || fail "composed entry not materialized in the log"
  assert_eq 'pin' "$(jq -r '.meta.context' "$1")" 'meta preserved on composed entry'
}

test_remanifest_rejects_bad_refs_without_mutating() {
  _s=$(mksess rmbad)
  _before=$(cat "$(hsh path "${_s}")/manifest.csv")
  printf '{"manifest":["99"]}' | hsh remanifest "${_s}" >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'unknown ref must fail'
  assert_eq "${_before}" "$(cat "$(hsh path "${_s}")/manifest.csv")" 'live view unchanged on bad spec'
  set -- "$(hsh path "${_s}")"/manifest-*.csv
  [ -e "$1" ] && fail "no generation should be retired on bad spec"
  return 0
}

test_remanifest_requires_refs_and_entries_to_match() {
  _s=$(mksess rmmatch)
  # Defined but unreferenced entry → error.
  printf '{"manifest":["1"],"entries":{"orphan":{"block":{"type":"text","text":"x"}}}}' \
    | hsh remanifest "${_s}" >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'unreferenced composed entry must fail'
  # Referenced but undefined key → error.
  printf '{"manifest":["@ghost"]}' | hsh remanifest "${_s}" >/dev/null 2>&1; _rc=$?
  assert_ne "${_rc}" 0 'undefined @ref must fail'
}

test_remanifest_is_undoable() {
  _s=$(mksess rmundo)
  _dir=$(hsh path "${_s}")
  printf '{"manifest":["4"]}' | hsh remanifest "${_s}" >/dev/null || fail "remanifest failed"
  # Restore the original view from the retired generation's refs.
  set -- "${_dir}"/manifest-*.csv
  cut -d, -f5 "$1" | jq -R . | jq -sc '{manifest:.}' | hsh remanifest "${_s}" >/dev/null \
    || fail "restore remanifest failed"
  assert_contains "$(hsh assemble "${_s}")" 'alpha topic'
}
