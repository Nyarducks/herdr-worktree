# shellcheck shell=bash
# Helpers shared by setup-repo.sh and create-worktree.sh. Source, don't run.

# hw_base_branch <repo_path> — print the branch task worktrees start from:
# `main` if origin has one, else `master`. The remote-tracking refs a clone
# or fetch left behind are read first; a clone without them (e.g. bare)
# asks origin. Neither branch -> error, exit status 1.
hw_base_branch() {
  local repo_path="$1" b
  for b in main master; do
    if git -C "${repo_path}" rev-parse --verify -q "refs/remotes/origin/${b}" > /dev/null; then
      echo "${b}"
      return 0
    fi
  done
  for b in main master; do
    if git -C "${repo_path}" ls-remote --exit-code --heads origin "${b}" > /dev/null 2>&1; then
      echo "${b}"
      return 0
    fi
  done
  echo "Error: origin of ${repo_path} has neither a main nor a master branch." >&2
  return 1
}
