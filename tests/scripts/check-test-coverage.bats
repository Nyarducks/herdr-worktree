#!/usr/bin/env bats
# check-test-coverage.bats — scripts/check-test-coverage.sh fails when a
# scripts/*.sh file has no matching tests/scripts/<name>.bats, or a
# scripts/lib/*.sh no tests/scripts/lib/<name>.bats.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load helpers

setup() {
  common_setup
  repo="${t}/repo"
  mkdir -p "${repo}/scripts" "${repo}/tests/scripts"
  git -C "${repo}" init -q -b main
  git -C "${repo}" config user.email t@t
  git -C "${repo}" config user.name t
}

teardown() {
  common_teardown
}

run_check() {
  (cd "${repo}" && "${repo_root}/scripts/check-test-coverage.sh")
}

@test "empty scripts/ passes" {
  run run_check
  expect_rc "no scripts -> pass" "${status}" 0
  expect_grep "reports covered" "${output}" "every scripts/*.sh and scripts/lib/*.sh has a matching test"
}

@test "a script without a test fails" {
  echo "echo a" > "${repo}/scripts/foo.sh"
  run run_check
  expect_rc "missing test -> fail" "${status}" nz
  expect_grep "names the gap" "${output}" "no test for scripts/foo.sh"
  expect_grep "expected path" "${output}" "tests/scripts/foo.bats"
}

@test "a matching bats file passes; an old-style test-*.sh does not count" {
  echo "echo a" > "${repo}/scripts/foo.sh"
  echo "exit 0" > "${repo}/tests/scripts/test-foo.sh"
  run run_check
  expect_rc "old-style test -> fail" "${status}" nz
  echo "@test x { true; }" > "${repo}/tests/scripts/foo.bats"
  run run_check
  expect_rc "covered -> pass" "${status}" 0
}

@test "a library in scripts/lib needs tests/scripts/lib/<name>.bats" {
  mkdir -p "${repo}/scripts/lib"
  echo "echo lib" > "${repo}/scripts/lib/helper.sh"
  run run_check
  expect_rc "untested lib -> fail" "${status}" nz
  expect_grep "names the lib test" "${output}" "no test for scripts/lib/helper.sh — expected tests/scripts/lib/helper.bats"
  mkdir -p "${repo}/tests/scripts/lib"
  echo "@test x { true; }" > "${repo}/tests/scripts/lib/helper.bats"
  run run_check
  expect_rc "tested lib -> pass" "${status}" 0
}
