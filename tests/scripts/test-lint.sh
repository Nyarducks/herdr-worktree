#!/usr/bin/env bash
# test-lint.sh — scripts/lint.sh prefers tools/shellcheck, falls back to
# PATH, lints every tracked *.sh plus extension-less scripts/hooks/*, and
# propagates shellcheck's exit code.
set -uo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo="${t}/repo"
mkdir -p "${repo}/scripts/hooks" "${repo}/tests"
git -C "${repo}" init -q -b main
git -C "${repo}" config user.email t@t
git -C "${repo}" config user.name t
echo "echo a" > "${repo}/scripts/foo.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${repo}/scripts/hooks/pre-commit"
echo "echo t" > "${repo}/tests/t.sh"
git -C "${repo}" add -A && git -C "${repo}" commit -qm init

# stub shellcheck: records its argv, exits ${SHELLCHECK_RC:-0}
cat > "${stub_bin}/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${SHELLCHECK_LOG:?}"
exit "${SHELLCHECK_RC:-0}"
EOF
chmod +x "${stub_bin}/shellcheck"
export SHELLCHECK_LOG="${t}/shellcheck.args"

run_lint() {
  (cd "${repo}" && "${repo_root}/scripts/lint.sh")
}

echo "== PATH fallback lints all tracked shell files =="

run_lint > /dev/null
expect_rc "lint passes" "$?" 0
for f in scripts/foo.sh scripts/hooks/pre-commit tests/t.sh; do
  expect_grep "lints ${f}" "$(cat "${SHELLCHECK_LOG}")" "${f}"
done

echo "== tools/shellcheck preferred over PATH =="

mkdir -p "${repo}/tools"
cat > "${repo}/tools/shellcheck" <<'EOF'
#!/usr/bin/env bash
echo tools > "${SHELLCHECK_ORIGIN:?}"
exit "${SHELLCHECK_RC:-0}"
EOF
chmod +x "${repo}/tools/shellcheck"
export SHELLCHECK_ORIGIN="${t}/origin.txt"
run_lint > /dev/null
expect_eq "tools shellcheck used" "$(cat "${SHELLCHECK_ORIGIN}")" "tools"

echo "== shellcheck failure propagates =="

SHELLCHECK_RC=1 run_lint > /dev/null 2>&1
expect_rc "rc propagates" "$?" nz

echo "== no shellcheck anywhere -> error =="

# PATH containing only git — shellcheck cannot be found, deterministically.
sysbin="${t}/sysbin"
mkdir -p "${sysbin}"
ln -s "$(command -v git)" "${sysbin}/git"
err="$(cd "${repo}" && rm -f tools/shellcheck && env PATH="${sysbin}" "$(command -v bash)" "${repo_root}/scripts/lint.sh" 2>&1)"
expect_rc "missing shellcheck -> fail" "$?" nz
expect_grep "install hint printed" "${err}" "shellcheck not found"

echo ""
printf 'passed: %d  failed: %d\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
