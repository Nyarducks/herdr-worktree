#!/usr/bin/env bash
# test-create-worktree.sh — scripts/create-worktree.sh creates
# worktree/<repo>/<branch> on a new branch from origin/main, refuses to
# overwrite an existing worktree, and installs herdr-worktree's git hooks.
set -uo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lab="${t}/lab"
make_lab "${lab}"
export WORKTREE_LAB_DIR="${lab}"
stub_gh
seed_origin TestRepo

echo "== creates worktree =="

out="$(WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/create-worktree.sh" owner/TestRepo feat/topic)"
expect_grep "prints path" "${out}" "Path:   ${lab}/worktree/TestRepo/feat/topic"
expect_file "worktree dir exists" "${lab}/worktree/TestRepo/feat/topic" exists

branch="$(git -C "${lab}/worktree/TestRepo/feat/topic" rev-parse --abbrev-ref HEAD)"
expect_eq "branch checked out" "${branch}" "feat/topic"
base="$(git -C "${lab}/worktree/TestRepo/feat/topic" rev-parse HEAD)"
origin_main="$(git -C "${lab}/repos/TestRepo" rev-parse origin/main)"
expect_eq "based on origin/main" "${base}" "${origin_main}"

echo "== --detach creates a detached HEAD =="

out="$(WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/create-worktree.sh" --detach owner/TestRepo task/abc123)"
expect_grep "prints detached" "${out}" "HEAD:   detached at origin/main"
head_ref="$(git -C "${lab}/worktree/TestRepo/task/abc123" rev-parse --abbrev-ref HEAD)"
expect_eq "HEAD detached" "${head_ref}" "HEAD"
base="$(git -C "${lab}/worktree/TestRepo/task/abc123" rev-parse HEAD)"
expect_eq "based on origin/main" "${base}" "$(git -C "${lab}/repos/TestRepo" rev-parse origin/main)"
expect_eq "no branch created" "$(git -C "${lab}/repos/TestRepo" branch --list 'task/abc123')" ""

echo "== refuses to clobber =="

err="$(WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/create-worktree.sh" owner/TestRepo feat/topic 2>&1)"
rc=$?
expect_rc "existing worktree -> error" "${rc}" nz
expect_grep "error message" "${err}" "already exists"

echo "== installs herdr-worktree git hooks as symlinks =="

hooks_dir="$(git -C "${lab}/repos/TestRepo" rev-parse --path-format=absolute --git-dir)/hooks"
expect_file "pre-commit installed" "${hooks_dir}/pre-commit" exists
if [[ -L "${hooks_dir}/pre-commit" ]]; then
  ok "pre-commit is a symlink"
else
  bad "pre-commit is a symlink"
fi
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
out="$(WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/create-worktree.sh" --detach owner/TestRepo task/foreign-link)"
expect_grep "foreign link: run completes" "${out}" "Done."
expect_eq "foreign link preserved" "$(readlink "${hooks_dir}/pre-commit")" "${lab}/foreign-hook.sh"

echo "== usage =="

WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/create-worktree.sh" owner/TestRepo > /dev/null 2>&1
expect_rc "missing args -> usage error" "$?" nz

echo ""
printf 'passed: %d  failed: %d\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
