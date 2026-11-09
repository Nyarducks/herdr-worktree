#!/usr/bin/env bats
# repo.bats — scripts/lib/repo.sh: hw_base_branch picks main, else master.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load ../helpers

setup() {
  common_setup
  stub_gh
  # shellcheck source=scripts/lib/repo.sh
  source "${repo_root}/scripts/lib/repo.sh"
}

teardown() {
  common_teardown
}

@test "main when origin has main" {
  seed_origin WithMain main
  git clone -q "${STUB_ORIGIN}/WithMain.git" "${t}/c"
  expect_eq "main" "$(hw_base_branch "${t}/c")" "main"
}

@test "master when origin has only master" {
  seed_origin OnlyMaster master
  git clone -q "${STUB_ORIGIN}/OnlyMaster.git" "${t}/c"
  expect_eq "master" "$(hw_base_branch "${t}/c")" "master"
}

@test "neither branch is an error" {
  seed_origin Other develop
  git clone -q "${STUB_ORIGIN}/Other.git" "${t}/c"
  run hw_base_branch "${t}/c"
  expect_rc "no base -> fail" "${status}" nz
}
