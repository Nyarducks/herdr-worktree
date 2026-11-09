# shellcheck shell=bash
# Driving herdr for a dispatch: workspaces, panes, and waiting for a newly
# launched agent. Source, don't run. Needs herdr and jq. Failures print
# "Error: ..." to stderr and return 1; callers decide whether to exit.

# hw_require_herdr — herdr is on PATH and this runs inside a herdr session.
hw_require_herdr() {
  command -v herdr > /dev/null 2>&1 || {
    echo "Error: herdr not found on PATH. Cannot dispatch a worker." >&2
    return 1
  }
  [[ "${HERDR_ENV:-}" == "1" ]] || {
    echo "Error: not running inside a herdr session (HERDR_ENV is unset)." >&2
    return 1
  }
}

# hw_launch_error <pane_id> <kind>
# Prints the first `Error:` line the agent CLI wrote after its most recent
# launch command in the pane (e.g. devin's "Error: Upgrade to Pro to access
# this model"), or nothing. A CLI that exits at startup leaves the agent
# unregistered, so herdr would otherwise wait out its full timeout.
hw_launch_error() {
  local pane_id="$1" kind="$2"
  herdr pane read "${pane_id}" --source recent-unwrapped --lines 40 2>/dev/null |
    awk -v k="${kind}" '
      { line[NR] = $0 }
      $0 ~ ("(^|[ /])" k "( |$)") { start = NR }
      END {
        if (!start) exit
        for (i = start + 1; i <= NR; i++) {
          l = line[i]; sub(/^[ \t]+/, "", l)
          if (l ~ /^([Ee]rror|fatal)[: ]/) { print l; exit }
        }
      }'
}

# hw_pane_has_dialog <pane_id>
# True when the pane shows a selection/confirmation dialog (trust prompts,
# import approvals, …). herdr can report such an agent as idle, so an Enter
# nudge or a resent prompt would answer the dialog — check before either.
hw_pane_has_dialog() {
  herdr pane read "$1" --source recent-unwrapped --lines 30 2>/dev/null |
    grep -Eqi 'enter (to )?(select|confirm|continue)|esc (to )?(skip|cancel)|do not trust|trust (this|project)|allow external|update available'
}

# hw_workspace_pane_for <repo_name> <worktree_path> <tab_label>
# Prints the pane_id hosting the new worktree: a new tab in the repo's
# existing workspace when one exists, otherwise a new workspace's root pane.
hw_workspace_pane_for() {
  local repo_name="$1" wt="$2" tab_label="$3"
  local ws_id pane_id
  ws_id="$(herdr workspace list 2>/dev/null | jq -r --arg l "${repo_name}" \
    '[.result.workspaces[]? | select(.label == $l)][0].workspace_id // empty')"

  if [[ -n "${ws_id}" ]]; then
    pane_id="$(herdr tab create --workspace "${ws_id}" --cwd "${wt}" \
      --label "${tab_label}" --no-focus |
      jq -r '.result.root_pane.pane_id // .result.pane.pane_id // empty')"
  else
    pane_id="$(herdr workspace create --cwd "${wt}" --label "${repo_name}" --no-focus |
      jq -r '.result.root_pane.pane_id // empty')"
  fi
  [[ -n "${pane_id}" && "${pane_id}" != "null" ]] || {
    echo "Error: could not obtain a pane for ${wt}." >&2
    return 1
  }
  printf '%s\n' "${pane_id}"
}

# hw_wait_for_agent <pane_id> <kind>
# After `herdr pane run`, `herdr agent wait` errors with "agent_not_found"
# until the agent's SessionStart hook registers the pane — retry briefly.
# A CLI that wrote an error and exited fails at once instead of waiting.
hw_wait_for_agent() {
  local pane_id="$1" kind="$2" attempt=0 err
  until herdr agent wait "${pane_id}" --until idle --until blocked --timeout 5000 >&2; do
    err="$(hw_launch_error "${pane_id}" "${kind}")"
    if [[ -n "${err}" ]]; then
      echo "Error: the agent exited during startup in pane ${pane_id}: ${err}" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    if [[ ${attempt} -ge 6 ]]; then
      echo "Error: agent at pane ${pane_id} did not register/become ready in time." >&2
      return 1
    fi
    sleep 1
  done
}
