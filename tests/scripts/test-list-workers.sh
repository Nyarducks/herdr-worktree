#!/usr/bin/env bash
# test-list-workers.sh — scripts/list-workers.sh with a stubbed herdr:
# only agents in task worktrees are listed, with tab labels joined in, and
# query words narrow the list (no match exits 1).
set -uo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

echo "== lists only task-worktree agents =="

out="$("${list}")"
expect_rc "exit 0" "$?" 0
expect_eq "three workers" "$(wc -l <<< "${out}" | tr -d ' ')" "3"
expect_not_grep "orchestrator excluded" "${out}" "w1:p1"
expect_grep "named worker row" "${out}" $'w2:p3\tdb-role\tshop\tidle\tapp DB role\tDesignDoc app DB role'
expect_grep "unnamed worker and missing tab label" "${out}" $'w2:p4\t-\tshop\tworking\t-\tHerdr standby worker'
expect_grep "title falls back, tabs flattened" "${out}" $'w3:p1\tfix-ci\tapi\tblocked\tfix ci\tCI flake'

echo "== query narrows =="

out="$("${list}" DB)"
expect_eq "case-insensitive single match" "${out%%$'\t'*}" "w2:p3"
out="$("${list}" shop working)"
expect_eq "all words must match" "${out%%$'\t'*}" "w2:p4"

echo "== no match =="

err="$("${list}" nothing-here 2>&1)"
expect_rc "no match -> exit 1" "$?" nz
expect_grep "explains" "${err}" "No worker matches: nothing-here"

echo ""
printf 'passed: %d  failed: %d\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
