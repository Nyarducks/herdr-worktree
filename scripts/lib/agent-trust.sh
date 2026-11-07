# shellcheck shell=bash
# Marking a worktree trusted in each agent CLI's own config, so a new
# worker does not stop at a first-run trust dialog. Source, don't run;
# needs scripts/lib/json.sh.

# hw_trust_worktree <worktree_path>
# Pre-trusts the worktree for supported agent CLIs so the worker does not
# stop at a first-run workspace-confirmation dialog:
#   - agy:    ~/.gemini/antigravity-cli/settings.json → trustedWorkspaces
#   - claude: ${CLAUDE_CONFIG_DIR:-~}/.claude.json (Claude Code keeps it in
#             CLAUDE_CONFIG_DIR when set) → projects[<wt>].hasTrustDialogAccepted, plus
#             the external-CLAUDE.md-imports dialog pre-answered "No"
#             (hasClaudeMdExternalIncludesApproved=false, ...WarningShown=true).
#             Worktrees can sit under the herdr-worktree checkout or another dir
#             with a CLAUDE.md; any import reaching outside the worktree
#             would otherwise stop the worker at that dialog, and declining
#             keeps foreign rules out of it.
#   - pi:     ${PI_CODING_AGENT_DIR:-~/.pi/agent}/trust.json → {<wt>: true}.
#             pi's trust check walks every ancestor for a project
#             `.agents/skills`, so herdr-worktree's own skills above the
#             worktree trigger "Trust project folder?" even when the repo
#             has nothing protected. Skill discovery stops at the repo root
#             (the worktree), so trusting it loads only the repo's own
#             resources, never herdr-worktree's skills.
hw_trust_worktree() {
  local worktree_path="$1"
  command -v jq >/dev/null 2>&1 || return 0

  local agy_settings="${HOME}/.gemini/antigravity-cli/settings.json"
  if [[ -f "${agy_settings}" ]]; then
    # single quotes are intentional — $path is a jq variable, not shell
    # shellcheck disable=SC2016
    hw_json_merge "${agy_settings}" "${worktree_path}" \
      '.trustedWorkspaces = ((.trustedWorkspaces // []) + [$path] | unique)'
  fi

  local claude_settings="${CLAUDE_CONFIG_DIR:-${HOME}}/.claude.json"
  if [[ -f "${claude_settings}" ]]; then
    # single quotes are intentional — $path is a jq variable, not shell
    # shellcheck disable=SC2016
    hw_json_merge "${claude_settings}" "${worktree_path}" \
      '.projects[$path] = ((.projects[$path] // {}) + {
         hasTrustDialogAccepted: true,
         hasClaudeMdExternalIncludesApproved: false,
         hasClaudeMdExternalIncludesWarningShown: true
       })'
  fi

  local pi_trust="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}/trust.json"
  if [[ -d "$(dirname "${pi_trust}")" ]]; then
    [[ -f "${pi_trust}" ]] || echo '{}' > "${pi_trust}"
    # single quotes are intentional — $path is a jq variable, not shell
    # shellcheck disable=SC2016
    hw_json_merge "${pi_trust}" "${worktree_path}" '.[$path] = true'
  fi
}
