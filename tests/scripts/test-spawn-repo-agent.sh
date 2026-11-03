#!/usr/bin/env bash
# test-spawn-repo-agent.sh — scripts/spawn-repo-agent.sh end to end with
# stubbed gh/herdr: asserts the worktree is created, the herdr call
# sequence is right, and the prompt carries the self-naming preamble. No
# network or real herdr session involved.
set -uo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lab="${t}/lab"
make_lab "${lab}"
export WORKTREE_LAB_DIR="${lab}"
export HOME="${t}/home"          # keep ~/.gemini, ~/.claude.json trust edits off the real HOME
mkdir -p "${HOME}"
stub_gh
stub_herdr
stub_agent_clis
seed_origin SpawnRepo

spawn="${repo_root}/scripts/spawn-repo-agent.sh"

echo "== dispatch =="

out="$("${spawn}" owner/SpawnRepo -- "fix the flaky test")"
expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
wt="$(find "${lab}/worktree/SpawnRepo/task" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [[ -n "${wt}" ]]; then
  ok "task worktree created"
else
  bad "task worktree created"
fi
expect_eq "task worktree is detached" \
  "$(git -C "${wt}" rev-parse --abbrev-ref HEAD)" "HEAD"

log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "workspace created" "${log}" "herdr workspace create"
expect_grep "agent start" "${log}" "herdr agent start w-"
expect_grep "prompt submitted" "${log}" "herdr agent prompt pane-1"
expect_grep "prompt carries self-rename" "${log}" "herdr agent rename pane-1"
expect_grep "prompt carries tab rename" "${log}" "herdr tab rename tab-1"
expect_grep "prompt carries task" "${log}" "fix the flaky test"
expect_not_grep "no pane run on clean start" "${log}" "herdr pane run"
expect_not_grep "no Enter nudge on clean submit" "${log}" "send-keys"

echo "== claude trust pre-seeds the external-imports answer =="

: > "${HERDR_STUB_LOG}"
echo '{}' > "${HOME}/.claude.json"
"${spawn}" owner/SpawnRepo -- "x" > /dev/null
wt="$(jq -r '.projects | keys[0] // empty' "${HOME}/.claude.json")"
expect_eq "trust dialog accepted" \
  "$(jq -r --arg p "${wt}" '.projects[$p].hasTrustDialogAccepted' "${HOME}/.claude.json")" "true"
expect_eq "external imports declined" \
  "$(jq -r --arg p "${wt}" '.projects[$p].hasClaudeMdExternalIncludesApproved' "${HOME}/.claude.json")" "false"
expect_eq "external imports dialog marked shown" \
  "$(jq -r --arg p "${wt}" '.projects[$p].hasClaudeMdExternalIncludesWarningShown' "${HOME}/.claude.json")" "true"
rm -f "${HOME}/.claude.json"

echo "== pi trust is pre-seeded =="

mkdir -p "${HOME}/.pi/agent"
echo '{"/elsewhere": true}' > "${HOME}/.pi/agent/trust.json"
"${spawn}" --kind pi owner/SpawnRepo -- "x" > /dev/null
wt="$(jq -r 'keys[] | select(contains("SpawnRepo/task/"))' "${HOME}/.pi/agent/trust.json" | head -1)"
expect_eq "worktree trusted for pi" \
  "$(jq -r --arg p "${wt}" '.[$p]' "${HOME}/.pi/agent/trust.json")" "true"
expect_eq "existing pi trust kept" \
  "$(jq -r '.["/elsewhere"]' "${HOME}/.pi/agent/trust.json")" "true"
rm -rf "${HOME}/.pi"

echo "== stalled prompt gets an Enter nudge =="

