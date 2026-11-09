#!/usr/bin/env bats
# create-worktree.bats — scripts/create-worktree.sh creates
# worktree/<repo>/<branch> on a new branch from origin/main (or master), refuses to
# overwrite an existing worktree, and installs herdr-worktree's git hooks.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin
# shellcheck disable=SC2154
load helpers

# create <args…> — run create-worktree.sh against the scratch lab
create() {
  WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/create-worktree.sh" "$@"
}

setup() {
  common_setup
  lab="${t}/lab"
  make_lab "${lab}"
  export WORKTREE_LAB_DIR="${lab}"
  stub_gh
  seed_origin TestRepo
}

teardown() {
  common_teardown
}

@test "creates a worktree on a new branch from origin/main" {
  out="$(create owner/TestRepo feat/topic)"
  expect_grep "prints path" "${out}" "Path:   ${lab}/worktree/TestRepo/feat/topic"
  expect_file "worktree dir exists" "${lab}/worktree/TestRepo/feat/topic" exists

  branch="$(git -C "${lab}/worktree/TestRepo/feat/topic" rev-parse --abbrev-ref HEAD)"
  expect_eq "branch checked out" "${branch}" "feat/topic"
  base="$(git -C "${lab}/worktree/TestRepo/feat/topic" rev-parse HEAD)"
  origin_main="$(git -C "${lab}/repos/TestRepo" rev-parse origin/main)"
  expect_eq "based on origin/main" "${base}" "${origin_main}"
}

@test "--detach creates a detached HEAD and no branch" {
  out="$(create --detach owner/TestRepo task/abc123)"
  expect_grep "prints detached" "${out}" "HEAD:   detached at origin/main"
  head_ref="$(git -C "${lab}/worktree/TestRepo/task/abc123" rev-parse --abbrev-ref HEAD)"
  expect_eq "HEAD detached" "${head_ref}" "HEAD"
  base="$(git -C "${lab}/worktree/TestRepo/task/abc123" rev-parse HEAD)"
  expect_eq "based on origin/main" "${base}" "$(git -C "${lab}/repos/TestRepo" rev-parse origin/main)"
  expect_eq "no branch created" "$(git -C "${lab}/repos/TestRepo" branch --list 'task/abc123')" ""
}

@test "a master-only repo starts from origin/master and blocks direct commits" {
  seed_origin OldRepo master
  rc=0
  out="$(create --detach owner/OldRepo task/def456)" || rc=$?
  expect_rc "master repo -> exit 0" "${rc}" 0
  expect_grep "prints detached at master" "${out}" "HEAD:   detached at origin/master"
  expect_eq "based on origin/master" "$(git -C "${lab}/worktree/OldRepo/task/def456" rev-parse HEAD)" "$(git -C "${lab}/repos/OldRepo" rev-parse origin/master)"
  out="$(create owner/OldRepo feat/x)"
  expect_grep "branch from origin/master" "${out}" "Branch: feat/x (from origin/master)"
  run git -C "${lab}/repos/OldRepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m direct
  expect_rc "pre-commit blocks master" "${status}" nz
  expect_grep "says why" "${output}" "direct commits to master are not allowed"
}

@test "a repo with neither main nor master is refused" {
  seed_origin OddRepo trunk
  run create --detach owner/OddRepo task/ghi789
  expect_rc "no main/master -> error" "${status}" nz
  expect_grep "names both branches" "${output}" "neither a main nor a master branch"
  expect_file "no worktree dir left" "${lab}/worktree/OddRepo" absent
}

@test "refuses to clobber an existing worktree" {
  create owner/TestRepo feat/topic > /dev/null
  run create owner/TestRepo feat/topic
  expect_rc "existing worktree -> error" "${status}" nz
  expect_grep "error message" "${output}" "already exists"
}

@test "installs herdr-worktree git hooks as symlinks, sparing repo-native and foreign hooks" {
  create owner/TestRepo feat/topic > /dev/null
  hooks_dir="$(git -C "${lab}/repos/TestRepo" rev-parse --path-format=absolute --git-dir)/hooks"
  expect_file "pre-commit installed" "${hooks_dir}/pre-commit" exists
  [[ -L "${hooks_dir}/pre-commit" ]] || _fail "pre-commit is a symlink" "path=${hooks_dir}/pre-commit"
  hw_base="$(dirname "$(git -C "${repo_root}" rev-parse --path-format=absolute --git-common-dir)")"
  expect_eq "symlink targets base clone hooks" "$(readlink "${hooks_dir}/pre-commit")" "${hw_base}/scripts/hooks/pre-commit"

  # a repo-native hook (regular file) is never clobbered — replace the
  # herdr-worktree symlink first (writing through it would hit the base clone)
  rm -f "${hooks_dir}/pre-push"
  printf '#!/bin/sh\necho repo-own\n' > "${hooks_dir}/pre-push"
  chmod +x "${hooks_dir}/pre-push"
  "${repo_root}/scripts/create-worktree.sh" --detach owner/TestRepo task/keep-own > /dev/null
  expect_eq "repo-native hook preserved" "$(cat "${hooks_dir}/pre-push")" "#!/bin/sh
echo repo-own"

  # a foreign symlink is left alone — and must not abort the run under
  # set -e (the old `[[ ]] && ln -sf` form returned 1 and killed the script)
  printf '#!/bin/sh\necho foreign\n' > "${lab}/foreign-hook.sh"
  chmod +x "${lab}/foreign-hook.sh"
  rm -f "${hooks_dir}/pre-commit"
  ln -s "${lab}/foreign-hook.sh" "${hooks_dir}/pre-commit"
  out="$(create --detach owner/TestRepo task/foreign-link)"
  expect_grep "foreign link: run completes" "${out}" "Done."
  expect_eq "foreign link preserved" "$(readlink "${hooks_dir}/pre-commit")" "${lab}/foreign-hook.sh"
}

@test "usage: missing arguments exit non-zero" {
  run create owner/TestRepo
  expect_rc "missing args -> usage error" "${status}" nz
}
