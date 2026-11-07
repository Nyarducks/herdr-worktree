#!/usr/bin/env bats
# check-docs-stale.bats — scripts/check-docs-stale.sh flags docs whose
# declared `sources:` changed without a doc update, and sources that no
# longer exist.

# t, repo_root, stub_bin and the stubs' exports are set by helpers.bash,
# which shellcheck does not follow through `load`.
# shellcheck disable=SC2154
load helpers

# Each history step builds on the previous one; a test replays the steps up
# to the state it checks.

# make_repo — ${repo} on main: docs/design/x.md declaring sources: [src]
make_repo() {
  repo="${t}/repo"
  mkdir -p "${repo}/docs/design" "${repo}/src"
  git -C "${repo}" init -q -b main
  git -C "${repo}" config user.email t@t
  git -C "${repo}" config user.name t
  cat > "${repo}/docs/design/x.md" <<'DOC'
---
type: Design Doc
sources: [src]
---
# X
DOC
  echo "echo a" > "${repo}/src/a.sh"
  git -C "${repo}" add -A
  git -C "${repo}" commit -qm init
}

# change_source — branch feat/x changes src without touching the doc
change_source() {
  git -C "${repo}" checkout -qb feat/x
  echo "echo b" > "${repo}/src/a.sh"
  git -C "${repo}" commit -qam change
}

# update_doc — the doc catches up with the source change
update_doc() {
  echo "# updated" >> "${repo}/docs/design/x.md"
  git -C "${repo}" commit -qam docs
}

# add_adr_with_drift — an ADR declaring the same source, and the source
# changes again without the ADR (the design doc is updated alongside)
add_adr_with_drift() {
  mkdir -p "${repo}/docs/adr"
  cat > "${repo}/docs/adr/0001-x.md" <<'DOC'
---
type: ADR
sources: [src]
---
# ADR 1
DOC
  echo "echo c" > "${repo}/src/a.sh"
  echo "# updated again" >> "${repo}/docs/design/x.md"
  git -C "${repo}" add -A && git -C "${repo}" commit -qm "adr + drift"
}

run_check() {
  (cd "${repo}" && "${repo_root}/scripts/check-docs-stale.sh" "$@")
}

setup() {
  common_setup
  make_repo
}

teardown() {
  common_teardown
}

@test "clean tree passes" {
  run run_check main
  expect_rc "no diff -> pass" "${status}" 0
  expect_grep "reports fresh" "${output}" "docs fresh"
}

@test "source changed without the doc is STALE" {
  change_source
  run run_check main
  expect_rc "stale -> fail" "${status}" nz
  expect_grep "names doc" "${output}" "STALE    docs/design/x.md"
}

@test "a doc in a docs/design subdirectory is checked too" {
  mkdir -p "${repo}/docs/design/plugins/p"
  cat > "${repo}/docs/design/plugins/p/README.md" <<'DOC'
---
type: Design Doc
sources: [src]
---
# P
DOC
  git -C "${repo}" add -A
  git -C "${repo}" commit -qm "nested doc"
  change_source
  run run_check main
  expect_rc "stale -> fail" "${status}" nz
  expect_grep "names the nested doc" "${output}" "STALE    docs/design/plugins/p/README.md"
}

@test "source and doc both changed passes" {
  change_source
  update_doc
  run run_check main
  expect_rc "doc updated -> pass" "${status}" 0
}

@test "docs/adr is exempt from the staleness check" {
  # An ADR declaring the same source must not be flagged even when the
  # source changes without it — ADRs are point-in-time records.
  change_source
  update_doc
  add_adr_with_drift
  run run_check main
  expect_rc "adr sources not checked -> pass" "${status}" 0
}

@test "a removed source is MISSING" {
  change_source
  update_doc
  add_adr_with_drift
  git -C "${repo}" rm -qr src
  git -C "${repo}" commit -qm "rm src"
  run run_check main
  expect_rc "missing source -> fail" "${status}" nz
  expect_grep "reports missing" "${output}" "MISSING  docs/design/x.md — source src"
}