: > "${HERDR_STUB_LOG}"
out="$(HERDR_STUB_PROMPT_STALL=1 "${spawn}" owner/SpawnRepo -- "unstick me" 2>&1)"
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "prompt attempted" "${log}" "herdr agent prompt pane-1"
expect_grep "Enter nudge sent" "${log}" "herdr pane send-keys pane-1 Enter"
expect_grep "re-wait after nudge" "${log}" "agent wait pane-1 --until working"
expect_grep "nudge reported" "${out}" "explicit Enter nudge"
expect_grep "still dispatched" "${out}" "Dispatched to pane pane-1"

echo "== an agent that exits at startup fails fast =="

: > "${HERDR_STUB_LOG}"
started=${SECONDS}
err="$(HERDR_STUB_START_HANG=1 HERDR_STUB_PANE_OUTPUT='❯ devin --permission-mode dangerous --model swe-2-medium
Error: Upgrade to Pro to access this model (https://devin.ai/pricing)
❯ ' "${spawn}" --kind devin --model swe-2-medium owner/SpawnRepo -- "x" 2>&1)"
rc=$?
elapsed=$((SECONDS - started))
expect_rc "startup error -> nonzero" "${rc}" nz
expect_grep "startup error reported" "${err}" "exited during startup in pane pane-1: Error: Upgrade to Pro"
if [[ ${elapsed} -lt 10 ]]; then ok "failed fast (${elapsed}s)"; else bad "failed fast (${elapsed}s)"; fi
log="$(cat "${HERDR_STUB_LOG}")"
expect_not_grep "no pane-run retry" "${log}" "herdr pane run"
expect_not_grep "no prompt sent" "${log}" "herdr agent prompt"

echo "== an Error: line before the launch command is ignored =="

: > "${HERDR_STUB_LOG}"
out="$(HERDR_STUB_PANE_OUTPUT='Error: something from an earlier command
❯ claude --permission-mode auto' "${spawn}" owner/SpawnRepo -- "x" 2>&1)"
expect_grep "still dispatched" "${out}" "Dispatched to pane pane-1"

echo "== a dialog on screen blocks the nudge and the resend =="

: > "${HERDR_STUB_LOG}"
rm -f "${HERDR_STUB_LOG}.prompted"
out="$(HERDR_STUB_PASTE_LOST=1 HERDR_STUB_PANE_OUTPUT=' Trust project folder?
 → Trust
   Do not trust
 ↑↓ navigate  enter select  escape/ctrl+c cancel' "${spawn}" --kind pi owner/SpawnRepo -- "x" 2>&1)"
log="$(cat "${HERDR_STUB_LOG}")"
expect_not_grep "no Enter into the dialog" "${log}" "send-keys"
expect_eq "prompt not resent" "$(grep -c "herdr agent prompt pane-1" <<< "${log}")" "1"
expect_grep "dialog warning" "${out}" "showing a dialog; nothing was sent"
rm -f "${HERDR_STUB_LOG}.prompted"

echo "== an update prompt also counts as a dialog =="

: > "${HERDR_STUB_LOG}"
rm -f "${HERDR_STUB_LOG}.prompted"
# shellcheck disable=SC2016  # the backticks are literal screen text
HERDR_STUB_PASTE_LOST=1 HERDR_STUB_PANE_OUTPUT='  Update available · 0.165.0 → 0.166.0
› 1. Update now (runs `brew upgrade --cask codex`)
  2. Skip
  enter continue · esc skip' "${spawn}" --kind codex owner/SpawnRepo -- "x" > /dev/null 2>&1
expect_not_grep "no Enter into the update prompt" "$(cat "${HERDR_STUB_LOG}")" "send-keys"
rm -f "${HERDR_STUB_LOG}.prompted"

echo "== lost paste gets the prompt resent once =="

: > "${HERDR_STUB_LOG}"
rm -f "${HERDR_STUB_LOG}.prompted"
out="$(HERDR_STUB_PASTE_LOST=1 "${spawn}" owner/SpawnRepo -- "resend me" 2>&1)"
log="$(cat "${HERDR_STUB_LOG}")"
expect_eq "prompt sent twice" "$(grep -c "herdr agent prompt pane-1" <<< "${log}")" "2"
expect_grep "Enter nudge tried first" "${log}" "herdr pane send-keys pane-1 Enter"
expect_grep "resend reported" "${out}" "prompt was resent"
expect_not_grep "no warning after resend" "${out}" "Warning:"
rm -f "${HERDR_STUB_LOG}.prompted"

echo "== --kind devin passes its flags to agent start =="

: > "${HERDR_STUB_LOG}"
out="$("${spawn}" --kind devin owner/SpawnRepo -- "ship it")"
expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "agent start invoked" "${log}" "herdr agent start w-"
expect_grep "kind devin" "${log}" "--kind devin"
expect_grep "devin flags" "${log}" "--permission-mode dangerous"
if [[ "${log}" =~ herdr\ agent\ start\ (w-[a-z0-9]+)\  ]]; then
  ok "placeholder agent name is lowercase alphanumeric"
else
  bad "placeholder agent name is lowercase alphanumeric"
fi

echo "== --model / --effort reach claude's agent start =="

: > "${HERDR_STUB_LOG}"
out="$("${spawn}" --model 'opus[1m]' --effort high owner/SpawnRepo -- "tune it")"
expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "model flag passed" "${log}" "--model opus[1m]"
expect_grep "effort flag passed" "${log}" "--effort high"
expect_grep "default claude flags kept" "${log}" "--permission-mode auto"

echo "== --model=/--effort= forms =="

: > "${HERDR_STUB_LOG}"
"${spawn}" --model=sonnet --effort=low owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "model= form" "${log}" "--model sonnet"
expect_grep "effort= form" "${log}" "--effort low"

echo "== --model alone =="

: > "${HERDR_STUB_LOG}"
"${spawn}" --model opus owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "model only: model passed" "${log}" "--model opus"
expect_not_grep "model only: effort inherited" "${log}" "--effort"

echo "== --effort alone =="

: > "${HERDR_STUB_LOG}"
"${spawn}" --effort max owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "effort only: effort passed" "${log}" "--effort max"
expect_not_grep "effort only: model inherited" "${log}" "--model"

echo "== explicit inherit passes nothing =="

: > "${HERDR_STUB_LOG}"
"${spawn}" --model inherit --effort inherit owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_not_grep "inherit: no model flag" "${log}" "--model"
expect_not_grep "inherit: no effort flag" "${log}" "--effort"

echo "== --kind devin --model inherit is accepted =="

: > "${HERDR_STUB_LOG}"
"${spawn}" --kind devin --model inherit owner/SpawnRepo -- "x" > /dev/null
expect_rc "devin + inherit -> ok" "$?" 0

echo "== no --model / --effort leaves claude flags alone =="

: > "${HERDR_STUB_LOG}"
"${spawn}" owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_not_grep "no model flag" "${log}" "--model"
expect_not_grep "no effort flag" "${log}" "--effort"

echo "== --model / --effort reach agy's agent start =="

: > "${HERDR_STUB_LOG}"
"${spawn}" --kind agy --model gemini-3.8-flash-medium --effort low owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "agy kind" "${log}" "--kind agy"
expect_grep "agy model passed" "${log}" "--model gemini-3.8-flash-medium"
expect_grep "agy effort passed" "${log}" "--effort low"
expect_grep "agy default flags kept" "${log}" "--dangerously-skip-permissions"

: > "${HERDR_STUB_LOG}"
"${spawn}" --kind antigravity --model gemini-3.8-flash-high owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "antigravity alias -> agy" "${log}" "--kind agy"
expect_grep "alias model passed" "${log}" "--model gemini-3.8-flash-high"

echo "== codex maps effort to model_reasoning_effort =="

: > "${HERDR_STUB_LOG}"
"${spawn}" --kind codex --model gpt-6-sol --effort ultra owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "codex kind" "${log}" "--kind codex"
expect_grep "codex model" "${log}" "--model gpt-6-sol"
expect_grep "codex effort via -c" "${log}" '-c model_reasoning_effort="ultra"'

echo "== pi maps effort to --thinking =="

: > "${HERDR_STUB_LOG}"
"${spawn}" --kind pi --model mlx/org/Qwen-4bit --effort minimal owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "pi kind" "${log}" "--kind pi"
expect_grep "pi model" "${log}" "--model mlx/org/Qwen-4bit"
expect_grep "pi thinking" "${log}" "--thinking minimal"
expect_not_grep "pi has no --effort" "${log}" "--effort"

echo "== devin takes --model but not --effort =="

: > "${HERDR_STUB_LOG}"
"${spawn}" --kind devin --model opus owner/SpawnRepo -- "x" > /dev/null
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "devin model" "${log}" "--model opus"
expect_grep "devin flags kept" "${log}" "--permission-mode dangerous"

: > "${HERDR_STUB_LOG}"
err="$("${spawn}" --kind devin --effort high owner/SpawnRepo -- "x" 2>&1)"
rc=$?
expect_rc "devin + --effort -> error" "${rc}" nz
expect_grep "devin effort message" "${err}" "cannot be set from the command line"
expect_grep "devin effort hint" "${err}" "level in the model id"
expect_not_grep "nothing dispatched" "$(cat "${HERDR_STUB_LOG}")" "agent start"

echo "== --model / --effort rejected for unsupported kinds =="

err="$("${spawn}" --kind cline --model x owner/SpawnRepo -- "x" 2>&1)"
rc=$?
expect_rc "cline + --model -> error" "${rc}" nz
expect_grep "kind error message" "${err}" "not supported for --kind cline"

echo "== invalid --effort rejected per kind =="

err="$("${spawn}" --effort extreme owner/SpawnRepo -- "x" 2>&1)"
rc=$?
expect_rc "bad effort -> error" "${rc}" nz
expect_grep "effort error message" "${err}" "--effort for claude must be one of"

err="$("${spawn}" --kind codex --effort max owner/SpawnRepo -- "x" 2>&1)"
rc=$?
expect_rc "codex effort outside catalog -> error" "${rc}" nz
expect_grep "codex lists its levels" "${err}" "low high ultra"

err="$("${spawn}" --kind codex --model gpt-6-luna --effort ultra owner/SpawnRepo -- "x" 2>&1)"
rc=$?
expect_rc "effort outside the model's levels -> error" "${rc}" nz
expect_grep "model levels listed" "${err}" "codex gpt-6-luna must be one of: low high"

echo "== requires herdr session =="

err="$(HERDR_ENV="" "${spawn}" owner/SpawnRepo -- "x" 2>&1)"
rc=$?
expect_rc "HERDR_ENV unset -> error" "${rc}" nz
expect_grep "error message" "${err}" "not running inside a herdr session"

echo "== no task — spawns an idle worker with a standby prompt =="

: > "${HERDR_STUB_LOG}"
out="$("${spawn}" owner/SpawnRepo)"
expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
expect_grep "prints idle hint" "${out}" "herdr agent prompt pane-1"
log="$(cat "${HERDR_STUB_LOG}")"
expect_grep "agent launched" "${log}" "herdr agent start w-"
expect_grep "standby prompt submitted" "${log}" "agent prompt pane-1"
expect_grep "standby keeps rename contract" "${log}" "herdr agent rename pane-1"
expect_not_grep "no task text in prompt" "${log}" "Task:"

echo "== bare -- with no text also spawns idle =="

: > "${HERDR_STUB_LOG}"
out="$("${spawn}" owner/SpawnRepo --)"
expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
expect_grep "standby prompt submitted" "$(cat "${HERDR_STUB_LOG}")" "agent prompt pane-1"

echo "== extra args without -- are rejected =="

"${spawn}" owner/SpawnRepo stray-arg > /dev/null 2>&1
expect_rc "stray arg -> usage error" "$?" nz

echo ""
printf 'passed: %d  failed: %d\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
