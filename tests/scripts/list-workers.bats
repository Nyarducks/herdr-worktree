#!/usr/bin/env bats
# list-workers.bats — scripts/list-workers.sh with a stubbed herdr:
# only agents in task worktrees are listed, with tab labels joined in, and
# query words narrow the list (no match exits 1).

# common_setup (helpers.bash) assigns repo_root, t and stub_bin
# shellcheck disable=SC2154
load helpers

# stub_machines — a stub plugin that knows three machines: box answers, down
# does not (even after ensure), back answers only after an ensure (a stopped
# container). Sets d to the stub's state dir.
stub_machines() {
  stub_plugin box
  d="${PLUGIN_STUB}/box"
  echo '[{"label":"box","target":"box-ssh","dir":"~/herdr-worktree","registered":true},{"label":"down","target":"down-ssh","dir":"~/hw","registered":true},{"label":"back","target":"back-ssh","dir":"~/hw","registered":true}]' > "${d}/machines.json"
  printf 'w5:p2\tapi-fix\tapi\tidle\tfix api\tFix the API\n' > "${d}/exec-box-ssh"
  echo 1 > "${d}/ensure-down-ssh"
  printf 'w1:p1\tdb\tshop\tidle\tdb\tDB\n' > "${d}/exec-back-ssh"
  touch "${d}/needs-up-back-ssh"
}

setup() {
  common_setup
  lab="${t}/lab"
  make_lab "${lab}"
  export WORKTREE_LAB_DIR="${lab}"
  wt_root="$(cd "${lab}" && pwd -P)/worktree"

  cat > "${stub_bin}/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent list") cat <<'JSON'
{"result":{"agents":[
 {"pane_id":"w1:p1","tab_id":"w1:t1","cwd":"${lab}","agent_status":"working","terminal_title_stripped":"orchestrator"},
 {"pane_id":"w2:p3","tab_id":"w2:t3","name":"db-role","cwd":"${wt_root}/shop/task/aaa111","agent_status":"idle","terminal_title_stripped":"DesignDoc app DB role"},
 {"pane_id":"w2:p4","tab_id":"w2:t4","cwd":"${wt_root}/shop/task/bbb222","agent_status":"working","terminal_title_stripped":"Herdr standby worker"},
 {"pane_id":"w3:p1","tab_id":"w3:t1","name":"fix-ci","cwd":"${wt_root}/api/task/ccc333","agent_status":"blocked","terminal_title":"CI\tflake"}
]}}
JSON
  ;;
  "tab list") echo '{"result":{"tabs":[{"tab_id":"w2:t3","label":"app DB role"},{"tab_id":"w3:t1","label":"fix ci"}]}}' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${stub_bin}/herdr"

  list="${repo_root}/scripts/list-workers.sh"
}

teardown() {
  common_teardown
}

@test "lists only task-worktree agents, with tab labels joined in" {
  rc=0
  out="$("${list}")" || rc=$?
  expect_rc "exit 0" "${rc}" 0
  expect_eq "three workers" "$(wc -l <<< "${out}" | tr -d ' ')" "3"
  expect_not_grep "orchestrator excluded" "${out}" "w1:p1"
  expect_grep "named worker row" "${out}" $'w2:p3\tdb-role\tshop\tidle\tapp DB role\tDesignDoc app DB role'
  expect_grep "unnamed worker and missing tab label" "${out}" $'w2:p4\t-\tshop\tworking\t-\tHerdr standby worker'
  expect_grep "title falls back, tabs flattened" "${out}" $'w3:p1\tfix-ci\tapi\tblocked\tfix ci\tCI flake'
}

@test "query words narrow the list" {
  out="$("${list}" DB)"
  expect_eq "case-insensitive single match" "${out%%$'\t'*}" "w2:p3"
  out="$("${list}" shop working)"
  expect_eq "all words must match" "${out%%$'\t'*}" "w2:p4"
}

@test "no match exits 1 and explains" {
  run "${list}" nothing-here
  expect_rc "no match -> exit 1" "${status}" nz
  expect_grep "explains" "${output}" "No worker matches: nothing-here"
}

@test "workers on other machines: remote rows, ensure, unreachable warning" {
  stub_machines
  rc=0
  out="$("${list}" 2>"${t}/err")" || rc=$?
  expect_rc "exit 0 with an unreachable machine" "${rc}" 0
  expect_eq "local and remote rows" "$(wc -l <<< "${out}" | tr -d ' ')" "5"
  expect_grep "remote row prefixed with its label" "${out}" $'box/w5:p2\tapi-fix\tapi\tidle'
  expect_grep "remote lists its own workers only" "$(cat "${d}/calls")" "exec box-ssh -- scripts/list-workers.sh --local"
  expect_grep "a stopped machine is ensured" "$(cat "${d}/calls")" "ensure back-ssh"
  expect_grep "its workers after the restart" "${out}" $'back/w1:p1\tdb\tshop'
  expect_not_grep "no warning once back" "$(cat "${t}/err")" "machine back"
  expect_grep "unreachable machine warned" "$(cat "${t}/err")" "could not list workers on machine down"
  for m in box-ssh down-ssh back-ssh; do
    expect_grep "every machine tried (no input eaten): ${m}" "$(cat "${d}/calls")" "exec ${m} --"
  done
  expect_eq "a failed ensure is not retried" "$(grep -c '^exec down-ssh' "${d}/calls")" "1"
}

@test "workers on other machines: a query reaches remote rows" {
  stub_machines
  out="$("${list}" api-fix 2>/dev/null)"
  expect_eq "query reaches remote rows" "${out%%$'\t'*}" "box/w5:p2"
}

@test "--local lists this herdr only, without calling the plugin" {
  stub_machines
  : > "${d}/calls"
  out="$("${list}" --local)"
  expect_eq "--local: local rows only" "$(wc -l <<< "${out}" | tr -d ' ')" "3"
  expect_eq "--local: no plugin call" "$(wc -c < "${d}/calls" | tr -d ' ')" "0"
}

@test "without a plugin only this herdr is listed, without warnings" {
  stub_machines
  rm -rf "${HW_PLUGINS_DIR}"
  out="$("${list}" 2>"${t}/err")"
  expect_eq "no plugin: this herdr only" "$(wc -l <<< "${out}" | tr -d ' ')" "3"
  expect_eq "no plugin: no warning" "$(wc -c < "${t}/err" | tr -d ' ')" "0"
}

@test "split layout without WORKTREE_LAB_DIR: the lab is the checkout's parent holding repos/" {
  # <lab>/herdr-worktree is the checkout; repos/ and worktree/ sit next to it
  mkdir -p "${lab}/herdr-worktree"
  cp -R "${repo_root}/scripts" "${lab}/herdr-worktree/scripts"
  unset WORKTREE_LAB_DIR
  rc=0
  out="$("${lab}/herdr-worktree/scripts/list-workers.sh")" || rc=$?
  expect_rc "exit 0" "${rc}" 0
  expect_eq "the lab's three workers" "$(wc -l <<< "${out}" | tr -d ' ')" "3"
}
