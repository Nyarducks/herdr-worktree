#!/usr/bin/env bats
# herdr.bats — scripts/lib/herdr.sh against a scripted herdr: session
# checks, reading a launch error or a dialog off the pane, picking the
# repo's workspace, and waiting for a launched agent.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load ../helpers

# fake_herdr — a herdr whose answers come from files in $t/h/:
#   workspaces.json  what `workspace list` prints
#   pane.txt         what `pane read` prints
#   wait-rc          exit status of `agent wait` (default 0)
# Every call is appended to $t/h/calls.
fake_herdr() {
  mkdir -p "${t}/h"
  cat > "${stub_bin}/herdr" <<'STUB'
#!/usr/bin/env bash
h="${FAKE_HERDR:?}"
echo "$*" >> "${h}/calls"
case "$1 $2" in
  "workspace list") cat "${h}/workspaces.json" 2>/dev/null || echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"root_pane":{"pane_id":"new-ws-pane"}}}' ;;
  "tab create") echo '{"result":{"root_pane":{"pane_id":"new-tab-pane"}}}' ;;
  "pane read") cat "${h}/pane.txt" 2>/dev/null ;;
  "agent wait") exit "$(cat "${h}/wait-rc" 2>/dev/null || echo 0)" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${stub_bin}/herdr"
  export FAKE_HERDR="${t}/h"
}

setup() {
  common_setup
  fake_herdr
  # shellcheck source=scripts/lib/herdr.sh
  source "${repo_root}/scripts/lib/herdr.sh"
}

teardown() {
  common_teardown
}

@test "hw_require_herdr needs herdr on PATH and a herdr session" {
  HERDR_ENV=1 hw_require_herdr
  HERDR_ENV="" run hw_require_herdr
  expect_rc "outside a session -> fail" "${status}" nz
  expect_grep "says why" "${output}" "not running inside a herdr session"
}

@test "hw_launch_error reads the first error after the latest launch" {
  printf '%s\n' "$ devin --model x" "Error: old" "$ devin --model y" "  Error: Upgrade to Pro" "Error: later" > "${t}/h/pane.txt"
  expect_eq "first error after the last launch" "$(hw_launch_error p1 devin)" "Error: Upgrade to Pro"
  printf '%s\n' "Error: before" "$ claude" "welcome" > "${t}/h/pane.txt"
  expect_eq "an error before the launch is ignored" "$(hw_launch_error p1 claude)" ""
}

@test "hw_pane_has_dialog spots a dialog prompt" {
  printf '%s\n' "Do you trust this folder?" "Enter to confirm · Esc to cancel" > "${t}/h/pane.txt"
  hw_pane_has_dialog p1
  printf '%s\n' "ready" > "${t}/h/pane.txt"
  run hw_pane_has_dialog p1
  expect_rc "no dialog" "${status}" nz
}

@test "hw_workspace_pane_for adds a tab to the repo's workspace, else creates one" {
  echo '{"result":{"workspaces":[{"label":"other","workspace_id":"ws-o"},{"label":"shop","workspace_id":"ws-s"}]}}' > "${t}/h/workspaces.json"
  expect_eq "tab in the existing workspace" "$(hw_workspace_pane_for shop /wt task-1)" "new-tab-pane"
  expect_grep "tab created in ws-s" "$(cat "${t}/h/calls")" "tab create --workspace ws-s --cwd /wt --label task-1"
  expect_eq "new workspace for a new repo" "$(hw_workspace_pane_for api /wt2 task-2)" "new-ws-pane"
  expect_grep "workspace labeled by repo" "$(cat "${t}/h/calls")" "workspace create --cwd /wt2 --label api"
}

@test "hw_wait_for_agent returns at once on success and fails fast on a launch error" {
  hw_wait_for_agent p1 claude
  echo 1 > "${t}/h/wait-rc"
  printf '%s\n' "$ claude --model nope" "Error: model not found" > "${t}/h/pane.txt"
  run hw_wait_for_agent p1 claude
  expect_rc "launch error -> fail" "${status}" nz
  expect_grep "names the error" "${output}" "exited during startup in pane p1: Error: model not found"
}
