#!/usr/bin/env bats
# common.bats — scripts/lib/common.sh: hw_die and hw_short_id.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load ../helpers

setup() {
  common_setup
  # shellcheck source=scripts/lib/common.sh
  source "${repo_root}/scripts/lib/common.sh"
}

teardown() {
  common_teardown
}

@test "hw_die prints Error: and exits 1" {
  run hw_die "no such" thing
  expect_rc "exits 1" "${status}" nz
  expect_eq "message" "${output}" "Error: no such thing"
}

@test "hw_short_id is 12 lowercase hex characters and differs per call" {
  local a b
  a="$(hw_short_id)"
  b="$(hw_short_id)"
  [[ "${a}" =~ ^[0-9a-f]{12}$ ]] || _fail "12 lowercase hex" "got=${a}"
  expect_not_grep "differs per call" "${a}" "${b}"
}
