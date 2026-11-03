#!/usr/bin/env bash
# test-check-docs-stale.sh — scripts/check-docs-stale.sh flags docs whose
# declared `sources:` changed without a doc update, and sources that no
# longer exist.
set -uo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo="${t}/repo"
mkdir -p "${repo}/docs/design" "${repo}/src"
git -C "${repo}" init -q -b main
git -C "${repo}" config user.email t@t
git -C "${repo}" config user.name t

cat > "${repo}/docs/design/x.md" <<'EOF'
---
type: Design Doc
sources: [src]
---
# X
EOF
echo "echo a" > "${repo}/src/a.sh"
git -C "${repo}" add -A
git -C "${repo}" commit -qm init

run_check() {
  (cd "${repo}" && "${repo_root}/scripts/check-docs-stale.sh" "$@")
}

echo "== clean tree -> pass =="

out="$(run_check main)"
expect_rc "no diff -> pass" "$?" 0
expect_grep "reports fresh" "${out}" "docs fresh"

echo "== source changed, doc not -> STALE =="

git -C "${repo}" checkout -qb feat/x
echo "echo b" > "${repo}/src/a.sh"
git -C "${repo}" commit -qam change
err="$(run_check main 2>&1)"
expect_rc "stale -> fail" "$?" nz
expect_grep "names doc" "${err}" "STALE    docs/design/x.md"

echo "== source + doc changed -> pass =="

echo "# updated" >> "${repo}/docs/design/x.md"
git -C "${repo}" commit -qam docs
out="$(run_check main)"
expect_rc "doc updated -> pass" "$?" 0

echo "== docs/adr is exempt =="

# An ADR declaring the same source must not be flagged even when the
# source changes without it — ADRs are point-in-time records.
mkdir -p "${repo}/docs/adr"
cat > "${repo}/docs/adr/0001-x.md" <<'EOF'
---
type: ADR
sources: [src]
---
# ADR 1
EOF
echo "echo c" > "${repo}/src/a.sh"
echo "# updated again" >> "${repo}/docs/design/x.md"
git -C "${repo}" add -A && git -C "${repo}" commit -qm "adr + drift"
out="$(run_check main)"
expect_rc "adr sources not checked -> pass" "$?" 0

echo "== missing source -> MISSING =="

git -C "${repo}" rm -qr src
git -C "${repo}" commit -qm "rm src"
err="$(run_check main 2>&1)"
expect_rc "missing source -> fail" "$?" nz
expect_grep "reports missing" "${err}" "MISSING  docs/design/x.md — source src"

echo ""
printf 'passed: %d  failed: %d\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
