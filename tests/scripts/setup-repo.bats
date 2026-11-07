#!/usr/bin/env bats
# setup-repo.bats — scripts/setup-repo.sh clones a repo into
# $lab/repos/ on first run and fetches updates on later runs.
# `gh` is stubbed so clone resolves against a local bare origin.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin
# shellcheck disable=SC2154
load helpers

# setup_repo <args…> — run setup-repo.sh against the scratch lab
setup_repo() {
  WORKTREE_LAB_DIR="${lab}" "${repo_root}/scripts/setup-repo.sh" "$@"
}

setup() {
  common_setup
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
}

teardown() {
  common_teardown
}

@test "first run clones the repo and installs its hooks" {
  out="$(setup_repo owner/TestRepo)"
  expect_eq "prints repo path" "${out}" "${lab}/repos/TestRepo"
  expect_file "repo cloned" "${lab}/repos/TestRepo/.git" exists
  expect_grep "gh repo clone invoked" "$(cat "${GH_STUB_LOG}")" "gh repo clone owner/TestRepo"
  expect_file "hooks auto-installed" "${lab}/repos/TestRepo/.git/hooks/pre-commit" exists
}

@test "a later run fetches updates into the existing clone" {
  setup_repo owner/TestRepo > /dev/null
  # add a commit to the origin, then re-run — the base must fetch it
  seed="${t}/seed-TestRepo"
  git -C "${seed}" -c user.email=t@t -c user.name=t commit -qm second --allow-empty
  git -C "${seed}" push -q "${STUB_ORIGIN}/TestRepo.git" main
  before="$(git -C "${lab}/repos/TestRepo" rev-parse origin/main)"
  setup_repo owner/TestRepo > /dev/null
  after="$(git -C "${lab}/repos/TestRepo" rev-parse origin/main)"
  [[ "${before}" != "${after}" ]] || _fail "existing clone fetches updates" "origin/main stayed at ${before}"
}

@test "a master-only repo clones and fast-forwards without fetching main" {
  seed_origin OldRepo master
  rc=0
  setup_repo owner/OldRepo > /dev/null || rc=$?
  expect_rc "master clone -> exit 0" "${rc}" 0
  git -C "${t}/seed-OldRepo" -c user.email=t@t -c user.name=t commit -qm second --allow-empty
  git -C "${t}/seed-OldRepo" push -q "${STUB_ORIGIN}/OldRepo.git" master
  rc=0
  setup_repo owner/OldRepo > /dev/null 2>"${t}/err" || rc=$?
  expect_rc "master update -> exit 0" "${rc}" 0
  expect_eq "master update fast-forwards" "$(git -C "${lab}/repos/OldRepo" rev-parse HEAD)" "$(git -C "${t}/seed-OldRepo" rev-parse HEAD)"
  expect_not_grep "no main fetched" "$(cat "${t}/err")" "couldn't find remote ref main"
}

@test "org resolution: GH_ORG resolves a bare name; no org is an error" {
  setup_repo owner/TestRepo > /dev/null
  out="$(GH_ORG=other-org setup_repo TestRepo)"
  expect_eq "GH_ORG resolves bare repo name" "${out}" "${lab}/repos/TestRepo"

  rm -rf "${lab}/repos/TestRepo"
  run setup_repo TestRepo
  expect_rc "no org -> error" "${status}" nz
  expect_grep "error message" "${output}" "cannot determine GitHub org"
}

@test "parse_repo_arg (sourced): org/repo sets both, a bare name keeps GH_ORG" {
  # sourcing defines the functions without running main
  # shellcheck source=scripts/setup-repo.sh
  source "${repo_root}/scripts/setup-repo.sh"
  parse_repo_arg acme/shop
  expect_eq "org from the argument" "${GH_ORG}" "acme"
  expect_eq "repo from the argument" "${repo_name}" "shop"
  GH_ORG=fromenv
  parse_repo_arg api
  expect_eq "org kept from the environment" "${GH_ORG}" "fromenv"
  expect_eq "bare repo name" "${repo_name}" "api"
}

@test "an existing clone of the same name from another org is refused" {
  setup_repo owner/TestRepo > /dev/null
  # make origin look like GitHub (as gh clones it) while fetches still reach
  # the local stub origin
  export GIT_CONFIG_GLOBAL="${t}/gitconfig"
  git config --global url."${STUB_ORIGIN}/".insteadOf "https://github.com/owner/"
  git -C "${lab}/repos/TestRepo" remote set-url origin https://github.com/owner/TestRepo.git

  run setup_repo other/TestRepo
  expect_rc "other org -> error" "${status}" nz
  expect_grep "names both repositories" "${output}" "repos/TestRepo is a clone of owner/TestRepo, not other/TestRepo"
  expect_not_grep "nothing fetched" "${output}" "Updating TestRepo"

  rc=0
  out="$(setup_repo Owner/TestRepo 2>/dev/null)" || rc=$?
  expect_rc "same org, other case -> ok" "${rc}" 0
  expect_eq "same clone" "${out}" "${lab}/repos/TestRepo"
  rc=0
  out="$(GH_ORG=other setup_repo TestRepo 2>/dev/null)" || rc=$?
  expect_rc "bare name uses the existing clone whatever GH_ORG is" "${rc}" 0
}

@test "clone_org (sourced): the org of a GitHub origin, empty otherwise" {
  # shellcheck source=scripts/setup-repo.sh
  source "${repo_root}/scripts/setup-repo.sh"
  git init -q "${t}/c"
  git -C "${t}/c" remote add origin https://github.com/acme/shop.git
  expect_eq "https" "$(clone_org "${t}/c")" "acme"
  git -C "${t}/c" remote set-url origin git@github.com:acme2/shop.git
  expect_eq "ssh form" "$(clone_org "${t}/c")" "acme2"
  git -C "${t}/c" remote set-url origin /srv/git/shop.git
  expect_eq "not GitHub" "$(clone_org "${t}/c")" ""
}
