#!/usr/bin/env bash
# Usage: list-workers.sh [--local] [query...]
#
# Lists the dispatched workers herdr knows about — agents whose cwd is a
# task worktree under <lab>/worktree/<repo>/ — one per line, tab-separated:
#
#   pane_id  name  repo  status  tab_label  title
#
# Workers on other machines follow when a plugin provides machines
# (scripts/lib/plugins.sh, e.g. plugins/instances: dev containers and remote
# hosts): each machine's own list-workers.sh --local runs there through the
# plugin's exec, with pane_id written <label>/<pane>; drive those with
# `herdr --machine <label> ... <pane>`. A machine that does not answer is
# ensured once through its plugin, then skipped with a warning. Without an
# enabled plugin, or with --local, only this herdr is listed.
#
# `name` is the agent's self-chosen slug (`-` when unnamed), `tab_label`
# the herdr tab label, `title` the agent's terminal title (usually the
# task summary). With a query, only lines that contain every query word
# (case-insensitive) are printed; no match exits 1. The orchestrator uses
# this to resolve "the DB role worker" / "the billing task" to a pane id
# before `herdr agent focus|prompt|read`.
#
# The lab root is WORKTREE_LAB_DIR, else the nearest directory at or above
# this checkout holding repos/ (scripts/lib/lab.sh).

main() {
  command -v herdr > /dev/null 2>&1 || {
    echo "Error: herdr not found on PATH." >&2
    exit 1
  }

  local local_only=0
  if [[ "${1:-}" == "--local" ]]; then
    local_only=1
    shift
  fi

  local script_dir lab
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/lib/lab.sh
  source "${script_dir}/lib/lab.sh"
  lab="$(hw_lab_dir "$(dirname "${script_dir}")")"
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

  if [[ "${local_only}" -eq 0 ]]; then
    # shellcheck source=scripts/lib/plugins.sh
    source "${script_dir}/lib/plugins.sh"
    local bin machine target remote
    # the list is read on fd 3, so nothing in the loop eats it
    while IFS=$'\t' read -r bin machine target <&3; do
      [[ -n "${machine}" ]] || continue
      # a machine that does not answer is ensured once (its plugin restarts a
      # stopped container, explains a remote host) before it is skipped
      if remote="$(hw_plugin_exec "${bin}" "${target}" scripts/list-workers.sh --local 2>/dev/null)" ||
        { hw_plugin_ensure "${bin}" "${target}" &&
          remote="$(hw_plugin_exec "${bin}" "${target}" scripts/list-workers.sh --local 2>/dev/null)"; }; then
        if [[ -n "${remote}" ]]; then
          # prefix every line with <machine>/
          rows+="${rows:+$'\n'}${machine}/${remote//$'\n'/$'\n'${machine}/}"
        fi
      else
        echo "Warning: could not list workers on machine ${machine}; skipped." >&2
      fi
    done 3< <(hw_plugin_machines)
  fi

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

# Run only when executed: tests source this file to call its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
