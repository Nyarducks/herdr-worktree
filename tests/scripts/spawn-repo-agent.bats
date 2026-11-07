#!/usr/bin/env bats
# spawn-repo-agent.bats — scripts/spawn-repo-agent.sh end to end with
# stubbed gh/herdr: asserts the worktree is created, the herdr call
# sequence is right, and the prompt carries the self-naming preamble. No
# network or real herdr session involved.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load helpers

setup() {
  common_setup
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
}

teardown() {
  common_teardown
}

@test "dispatch" {
  out="$("${spawn}" owner/SpawnRepo -- "fix the flaky test")"
  expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
  wt="$(find "${lab}/worktree/SpawnRepo/task" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "${wt}" ]] || _fail "task worktree created" "no dir under ${lab}/worktree/SpawnRepo/task"
  expect_eq "task worktree is detached" \
    "$(git -C "${wt}" rev-parse --abbrev-ref HEAD)" "HEAD"

  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "workspace created" "${log}" "herdr workspace create"
  expect_grep "agent start" "${log}" "herdr agent start w-"
  expect_grep "prompt submitted" "${log}" "herdr agent prompt pane-1"
  expect_grep "prompt carries self-rename" "${log}" "herdr agent rename pane-1"
  expect_grep "prompt carries tab rename" "${log}" "herdr tab rename tab-1"
  expect_grep "prompt carries task" "${log}" "fix the flaky test"
  expect_grep "prompt thinks in English" "${log}" "Language: think in English"
  expect_grep "default replies follow the human" "${log}" "in the natural language they write to you in"
  expect_not_grep "no pane run on clean start" "${log}" "herdr pane run"
  expect_not_grep "no Enter nudge on clean submit" "${log}" "send-keys"
}

@test "claude trust pre-seeds the external-imports answer" {
  echo '{}' > "${HOME}/.claude.json"
  "${spawn}" owner/SpawnRepo -- "x" > /dev/null
  wt="$(jq -r '.projects | keys[0] // empty' "${HOME}/.claude.json")"
  expect_eq "trust dialog accepted" \
    "$(jq -r --arg p "${wt}" '.projects[$p].hasTrustDialogAccepted' "${HOME}/.claude.json")" "true"
  expect_eq "external imports declined" \
    "$(jq -r --arg p "${wt}" '.projects[$p].hasClaudeMdExternalIncludesApproved' "${HOME}/.claude.json")" "false"
  expect_eq "external imports dialog marked shown" \
    "$(jq -r --arg p "${wt}" '.projects[$p].hasClaudeMdExternalIncludesWarningShown' "${HOME}/.claude.json")" "true"
}

@test "claude trust follows CLAUDE_CONFIG_DIR" {
  mkdir -p "${t}/claude-config"
  echo '{}' > "${t}/claude-config/.claude.json"
  CLAUDE_CONFIG_DIR="${t}/claude-config" "${spawn}" owner/SpawnRepo -- "x" > /dev/null
  expect_eq "trust written to CLAUDE_CONFIG_DIR/.claude.json" \
    "$(jq -r '[.projects[]?.hasTrustDialogAccepted] | first // empty' "${t}/claude-config/.claude.json")" "true"
  expect_file "nothing written to HOME/.claude.json" "${HOME}/.claude.json" absent
}

@test "pi trust is pre-seeded" {
  mkdir -p "${HOME}/.pi/agent"
  echo '{"/elsewhere": true}' > "${HOME}/.pi/agent/trust.json"
  "${spawn}" --kind pi owner/SpawnRepo -- "x" > /dev/null
  wt="$(jq -r 'keys[] | select(contains("SpawnRepo/task/"))' "${HOME}/.pi/agent/trust.json" | head -1)"
  expect_eq "worktree trusted for pi" \
    "$(jq -r --arg p "${wt}" '.[$p]' "${HOME}/.pi/agent/trust.json")" "true"
  expect_eq "existing pi trust kept" \
    "$(jq -r '.["/elsewhere"]' "${HOME}/.pi/agent/trust.json")" "true"
}

