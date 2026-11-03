#!/usr/bin/env bash
# check-test-coverage.sh — every scripts/*.sh must have a matching
# tests/scripts/test-<name>.sh. Run by the pre-push hook and as the last
# step of the CI shell-test job.
set -euo pipefail

main() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"

  local missing=0 script name
  for script in "${repo_root}"/scripts/*.sh; do
    [[ -f "${script}" ]] || continue
    name="$(basename "${script}" .sh)"
    if [[ ! -f "${repo_root}/tests/scripts/test-${name}.sh" ]]; then
      echo "[check-test-coverage] no test for ${script#"${repo_root}"/} — expected tests/scripts/test-${name}.sh" >&2
      missing=1
    fi
  done

  if [[ "${missing}" -eq 0 ]]; then
    echo "[check-test-coverage] every scripts/*.sh has a matching test"
  fi
  return "${missing}"
}

main "$@"
