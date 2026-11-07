#!/usr/bin/env bats
# json.bats — scripts/lib/json.sh: hw_json_merge edits a file in place under
# a lock and recovers a corrupt file.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# SC2016: $path in the jq filters is a jq variable — single quotes are intentional.
# shellcheck disable=SC2154,SC2016
load ../helpers

setup() {
  common_setup
  # shellcheck source=scripts/lib/json.sh
  source "${repo_root}/scripts/lib/json.sh"
  f="${t}/settings.json"
}

teardown() {
  common_teardown
}

@test "merges with \$path bound and keeps other keys" {
  echo '{"keep":1,"list":["a"]}' > "${f}"
  hw_json_merge "${f}" "b" '.list = (.list + [$path] | unique)'
  expect_eq "merged" "$(jq -c . "${f}")" '{"keep":1,"list":["a","b"]}'
  expect_file "lock released" "${f}.lock.d" absent
}

@test "a corrupt file is backed up and replaced by the merge over {}" {
  echo 'not json' > "${f}"
  hw_json_merge "${f}" "x" '.[$path] = true'
  expect_eq "recovered" "$(jq -c . "${f}")" '{"x":true}'
  local backups=("${f}".corrupt-*.bak)
  expect_file "backup kept" "${backups[0]}" exists
  expect_eq "backup content" "$(cat "${backups[0]}")" "not json"
}

@test "a failing filter leaves the file as it was" {
  echo '{"a":1}' > "${f}"
  hw_json_merge "${f}" "x" '.a.b.c = error("boom")' || true
  expect_eq "unchanged" "$(jq -c . "${f}")" '{"a":1}'
  expect_file "lock released" "${f}.lock.d" absent
}
