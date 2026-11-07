#!/usr/bin/env bats
# lint.bats — scripts/lint.sh prefers tools/shellcheck, falls back to PATH,
# lints every tracked *.sh, *.bats and *.bash plus extension-less
# scripts/hooks/*, and propagates shellcheck's exit code.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load helpers

setup() {
  common_setup
  repo="${t}/repo"
  mkdir -p "${repo}/scripts/hooks" "${repo}/tests"
  git -C "${repo}" init -q -b main
  git -C "${repo}" config user.email t@t
  git -C "${repo}" config user.name t
  echo "echo a" > "${repo}/scripts/foo.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${repo}/scripts/hooks/pre-commit"
  echo "echo t" > "${repo}/tests/t.sh"
  printf '#!/usr/bin/env bats\n@test x { true; }\n' > "${repo}/tests/x.bats"
  echo "h() { :; }" > "${repo}/tests/helpers.bash"
  git -C "${repo}" add -A && git -C "${repo}" commit -qm init

  # stub shellcheck: records its argv, exits ${SHELLCHECK_RC:-0}
  cat > "${stub_bin}/shellcheck" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${SHELLCHECK_LOG:?}"
exit "${SHELLCHECK_RC:-0}"
STUB
  chmod +x "${stub_bin}/shellcheck"
  export SHELLCHECK_LOG="${t}/shellcheck.args"
}

teardown() {
  common_teardown
}

run_lint() {
  (cd "${repo}" && "${repo_root}/scripts/lint.sh")
}

@test "PATH fallback lints all tracked shell files" {
  run run_lint
  expect_rc "lint passes" "${status}" 0
  local f
  for f in scripts/foo.sh scripts/hooks/pre-commit tests/t.sh tests/x.bats tests/helpers.bash; do
    expect_grep "lints ${f}" "$(cat "${SHELLCHECK_LOG}")" "${f}"
  done
}

@test "tools/shellcheck is preferred over PATH" {
  mkdir -p "${repo}/tools"
  cat > "${repo}/tools/shellcheck" <<'STUB'
#!/usr/bin/env bash
echo tools > "${SHELLCHECK_ORIGIN:?}"
exit "${SHELLCHECK_RC:-0}"
STUB
  chmod +x "${repo}/tools/shellcheck"
  export SHELLCHECK_ORIGIN="${t}/origin.txt"
  run_lint > /dev/null
  expect_eq "tools shellcheck used" "$(cat "${SHELLCHECK_ORIGIN}")" "tools"
}

@test "a shellcheck failure propagates" {
  SHELLCHECK_RC=1 run run_lint
  expect_rc "rc propagates" "${status}" nz
}

@test "no shellcheck anywhere is an error" {
  # PATH containing only git — shellcheck cannot be found, deterministically.
  local sysbin="${t}/sysbin"
  mkdir -p "${sysbin}"
  # the real git binary: /usr/bin/git on macOS is an xcrun shim that hangs
  # without the usual PATH
  ln -s "$(git --exec-path)/git" "${sysbin}/git"
  local bash_bin
  bash_bin="$(command -v bash)"
  run env -C "${repo}" PATH="${sysbin}" "${bash_bin}" "${repo_root}/scripts/lint.sh"
  expect_rc "missing shellcheck -> fail" "${status}" nz
  expect_grep "install hint printed" "${output}" "shellcheck not found"
}
