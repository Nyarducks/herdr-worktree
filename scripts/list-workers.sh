#!/usr/bin/env bash
# Usage: list-workers.sh [query...]
#
# Lists the dispatched workers herdr knows about — agents whose cwd is a
# task worktree under <lab>/worktree/<repo>/ — one per line, tab-separated:
#
#   pane_id  name  repo  status  tab_label  title
#
# `name` is the agent's self-chosen slug (`-` when unnamed), `tab_label`
# the herdr tab label, `title` the agent's terminal title (usually the
# task summary). With a query, only lines that contain every query word
# (case-insensitive) are printed; no match exits 1. The orchestrator uses
# this to resolve "the DB role worker" / "the billing task" to a pane id
# before `herdr agent focus|prompt|read`.
#
# The lab root is WORKTREE_LAB_DIR, else the parent of this script's dir.
set -euo pipefail

main() {
  command -v herdr > /dev/null 2>&1 || {
    echo "Error: herdr not found on PATH." >&2
    exit 1
  }

  local script_dir lab
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  lab="${WORKTREE_LAB_DIR:-$(dirname "${script_dir}")}"
  # herdr reports physical paths (macOS /var -> /private/var)
  lab="$(cd "${lab}" 2>/dev/null && pwd -P)" || {
    echo "Error: lab directory not found: ${WORKTREE_LAB_DIR:-}" >&2
    exit 1
  }

  local agents tabs
  agents="$(herdr agent list)"
  tabs="$(herdr tab list 2>/dev/null || echo '{}')"

  local rows
  rows="$(jq -r --arg root "${lab}/worktree/" --argjson tabs "${tabs}" '
    ($tabs.result.tabs // [] | map({(.tab_id): .label}) | add // {}) as $labels
    | .result.agents // []
    | .[]
    | select((.cwd // "") | startswith($root))
    | [ .pane_id,
        (.name // "-"),
        ((.cwd | ltrimstr($root) | split("/"))[0]),
        (.agent_status // "unknown"),
        ($labels[.tab_id] // "-"),
        (.terminal_title_stripped // .terminal_title // "-")
      ]
    | map(gsub("[\t\n]"; " "))
    | @tsv' <<< "${agents}")"

  if [[ $# -eq 0 ]]; then
    [[ -n "${rows}" ]] && printf '%s\n' "${rows}"
    return 0
  fi

  local matched="${rows}" word
  for word in "$@"; do
    [[ -n "${matched}" ]] || break
    matched="$(grep -iF -- "${word}" <<< "${matched}" || true)"
  done
  if [[ -z "${matched}" ]]; then
    echo "No worker matches: $*" >&2
    exit 1
  fi
  printf '%s\n' "${matched}"
}

main "$@"