@test "stalled prompt gets an Enter nudge" {
  out="$(HERDR_STUB_PROMPT_STALL=1 "${spawn}" owner/SpawnRepo -- "unstick me" 2>&1)"
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "prompt attempted" "${log}" "herdr agent prompt pane-1"
  expect_grep "Enter nudge sent" "${log}" "herdr pane send-keys pane-1 Enter"
  expect_grep "re-wait after nudge" "${log}" "agent wait pane-1 --until working"
  expect_grep "nudge reported" "${out}" "explicit Enter nudge"
  expect_grep "still dispatched" "${out}" "Dispatched to pane pane-1"
}

@test "an agent that exits at startup fails fast" {
  started=${SECONDS}
  rc=0
  err="$(HERDR_STUB_START_HANG=1 HERDR_STUB_PANE_OUTPUT='❯ devin --permission-mode dangerous --model swe-2-medium
Error: Upgrade to Pro to access this model (https://devin.ai/pricing)
❯ ' "${spawn}" --kind devin --model swe-2-medium owner/SpawnRepo -- "x" 2>&1)" || rc=$?
  elapsed=$((SECONDS - started))
  expect_rc "startup error -> nonzero" "${rc}" nz
  expect_grep "startup error reported" "${err}" "exited during startup in pane pane-1: Error: Upgrade to Pro"
  [[ ${elapsed} -lt 10 ]] || _fail "failed fast (${elapsed}s)" "took ${elapsed}s, want < 10s"
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_not_grep "no pane-run retry" "${log}" "herdr pane run"
  expect_not_grep "no prompt sent" "${log}" "herdr agent prompt"
}

@test "an Error: line before the launch command is ignored" {
  out="$(HERDR_STUB_PANE_OUTPUT='Error: something from an earlier command
❯ claude --permission-mode auto' "${spawn}" owner/SpawnRepo -- "x" 2>&1)"
  expect_grep "still dispatched" "${out}" "Dispatched to pane pane-1"
}

@test "a dialog on screen blocks the nudge and the resend" {
  out="$(HERDR_STUB_PASTE_LOST=1 HERDR_STUB_PANE_OUTPUT=' Trust project folder?
 → Trust
   Do not trust
 ↑↓ navigate  enter select  escape/ctrl+c cancel' "${spawn}" --kind pi owner/SpawnRepo -- "x" 2>&1)" || true
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_not_grep "no Enter into the dialog" "${log}" "send-keys"
  expect_eq "prompt not resent" "$(grep -c "herdr agent prompt pane-1" <<< "${log}")" "1"
  expect_grep "dialog warning" "${out}" "showing a dialog; nothing was sent"
}

@test "an update prompt also counts as a dialog" {
  # shellcheck disable=SC2016  # the backticks are literal screen text
  HERDR_STUB_PASTE_LOST=1 HERDR_STUB_PANE_OUTPUT='  Update available · 0.165.0 → 0.166.0
› 1. Update now (runs `brew upgrade --cask codex`)
  2. Skip
  enter continue · esc skip' "${spawn}" --kind codex owner/SpawnRepo -- "x" > /dev/null 2>&1 || true
  expect_not_grep "no Enter into the update prompt" "$(cat "${HERDR_STUB_LOG}")" "send-keys"
}

@test "lost paste gets the prompt resent once" {
  out="$(HERDR_STUB_PASTE_LOST=1 "${spawn}" owner/SpawnRepo -- "resend me" 2>&1)" || true
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_eq "prompt sent twice" "$(grep -c "herdr agent prompt pane-1" <<< "${log}")" "2"
  expect_grep "Enter nudge tried first" "${log}" "herdr pane send-keys pane-1 Enter"
  expect_grep "resend reported" "${out}" "prompt was resent"
  expect_not_grep "no warning after resend" "${out}" "Warning:"
}

@test "--kind devin passes its flags to agent start" {
  out="$("${spawn}" --kind devin owner/SpawnRepo -- "ship it")"
  expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "agent start invoked" "${log}" "herdr agent start w-"
  expect_grep "kind devin" "${log}" "--kind devin"
  expect_grep "devin flags" "${log}" "--permission-mode dangerous"
  [[ "${log}" =~ herdr\ agent\ start\ (w-[a-z0-9]+)\  ]] \
    || _fail "placeholder agent name is lowercase alphanumeric" "no 'herdr agent start w-<a-z0-9>' in log"
}

@test "--model / --effort reach claude's agent start" {
  out="$("${spawn}" --model 'opus[1m]' --effort high owner/SpawnRepo -- "tune it")"
  expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "model flag passed" "${log}" "--model opus[1m]"
  expect_grep "effort flag passed" "${log}" "--effort high"
  expect_grep "default claude flags kept" "${log}" "--permission-mode auto"
}

@test "--model=/--effort= forms" {
  "${spawn}" --model=sonnet --effort=low owner/SpawnRepo -- "x" > /dev/null
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "model= form" "${log}" "--model sonnet"
  expect_grep "effort= form" "${log}" "--effort low"
}

@test "--model alone" {
  "${spawn}" --model opus owner/SpawnRepo -- "x" > /dev/null
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "model only: model passed" "${log}" "--model opus"
  expect_not_grep "model only: effort inherited" "${log}" "--effort"
}

@test "--effort alone" {
  "${spawn}" --effort max owner/SpawnRepo -- "x" > /dev/null
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "effort only: effort passed" "${log}" "--effort max"
  expect_not_grep "effort only: model inherited" "${log}" "--model"
}

@test "explicit inherit passes nothing" {
  "${spawn}" --model inherit --effort inherit owner/SpawnRepo -- "x" > /dev/null
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_not_grep "inherit: no model flag" "${log}" "--model"
  expect_not_grep "inherit: no effort flag" "${log}" "--effort"
}

@test "--kind devin --model inherit is accepted" {
  rc=0
  "${spawn}" --kind devin --model inherit owner/SpawnRepo -- "x" > /dev/null || rc=$?
  expect_rc "devin + inherit -> ok" "${rc}" 0
}

@test "no --model / --effort leaves claude flags alone" {
  "${spawn}" owner/SpawnRepo -- "x" > /dev/null
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_not_grep "no model flag" "${log}" "--model"
  expect_not_grep "no effort flag" "${log}" "--effort"
}

@test "--model / --effort reach agy's agent start" {
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
}

@test "codex maps effort to model_reasoning_effort" {
  "${spawn}" --kind codex --model gpt-6-sol --effort ultra owner/SpawnRepo -- "x" > /dev/null
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "codex kind" "${log}" "--kind codex"
  expect_grep "codex model" "${log}" "--model gpt-6-sol"
  expect_grep "codex effort via -c" "${log}" '-c model_reasoning_effort="ultra"'
}

@test "pi maps effort to --thinking" {
  "${spawn}" --kind pi --model mlx/org/Qwen-4bit --effort minimal owner/SpawnRepo -- "x" > /dev/null
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "pi kind" "${log}" "--kind pi"
  expect_grep "pi model" "${log}" "--model mlx/org/Qwen-4bit"
  expect_grep "pi thinking" "${log}" "--thinking minimal"
  expect_not_grep "pi has no --effort" "${log}" "--effort"
}

@test "devin takes --model but not --effort" {
  "${spawn}" --kind devin --model opus owner/SpawnRepo -- "x" > /dev/null
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "devin model" "${log}" "--model opus"
  expect_grep "devin flags kept" "${log}" "--permission-mode dangerous"

  : > "${HERDR_STUB_LOG}"
  run "${spawn}" --kind devin --effort high owner/SpawnRepo -- "x"
  expect_rc "devin + --effort -> error" "${status}" nz
  expect_grep "devin effort message" "${output}" "cannot be set from the command line"
  expect_grep "devin effort hint" "${output}" "level in the model id"
  expect_not_grep "nothing dispatched" "$(cat "${HERDR_STUB_LOG}")" "agent start"
}

@test "--model / --effort rejected for unsupported kinds" {
  run "${spawn}" --kind cline --model x owner/SpawnRepo -- "x"
  expect_rc "cline + --model -> error" "${status}" nz
  expect_grep "kind error message" "${output}" "not supported for --kind cline"
}

@test "invalid --effort rejected per kind" {
  run "${spawn}" --effort extreme owner/SpawnRepo -- "x"
  expect_rc "bad effort -> error" "${status}" nz
  expect_grep "effort error message" "${output}" "--effort for claude must be one of"

  run "${spawn}" --kind codex --effort max owner/SpawnRepo -- "x"
  expect_rc "codex effort outside catalog -> error" "${status}" nz
  expect_grep "codex lists its levels" "${output}" "low high ultra"

  run "${spawn}" --kind codex --model gpt-6-luna --effort ultra owner/SpawnRepo -- "x"
  expect_rc "effort outside the model's levels -> error" "${status}" nz
  expect_grep "model levels listed" "${output}" "codex gpt-6-luna must be one of: low high"
}

@test "requires herdr session" {
  rc=0
  err="$(HERDR_ENV="" "${spawn}" owner/SpawnRepo -- "x" 2>&1)" || rc=$?
  expect_rc "HERDR_ENV unset -> error" "${rc}" nz
  expect_grep "error message" "${err}" "not running inside a herdr session"
}

@test "no task — spawns an idle worker with a standby prompt" {
  out="$("${spawn}" owner/SpawnRepo)"
  expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
  expect_grep "prints idle hint" "${out}" "herdr agent prompt pane-1"
  expect_grep "idle hint returns once the task is picked up, not when it is done" "${out}" "--wait --until working --until blocked --timeout"
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "agent launched" "${log}" "herdr agent start w-"
  expect_grep "standby prompt submitted" "${log}" "agent prompt pane-1"
  expect_grep "standby keeps rename contract" "${log}" "herdr agent rename pane-1"
  expect_not_grep "no task text in prompt" "${log}" "Task:"
  expect_grep "standby carries language rule" "${log}" "Language: think in English"
}

@test "--reply-lang names the reply language" {
  "${spawn}" --reply-lang Japanese owner/SpawnRepo -- "x" > /dev/null
  log="$(cat "${HERDR_STUB_LOG}")"
  expect_grep "reply language in prompt" "${log}" "write every reply to the human in Japanese"
  : > "${HERDR_STUB_LOG}"
  "${spawn}" --reply-lang=Japanese owner/SpawnRepo > /dev/null
  expect_grep "reply language in standby prompt" "$(cat "${HERDR_STUB_LOG}")" "reply to the human in Japanese"
}

@test "bare -- with no text also spawns idle" {
  out="$("${spawn}" owner/SpawnRepo --)"
  expect_grep "reports pane" "${out}" "Dispatched to pane pane-1"
  expect_grep "standby prompt submitted" "$(cat "${HERDR_STUB_LOG}")" "agent prompt pane-1"
}

@test "extra args without -- are rejected" {
  run "${spawn}" owner/SpawnRepo stray-arg
  expect_rc "stray arg -> usage error" "${status}" nz
}

@test "--machine runs the machine's own spawn through its plugin" {
  run "${spawn}" --machine box owner/api
  expect_rc "no plugin -> exit 1" "${status}" nz
  expect_grep "no plugin explained" "${output}" "--machine needs a plugin that provides machines"

  stub_plugin box
  d="${PLUGIN_STUB}/box"
  echo '[{"label":"box","target":"box-ssh","dir":"~/herdr-worktree","registered":true}]' > "${d}/machines.json"
  printf '%s\n' \
    "Dispatched to pane w3:p2 (repo=api worktree=/home/dev/herdr-worktree/worktree/api/task/abc)." \
    "  Idle (standby prompt sent) — send a task with: herdr agent prompt w3:p2 \"<task>\" --wait --until working --until blocked --timeout 15000" > "${d}/exec-box-ssh"
  : > "${HERDR_STUB_LOG}"

  rc=0
  out="$("${spawn}" --kind codex --machine box owner/api -- "fix it --machine nope")" || rc=$?
  expect_rc "remote dispatch exits 0" "${rc}" 0
  calls="$(cat "${d}/calls")"
  expect_grep "ensured first" "$(head -2 <<< "${calls}" | tail -1)" "ensure box-ssh"
  expect_grep "then its own spawn runs there" "${calls}" "exec box-ssh -- scripts/spawn-repo-agent.sh --kind codex owner/api --"
  expect_not_grep "--machine not passed on" "$(grep '^exec' <<< "${calls}")" "--machine box"
  expect_eq "task text kept as one argument" "$(tail -1 "${d}/last-argv")" "fix it --machine nope"
  expect_grep "pane id prefixed with the label" "${out}" "Dispatched to pane box/w3:p2"
  expect_grep "hint uses herdr --machine" "${out}" "herdr --machine box agent prompt w3:p2"
  expect_eq "nothing dispatched locally" "$(wc -c < "${HERDR_STUB_LOG}" | tr -d ' ')" "0"

  : > "${d}/calls"
  rc=0
  out="$("${spawn}" --machine box-ssh owner/api 2>/dev/null)" || rc=$?
  expect_rc "addressed by target too" "${rc}" 0
  expect_grep "label still used for the prefix" "${out}" "Dispatched to pane box/w3:p2"

  run "${spawn}" --machine nowhere owner/api
  expect_rc "unknown machine -> exit 1" "${status}" nz
  expect_grep "unknown machine explained" "${output}" "no machine labeled or named 'nowhere'"

  : > "${d}/calls"
  echo 1 > "${d}/ensure-box-ssh"
  run "${spawn}" --machine box owner/api
  expect_rc "machine unavailable -> exit 1" "${status}" nz
  expect_grep "says it is unavailable" "${output}" "machine box is not available"
  expect_not_grep "nothing run there" "$(cat "${d}/calls")" "exec"
}

@test "--machine with a label holding sed's special characters keeps it literal" {
  stub_plugin box
  d="${PLUGIN_STUB}/box"
  printf '%s\n' '[{"label":"dev&1\\x|y","target":"box-ssh","dir":"~/herdr-worktree","registered":true}]' > "${d}/machines.json"
  printf '%s\n' "Dispatched to pane w3:p2 (repo=api)." "  herdr agent get w3:p2" > "${d}/exec-box-ssh"
  rc=0
  out="$("${spawn}" --machine box-ssh owner/api 2>/dev/null)" || rc=$?
  expect_rc "dispatch exits 0" "${rc}" 0
  expect_grep "pane prefixed with the literal label" "${out}" 'Dispatched to pane dev&1\x|y/w3:p2'
  expect_grep "hint names the literal label" "${out}" 'herdr --machine dev&1\x|y agent get w3:p2'
}

@test "--machine= with no value is refused, never run here" {
  : > "${HERDR_STUB_LOG}"
  run "${spawn}" --machine= owner/api
  expect_rc "empty --machine= -> exit 1" "${status}" nz
  expect_grep "explained" "${output}" "--machine needs a value"
  expect_eq "nothing dispatched locally" "$(wc -c < "${HERDR_STUB_LOG}" | tr -d ' ')" "0"
}
