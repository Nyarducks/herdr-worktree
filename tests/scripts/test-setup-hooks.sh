#!/usr/bin/env bash
# test-setup-hooks.sh — scripts/setup-hooks.sh symlinks scripts/hooks/*
# into the common git dir, and works identically from a linked worktree
# (hooks must land in the shared .git, not the worktree's private one).
set -uo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== installs into main repo =="

repo="${t}/repo"
git init -q "${repo}"
mkdir -p "${repo}/scripts/hooks"
cp "${repo_root}/scripts/setup-hooks.sh" "${repo}/scripts/"
printf '#!/bin/sh\nexit 0\n' > "${repo}/scripts/hooks/pre-commit"
printf '#!/bin/sh\nexit 0\n' > "${repo}/scripts/hooks/pre-push"

out="$(bash "${repo}/scripts/setup-hooks.sh")"
expect_grep "reports install" "${out}" "git hooks installed"
for name in pre-commit pre-push; do
  hook="${repo}/.git/hooks/${name}"
  expect_file "${name} installed" "${hook}" exists
  if [[ -L "${hook}" ]]; then
    ok "${name} installed as symlink"
  else
    bad "${name} installed as symlink"
  fi
done

echo "== from a linked worktree, hooks land in the common git dir =="

git -C "${repo}" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
git -C "${repo}" worktree add -q "${t}/linked" -b linked 2>/dev/null
rm -f "${repo}/.git/hooks/pre-commit"   # prove the worktree call re-installs
mkdir -p "${t}/linked/scripts/hooks"
cp "${repo_root}/scripts/setup-hooks.sh" "${t}/linked/scripts/"
printf '#!/bin/sh\nexit 0\n' > "${t}/linked/scripts/hooks/pre-commit"

bash "${t}/linked/scripts/setup-hooks.sh" > /dev/null
expect_file "pre-commit lands in common hooks dir" "${repo}/.git/hooks/pre-commit" exists
expect_file "worktree has no private hooks" "${t}/linked/.git/hooks" absent

echo ""
printf 'passed: %d  failed: %d\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
