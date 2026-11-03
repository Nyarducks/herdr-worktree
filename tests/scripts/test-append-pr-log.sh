#!/usr/bin/env bash
# test-append-pr-log.sh — scripts/append-pr-log.sh appends a collapsed
# <details> entry under "## Decision Logs" in the PR body, creating the
# header when absent. `gh api` is stubbed: GET serves a canned body from
# $GH_STUB_BODY_FILE, PATCH captures the submitted body back into it.
set -uo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

stub_gh

# a git worktree-ish dir — only needs a commit for log -1 / rev-parse
wt="${t}/wt"
git init -q -b main "${wt}"
git -C "${wt}" -c user.email=t@t -c user.name=t commit -qm "feat: the change" --allow-empty

echo "== creates Decision Logs section when absent =="

printf 'original body\n' > "${GH_STUB_BODY_FILE}"
out="$(printf '### What changed\n- did X\n' | "${repo_root}/scripts/append-pr-log.sh" o/r 1 "${wt}")"
expect_grep "reports update" "${out}" "Updated PR #1"
body="$(cat "${GH_STUB_BODY_FILE}")"
expect_grep "adds header" "${body}" "## Decision Logs"
expect_grep "adds details entry" "${body}" "<details>"
expect_grep "entry summary = commit subject" "${body}" "<summary>feat: the change ("
expect_grep "inner content included" "${body}" "did X"

echo "== appends under existing header without duplicating it =="

printf '### What changed\n- did Y\n' | "${repo_root}/scripts/append-pr-log.sh" o/r 1 "${wt}" > /dev/null
body="$(cat "${GH_STUB_BODY_FILE}")"
expect_eq "header appears once" "$(grep -c '## Decision Logs' <<<"${body}")" "1"
expect_grep "second entry appended" "${body}" "did Y"

echo "== rejects empty stdin =="

err="$(printf '' | "${repo_root}/scripts/append-pr-log.sh" o/r 1 "${wt}" 2>&1)"
rc=$?
expect_rc "empty stdin -> error" "${rc}" nz
expect_grep "error message" "${err}" "no content on stdin"

echo ""
printf 'passed: %d  failed: %d\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
