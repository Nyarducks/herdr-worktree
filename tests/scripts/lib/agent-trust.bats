#!/usr/bin/env bats
# agent-trust.bats — scripts/lib/agent-trust.sh: hw_trust_worktree writes
# the worktree into each installed agent CLI's trust config and leaves
# absent ones alone.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load ../helpers

setup() {
  common_setup
  export HOME="${t}/home"
  mkdir -p "${HOME}"
  # shellcheck source=scripts/lib/json.sh
  source "${repo_root}/scripts/lib/json.sh"
  # shellcheck source=scripts/lib/agent-trust.sh
  source "${repo_root}/scripts/lib/agent-trust.sh"
  wt="${t}/lab/worktree/R/task/abc"
}

teardown() {
  common_teardown
}

@test "claude, agy and pi configs get the worktree" {
  echo '{}' > "${HOME}/.claude.json"
  mkdir -p "${HOME}/.gemini/antigravity-cli" "${HOME}/.pi/agent"
  echo '{"trustedWorkspaces":["/old"]}' > "${HOME}/.gemini/antigravity-cli/settings.json"
  hw_trust_worktree "${wt}"
  expect_eq "claude trust accepted" "$(jq -r --arg p "${wt}" '.projects[$p].hasTrustDialogAccepted' "${HOME}/.claude.json")" "true"
  expect_eq "claude external includes declined" "$(jq -r --arg p "${wt}" '.projects[$p].hasClaudeMdExternalIncludesApproved' "${HOME}/.claude.json")" "false"
  expect_eq "agy keeps old, adds new" "$(jq -c '.trustedWorkspaces' "${HOME}/.gemini/antigravity-cli/settings.json")" "[\"/old\",\"${wt}\"]"
  expect_eq "pi trust.json created" "$(jq -r --arg p "${wt}" '.[$p]' "${HOME}/.pi/agent/trust.json")" "true"
}

@test "CLAUDE_CONFIG_DIR and PI_CODING_AGENT_DIR are honoured" {
  mkdir -p "${t}/cc" "${t}/pi"
  echo '{}' > "${t}/cc/.claude.json"
  CLAUDE_CONFIG_DIR="${t}/cc" PI_CODING_AGENT_DIR="${t}/pi" hw_trust_worktree "${wt}"
  expect_eq "claude config dir" "$(jq -r --arg p "${wt}" '.projects[$p].hasTrustDialogAccepted' "${t}/cc/.claude.json")" "true"
  expect_file "pi agent dir" "${t}/pi/trust.json" exists
}

@test "agents that are not installed are left alone" {
  hw_trust_worktree "${wt}"
  expect_file "no claude config created" "${HOME}/.claude.json" absent
  expect_file "no agy settings created" "${HOME}/.gemini" absent
  expect_file "no pi dir created" "${HOME}/.pi" absent
}
