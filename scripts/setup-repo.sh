#!/usr/bin/env bash
# Usage: setup-repo.sh <[org/]repo-name>
#
# Clones the repository into $LAB/repos/<repo-name>/ if not present,
# or fetches and fast-forwards to the latest main if it already exists.
# Prints the absolute path to the repository on stdout.
#
# Org resolution order:
#   1. <org>/<repo> syntax in the first argument
#   2. GH_ORG environment variable
#   3. git remote URL of existing clone
set -euo pipefail

# Output variables set by parse_repo_arg
GH_ORG=""
repo_name=""

usage() {
  echo "Usage: $0 <[org/]repo-name>" >&2
  echo "  Examples:" >&2
  echo "    $0 owner/MyRepo" >&2
  echo "    $0 MyRepo   # requires GH_ORG or existing clone" >&2
  exit 1
}

parse_repo_arg() {
  local arg="$1"
  if [[ "${arg}" == */* ]]; then
    GH_ORG="${arg%%/*}"
    repo_name="${arg##*/}"
  else
    GH_ORG="${GH_ORG:-}"
    repo_name="${arg}"
  fi
}

# Output variable: lab_dir
find_lab_dir() {
  local script_dir="$1"
  if [[ -n "${WORKTREE_LAB_DIR:-}" ]]; then
    lab_dir="${WORKTREE_LAB_DIR}"
    return
  fi
  lab_dir="${script_dir}"
  while [[ "${lab_dir}" != "/" && ! -d "${lab_dir}/repos" ]]; do
    lab_dir="$(dirname "${lab_dir}")"
  done
  if [[ ! -d "${lab_dir}/repos" ]]; then
    lab_dir="$(dirname "${script_dir}")"
    mkdir -p "${lab_dir}/repos"
  fi
}

clone_repo() {
  local repo_path="$1"
  if [[ -z "${GH_ORG}" ]]; then
    echo "Error: cannot determine GitHub org." >&2
    echo "  Use '<org>/<repo>' syntax or set the GH_ORG environment variable." >&2
    exit 1
  fi
  echo "Cloning ${GH_ORG}/${repo_name} into ${repo_path} ..." >&2
  gh repo clone "${GH_ORG}/${repo_name}" "${repo_path}" >&2
}

update_repo() {
  local repo_path="$1"
  if [[ -z "${GH_ORG}" ]]; then
    GH_ORG="$(git -C "${repo_path}" remote get-url origin \
      | sed 's|.*github\.com[:/]\([^/]*\)/.*|\1|')"
  fi
  echo "Updating ${repo_name} ..." >&2
  git -C "${repo_path}" fetch origin main >&2
  # A bare base clone has no work tree to pull into; the fetch above already
  # refreshed origin/main, which is all create-worktree.sh consumes.
  if [[ "$(git -C "${repo_path}" rev-parse --is-bare-repository)" == "true" ]]; then
    return
  fi
  git -C "${repo_path}" pull --ff-only origin main >&2
}

main() {
  [[ $# -ne 1 ]] && usage

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  parse_repo_arg "$1"

  local lab_dir
  find_lab_dir "${script_dir}"

  local repo_path="${lab_dir}/repos/${repo_name}"

  # A base clone is either a normal checkout (.git directory) or a bare
  # repository (HEAD file at the top level).
  if [[ ! -d "${repo_path}/.git" && ! -f "${repo_path}/HEAD" ]]; then
    clone_repo "${repo_path}"
  else
    update_repo "${repo_path}"
  fi

  # A repo that ships scripts/setup-hooks.sh gets its hooks installed once
  # at the base clone — linked worktrees share the common git dir, so no
  # per-worktree install is needed. stderr only: stdout is the path contract.
  if [[ -f "${repo_path}/scripts/setup-hooks.sh" ]]; then
    bash "${repo_path}/scripts/setup-hooks.sh" >&2
  fi

  echo "${repo_path}"
}

main "$@"
