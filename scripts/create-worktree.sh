#!/usr/bin/env bash
# Usage: create-worktree.sh [--detach] <[org/]repo-name> <name>
#   repo-name:   MyRepo | owner/MyRepo
#   name:        feat/<topic> | fix/<issue> | refactor/<scope> | task/<uuid>
#   --detach:    create the worktree with a detached HEAD at origin/<base>
#                instead of creating a branch named <name>
#   <base> is origin's main, else master (scripts/lib/repo.sh); a repo
#   with neither is refused before anything is created.
set -euo pipefail

usage() {
  echo "Usage: $0 [--detach] <[org/]repo-name> <name>" >&2
  echo "  Examples:" >&2
  echo "    $0 owner/MyRepo feat/my-feature" >&2
  echo "    $0 MyRepo feat/my-feature   # requires GH_ORG or existing clone" >&2
  echo "    $0 --detach owner/MyRepo task/abc123   # detached HEAD at origin/main (or master)" >&2
  exit 1
}

# Output variables: repo_name, worktree_path
compute_paths() {
  local repo_path="$1"
  local name="$2"
  repo_name="$(basename "${repo_path}")"
  local lab_dir
  lab_dir="$(dirname "$(dirname "${repo_path}")")"
  worktree_path="${lab_dir}/worktree/${repo_name}/${name}"
}

add_worktree() {
  local repo_path="$1"
  local worktree_path="$2"
  local name="$3"
  local detach="$4"
  local base="$5"

  if [[ -d "${worktree_path}" ]]; then
    echo "Error: worktree already exists at ${worktree_path}" >&2
    exit 1
  fi

  mkdir -p "$(dirname "${worktree_path}")"
  echo "Creating worktree for ${repo_name} at ${worktree_path} ..."
  if [[ "${detach}" -eq 1 ]]; then
    git -C "${repo_path}" worktree add --detach "${worktree_path}" "origin/${base}"
  else
    git -C "${repo_path}" worktree add "${worktree_path}" -b "${name}" "origin/${base}"
  fi
}

install_herdr_worktree_hooks() {
  local repo_path="$1"
  local script_dir git_common hooks_src hooks_dst
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Symlink to herdr-worktree's base clone — a link into this worktree would
  # dangle once the worktree is removed.
  git_common="$(git -C "${script_dir}" rev-parse --path-format=absolute --git-common-dir)"
  hooks_src="$(dirname "${git_common}")/scripts/hooks"
  [[ -d "${hooks_src}" ]] || return 0
  hooks_dst="$(git -C "${repo_path}" rev-parse --path-format=absolute --git-dir)/hooks"
  mkdir -p "${hooks_dst}"
  local hook name dst
  for hook in "${hooks_src}"/*; do
    name="$(basename "${hook}")"
    dst="${hooks_dst}/${name}"
    if [[ -L "${dst}" ]]; then
      # refresh only links that point at our hooks; foreign links stand
      if [[ "$(readlink "${dst}")" == "${hooks_src}/"* ]]; then
        ln -sf "${hook}" "${dst}"
      fi
    elif [[ ! -e "${dst}" ]]; then
      ln -sf "${hook}" "${dst}"
    fi
    # a regular file is the repo's own hook — never clobber it
  done
}

main() {
  local detach=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detach) detach=1; shift ;;
      *) break ;;
    esac
  done
  [[ $# -ne 2 ]] && usage

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/lib/repo.sh
  source "${script_dir}/lib/repo.sh"

  local repo_arg="$1"
  local name="$2"

  local repo_path
  repo_path="$("${script_dir}/setup-repo.sh" "${repo_arg}")"

  local repo_name worktree_path
  compute_paths "${repo_path}" "${name}"

  local base
  base="$(hw_base_branch "${repo_path}")"

  add_worktree "${repo_path}" "${worktree_path}" "${name}" "${detach}" "${base}"
  install_herdr_worktree_hooks "${repo_path}"

  echo ""
  echo "Done."
  echo "  Repo:   ${repo_name}"
  echo "  Path:   ${worktree_path}"
  if [[ "${detach}" -eq 1 ]]; then
    echo "  HEAD:   detached at origin/${base}"
  else
    echo "  Branch: ${name} (from origin/${base})"
  fi
}

main "$@"
