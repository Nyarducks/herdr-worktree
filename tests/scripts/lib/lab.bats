#!/usr/bin/env bats
# lab.bats — scripts/lib/lab.sh: hw_lab_dir finds the lab for both layouts.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load ../helpers

setup() {
  common_setup
  unset WORKTREE_LAB_DIR
  # shellcheck source=scripts/lib/lab.sh
  source "${repo_root}/scripts/lib/lab.sh"
}

teardown() {
  common_teardown
}

@test "WORKTREE_LAB_DIR wins" {
  WORKTREE_LAB_DIR="${t}/elsewhere" run hw_lab_dir "${t}/lab/checkout"
  expect_eq "env override" "${output}" "${t}/elsewhere"
}

@test "nested layout: the checkout holding repos/ is the lab" {
  mkdir -p "${t}/checkout/repos"
  expect_eq "nested" "$(hw_lab_dir "${t}/checkout")" "${t}/checkout"
}

@test "split layout: the parent holding repos/ is the lab" {
  mkdir -p "${t}/lab/repos" "${t}/lab/herdr-worktree"
  expect_eq "split" "$(hw_lab_dir "${t}/lab/herdr-worktree")" "${t}/lab"
}

@test "no repos/ anywhere: the checkout itself" {
  mkdir -p "${t}/fresh"
  expect_eq "fresh nested lab" "$(hw_lab_dir "${t}/fresh")" "${t}/fresh"
}
