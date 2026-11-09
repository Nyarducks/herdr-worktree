# shellcheck shell=bash
# Where the lab is: the directory holding repos/ (base clones) and
# worktree/ (task worktrees). Source, don't run.
#
# Two layouts work: nested (repos/ and worktree/ inside this checkout) and
# split (<lab>/repos, <lab>/worktree next to the checkout at <lab>/<any>).

# hw_lab_dir <checkout_dir> — print the lab root: WORKTREE_LAB_DIR when set,
# else the nearest directory at or above <checkout_dir> that has repos/,
# else <checkout_dir> itself (a fresh nested lab; the caller creates
# repos/ when it needs it).
hw_lab_dir() {
  if [[ -n "${WORKTREE_LAB_DIR:-}" ]]; then
    printf '%s\n' "${WORKTREE_LAB_DIR}"
    return 0
  fi
  local dir="$1"
  while [[ "${dir}" != "/" && ! -d "${dir}/repos" ]]; do
    dir="$(dirname "${dir}")"
  done
  if [[ -d "${dir}/repos" ]]; then
    printf '%s\n' "${dir}"
  else
    printf '%s\n' "$1"
  fi
}
