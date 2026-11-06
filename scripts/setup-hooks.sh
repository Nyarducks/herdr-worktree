#!/usr/bin/env bash
# Install git hooks as symlinks into the common git dir.
# Safe to call from both the main repo and any worktree.
set -euo pipefail

# Output variables: base_root, git_common_dir
resolve_git_dirs() {
  local script_dir="$1"
  git_common_dir="$(git -C "${script_dir}" rev-parse --path-format=absolute --git-common-dir)"
  # Symlinks point at the base clone's hooks — linking to a worktree's
  # copy would leave dangling hooks when the worktree is removed.
  base_root="$(dirname "${git_common_dir}")"
}

install_hooks() {
  mkdir -p "${git_common_dir}/hooks"
  local hook name
  for hook in "${base_root}"/scripts/hooks/*; do
    [[ -f "${hook}" ]] || continue
    name="$(basename "${hook}")"
    ln -sf "${hook}" "${git_common_dir}/hooks/${name}"
  done
  echo "git hooks installed"
}

main() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local base_root git_common_dir
  resolve_git_dirs "${script_dir}"
  install_hooks
}

main "$@"
