#!/usr/bin/env bash
# Usage: setup-repo.sh <[org/]repo-name>
#
# Clones the repository into $LAB/repos/<repo-name>/ if not present,
# or fetches and fast-forwards to the latest base branch (main, else
# master — scripts/lib/repo.sh) if it already exists.
# Prints the absolute path to the repository on stdout.
#
# The org is needed only to clone: <org>/<repo> in the argument, else the
# GH_ORG environment variable. An existing clone is fetched from its own
# origin. Clones are keyed by repo name, so <org>/<repo> naming another org
# than an existing repos/<repo> was cloned from is refused instead of
# silently reusing the other repository.

# Output variables set by parse_repo_arg
GH_ORG=""
org_from_arg=0
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
    org_from_arg=1
  else
    GH_ORG="${GH_ORG:-}"
    repo_name="${arg}"
    org_from_arg=0
  fi
}

# clone_org <repo_path> — the GitHub org of the clone's origin; empty when
# origin is not a GitHub URL. The configured URL is read as written (remote
# get-url would apply url.*.insteadOf rewrites).
clone_org() {
  git -C "$1" config --get remote.origin.url 2>/dev/null |
    sed -n 's|.*github\.com[:/]\([^/]*\)/.*|\1|p'
}

# check_same_repo <repo_path> — with <org>/<repo> given, refuse an existing
# clone of the same name from another org (GitHub org names ignore case).
check_same_repo() {
  local repo_path="$1" origin_org
  [[ "${org_from_arg}" -eq 1 ]] || return 0
  origin_org="$(clone_org "${repo_path}")"
  [[ -n "${origin_org}" ]] || return 0
  if [[ "${origin_org,,}" != "${GH_ORG,,}" ]]; then
    echo "Error: repos/${repo_name} is a clone of ${origin_org}/${repo_name}, not ${GH_ORG}/${repo_name}." >&2
    echo "  Repositories are kept by name, so two with the same name cannot share a lab." >&2
    return 1
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
  echo "Updating ${repo_name} ..." >&2
  local base
  base="$(hw_base_branch "${repo_path}")"
  git -C "${repo_path}" fetch origin "${base}" >&2
  # A bare base clone has no work tree to pull into; the fetch above already
  # refreshed origin/<base>, which is all create-worktree.sh consumes.
  if [[ "$(git -C "${repo_path}" rev-parse --is-bare-repository)" == "true" ]]; then
    return
  fi
  git -C "${repo_path}" pull --ff-only origin "${base}" >&2
}

main() {
  [[ $# -ne 1 ]] && usage

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/lib/repo.sh
  source "${script_dir}/lib/repo.sh"
  # shellcheck source=scripts/lib/lab.sh
  source "${script_dir}/lib/lab.sh"

  parse_repo_arg "$1"

  local lab_dir
  lab_dir="$(hw_lab_dir "$(dirname "${script_dir}")")"
  mkdir -p "${lab_dir}/repos"

  local repo_path="${lab_dir}/repos/${repo_name}"

  # A base clone is either a normal checkout (.git directory) or a bare
  # repository (HEAD file at the top level).
  if [[ ! -d "${repo_path}/.git" && ! -f "${repo_path}/HEAD" ]]; then
    clone_repo "${repo_path}"
  else
    check_same_repo "${repo_path}" || exit 1
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

# Run only when executed: tests source this file to call its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
