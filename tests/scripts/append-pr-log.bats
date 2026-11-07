#!/usr/bin/env bats
# append-pr-log.bats — scripts/append-pr-log.sh appends a collapsed
# <details> entry under "## Decision Logs" in the PR body, creating the
# header when absent. `gh api` is stubbed: GET serves a canned body from
# $GH_STUB_BODY_FILE, PATCH captures the submitted body back into it.

# t, repo_root, stub_bin and the stubs' exports are set by helpers.bash,
# which shellcheck does not follow through `load`.
# shellcheck disable=SC2154
load helpers

# append_log <content> — pipe <content> (backslash escapes expanded) into
# append-pr-log.sh for PR o/r#1 from the worktree ${wt}
append_log() {
  printf '%b' "$1" | "${repo_root}/scripts/append-pr-log.sh" o/r 1 "${wt}"
}

setup() {
  common_setup
  stub_gh
  # a git worktree-ish dir — only needs a commit for log -1 / rev-parse
  wt="${t}/wt"
  git init -q -b main "${wt}"
  git -C "${wt}" -c user.email=t@t -c user.name=t commit -qm "feat: the change" --allow-empty
  printf 'original body\n' > "${GH_STUB_BODY_FILE}"
}

teardown() {
  common_teardown
}

@test "creates the Decision Logs section when absent" {
  out="$(append_log '### What changed\n- did X\n')"
  expect_grep "reports update" "${out}" "Updated PR #1"
  body="$(cat "${GH_STUB_BODY_FILE}")"
  expect_grep "adds header" "${body}" "## Decision Logs"
  expect_grep "adds details entry" "${body}" "<details>"
  expect_grep "entry summary = commit subject" "${body}" "<summary>feat: the change ("
  expect_grep "inner content included" "${body}" "did X"
}

@test "appends under an existing header without duplicating it" {
  append_log '### What changed\n- did X\n' > /dev/null   # creates the header
  append_log '### What changed\n- did Y\n' > /dev/null
  body="$(cat "${GH_STUB_BODY_FILE}")"
  expect_eq "header appears once" "$(grep -c '## Decision Logs' <<<"${body}")" "1"
  expect_grep "second entry appended" "${body}" "did Y"
}

@test "rejects empty stdin" {
  run append_log ''
  expect_rc "empty stdin -> error" "${status}" nz
  expect_grep "error message" "${output}" "no content on stdin"
}
