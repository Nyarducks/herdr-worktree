#!/usr/bin/env bash
# check-test-coverage.sh — every scripts/*.sh must have a matching bats
# file tests/scripts/<name>.bats, and every scripts/lib/*.sh a
# tests/scripts/lib/<name>.bats. Run by the pre-push hook and as the last
# step of the CI shell-test job.

main() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"

  local missing=0 script rel want
  for script in "${repo_root}"/scripts/*.sh "${repo_root}"/scripts/lib/*.sh; do
    [[ -f "${script}" ]] || continue
    rel="${script#"${repo_root}"/scripts/}"
    want="tests/scripts/${rel%.sh}.bats"
    if [[ ! -f "${repo_root}/${want}" ]]; then
      echo "[check-test-coverage] no test for scripts/${rel} — expected ${want}" >&2
      missing=1
    fi
  done

  if [[ "${missing}" -eq 0 ]]; then
    echo "[check-test-coverage] every scripts/*.sh and scripts/lib/*.sh has a matching test"
  fi
  return "${missing}"
}

# Run only when executed: tests source this file to call its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
