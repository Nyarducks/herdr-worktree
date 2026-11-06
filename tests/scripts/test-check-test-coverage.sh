#!/usr/bin/env bash
# test-check-test-coverage.sh — scripts/check-test-coverage.sh fails when
# a scripts/*.sh file has no matching tests/scripts/test-<name>.sh.
set -uo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo="${t}/repo"
mkdir -p "${repo}/scripts" "${repo}/tests/scripts"
git -C "${repo}" init -q -b main
git -C "${repo}" config user.email t@t
git -C "${repo}" config user.name t

run_check() {
  (cd "${repo}" && "${repo_root}/scripts/check-test-coverage.sh")
}

echo "== empty scripts/ -> pass =="

out="$(run_check)"
expect_rc "no scripts -> pass" "$?" 0
expect_grep "reports covered" "${out}" "every scripts/*.sh has a matching test"

echo "== script without test -> fail =="

echo "echo a" > "${repo}/scripts/foo.sh"
err="$(run_check 2>&1)"
expect_rc "missing test -> fail" "$?" nz
expect_grep "names the gap" "${err}" "no test for scripts/foo.sh"
expect_grep "expected path" "${err}" "test-foo.sh"

echo "== matching test -> pass =="

echo "exit 0" > "${repo}/tests/scripts/test-foo.sh"
out="$(run_check)"
expect_rc "covered -> pass" "$?" 0

echo "== nested scripts/lib is out of scope =="

mkdir -p "${repo}/scripts/lib"
echo "echo lib" > "${repo}/scripts/lib/helper.sh"
out="$(run_check)"
expect_rc "lib excluded -> pass" "$?" 0

echo ""
printf 'passed: %d  failed: %d\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
