#!/usr/bin/env bash
# lint.sh — run shellcheck over every tracked shell file in the repo.
#
# Covers '*.sh' (scripts/, tests/, and any future .github/scripts/) plus the extension-less git
# hooks under scripts/hooks/. Uses tools/shellcheck when present (portable
# install, gitignored), otherwise shellcheck from PATH.
set -euo pipefail

main() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"

  local shellcheck_bin="${repo_root}/tools/shellcheck"
  if [[ ! -x "${shellcheck_bin}" ]]; then
    shellcheck_bin="$(command -v shellcheck || true)"
  fi
  if [[ -z "${shellcheck_bin}" ]]; then
    echo "Error: shellcheck not found." >&2
    echo "  Portable install (gitignored): mkdir -p tools && curl -sL \\" >&2
    echo "    https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz \\" >&2
    echo "    | tar -xJ -C tools --strip-components=1 shellcheck-v0.10.0/shellcheck" >&2
    echo "  Or via package manager: sudo apt install shellcheck / brew install shellcheck" >&2
    exit 1
  fi

  local -a files=()
  local f
  while IFS= read -r f; do
    files+=("${f}")
  done < <(git -C "${repo_root}" ls-files '*.sh' 'scripts/hooks/*')

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "no shell files found" >&2
    return 0
  fi

  cd "${repo_root}"
  "${shellcheck_bin}" -x "${files[@]}"
}

main "$@"
