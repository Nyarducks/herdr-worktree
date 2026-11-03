#!/usr/bin/env bash
# test-setup-repo.sh — scripts/setup-repo.sh clones a repo into
# $lab/repos/ on first run and fetches updates on later runs.
# `gh` is stubbed so clone resolves against a local bare origin.
set -uo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lab="${t}/lab"
make_lab "${lab}"
export WORKTREE_LAB_DIR="${lab}"
stub_gh
seed_origin TestRepo

# the seeded repo ships its own scripts/hooks + setup-hooks.sh so
# setup-repo.sh auto-installs them into the base clone's git dir
mkdir -p "${t}/seed-TestRepo/scripts/hooks"
cp "${repo_root}/scripts/setup-hooks.sh" "${t}/seed-TestRepo/scripts/"
printf '#!/bin/sh\nexit 0\n' > "${t}/seed-TestRepo/scripts/hooks/pre-commit"
git -C "${t}/seed-TestRepo" add -A
git -C "${t}/seed-TestRepo" -c user.email=t@t -c user.name=t commit -qm hooks
git -C "${t}/seed-TestRepo" push -q "${STUB_ORIGIN}/TestRepo.git" main

echo "== clone on first run =="

out="$(WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/setup-repo.sh" owner/TestRepo)"
expect_eq "prints repo path" "${out}" "${lab}/repos/TestRepo"
expect_file "repo cloned" "${lab}/repos/TestRepo/.git" exists
expect_grep "gh repo clone invoked" "$(cat "${GH_STUB_LOG}")" "gh repo clone owner/TestRepo"
expect_file "hooks auto-installed" "${lab}/repos/TestRepo/.git/hooks/pre-commit" exists

echo "== update on second run =="

# add a commit to the origin, then re-run — the base must fetch it
seed="${t}/seed-TestRepo"
git -C "${seed}" -c user.email=t@t -c user.name=t commit -qm second --allow-empty
git -C "${seed}" push -q "${STUB_ORIGIN}/TestRepo.git" main
before="$(git -C "${lab}/repos/TestRepo" rev-parse origin/main)"
WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/setup-repo.sh" owner/TestRepo > /dev/null
after="$(git -C "${lab}/repos/TestRepo" rev-parse origin/main)"
if [[ "${before}" != "${after}" ]]; then
  ok "existing clone fetches updates"
else
  bad "existing clone fetches updates"
fi

echo "== org resolution =="

out="$(WORKTREE_LAB_DIR="${lab}" GH_ORG=other-org "${repo_root}/scripts/setup-repo.sh" TestRepo)"
expect_eq "GH_ORG resolves bare repo name" "${out}" "${lab}/repos/TestRepo"

rm -rf "${lab}/repos/TestRepo"
err="$(WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/setup-repo.sh" TestRepo 2>&1)"
rc=$?
expect_rc "no org -> error" "${rc}" nz
expect_grep "error message" "${err}" "cannot determine GitHub org"

echo ""
printf 'passed: %d  failed: %d\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
