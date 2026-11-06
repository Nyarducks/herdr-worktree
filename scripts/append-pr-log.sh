#!/usr/bin/env bash
# Usage: append-pr-log.sh <owner>/<repo> <pr-number> <worktree-path>
#
# Appends the latest commit on <worktree-path> as a collapsed <details> entry
# under "## Decision Logs" in the PR body. The inner content of the entry
# (what changed / why) is read from stdin.
#
# Example:
#   scripts/append-pr-log.sh owner/repo 42 worktree/MyRepo/feat/topic <<'EOF'
#   ### What changed
#   - Rewrote foo() to handle edge case X
#
#   ### Why
#   Review comment pointed out Y was broken when input is empty.
#   EOF
set -euo pipefail

readonly DECISION_LOGS_HEADER="## Decision Logs"

usage() {
  echo "Usage: $0 <owner>/<repo> <pr-number> <worktree-path>" >&2
  echo "  Inner content is read from stdin." >&2
  exit 1
}

read_stdin_content() {
  local content
  content="$(cat)"
  if [[ -z "${content}" ]]; then
    echo "Error: no content on stdin — provide the details body." >&2
    exit 1
  fi
  printf '%s' "${content}"
}

get_commit_info() {
  local worktree_path="$1"
  commit_msg="$(git -C "${worktree_path}" log -1 --pretty=%s)"
  short_sha="$(git -C "${worktree_path}" rev-parse --short HEAD)"
}

build_entry() {
  local inner_content="$1"
  printf '<details>\n<summary>%s (%s)</summary>\n\n%s\n\n---\n\n</details>' \
    "${commit_msg}" "${short_sha}" "${inner_content}"
}

get_pr_body() {
  local owner_repo="$1"
  local pr="$2"
  gh api "repos/${owner_repo}/pulls/${pr}" --jq '.body // ""'
}

append_to_pr_body() {
  local owner_repo="$1"
  local pr="$2"
  local current_body="$3"
  local new_entry="$4"

  local new_body
  if printf '%s' "${current_body}" | grep -qF "${DECISION_LOGS_HEADER}"; then
    new_body="${current_body}

${new_entry}"
  else
    new_body="${current_body}

${DECISION_LOGS_HEADER}

${new_entry}"
  fi

  gh api "repos/${owner_repo}/pulls/${pr}" -X PATCH \
    -f "body=${new_body}" \
    --jq '.number | "Updated PR #\(.)"'
}

main() {
  [[ $# -ne 3 ]] && usage

  local owner_repo="$1"
  local pr="$2"
  local worktree_path="$3"

  local inner_content
  inner_content="$(read_stdin_content)"

  local commit_msg short_sha
  get_commit_info "${worktree_path}"

  local new_entry
  new_entry="$(build_entry "${inner_content}")"

  local current_body
  current_body="$(get_pr_body "${owner_repo}" "${pr}")"

  append_to_pr_body "${owner_repo}" "${pr}" "${current_body}" "${new_entry}"
}

main "$@"
