#!/usr/bin/env bats
# plugins.bats (lib) — scripts/lib/plugins.sh: finding enabled plugins and
# their machines, and calling the contract.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load ../helpers

setup() {
  common_setup
  # shellcheck source=scripts/lib/plugins.sh
  source "${repo_root}/scripts/lib/plugins.sh"
}

teardown() {
  common_teardown
}

@test "no plugin enabled: no bins, no machines, nothing found" {
  expect_eq "no bins" "$(hw_plugin_bins)" ""
  expect_eq "no machines" "$(hw_plugin_machines)" ""
  expect_eq "nothing found" "$(hw_plugin_find box)" ""
}

@test "machines and find by label or target" {
  stub_plugin vm
  echo '[{"label":"box","target":"box-ssh","dir":"~/hw","registered":true}]' > "${PLUGIN_STUB}/vm/machines.json"
  local bin="${HW_PLUGINS_DIR}/vm/bin/hw-plugin"
  expect_eq "bins" "$(hw_plugin_bins)" "${bin}"
  expect_eq "machines" "$(hw_plugin_machines)" "${bin}"$'\tbox\tbox-ssh'
  expect_eq "by label" "$(hw_plugin_find box)" "${bin}"$'\tbox\tbox-ssh'
  expect_eq "by target" "$(hw_plugin_find box-ssh)" "${bin}"$'\tbox\tbox-ssh'
}

@test "exec closes stdin and passes the command; ensure reports failure" {
  stub_plugin vm
  echo hello > "${PLUGIN_STUB}/vm/exec-box-ssh"
  local bin="${HW_PLUGINS_DIR}/vm/bin/hw-plugin"
  expect_eq "exec output" "$(echo eaten | hw_plugin_exec "${bin}" box-ssh scripts/x.sh a)" "hello"
  expect_eq "argv" "$(tr '\n' ' ' < "${PLUGIN_STUB}/vm/last-argv")" "exec box-ssh -- scripts/x.sh a "
  echo 1 > "${PLUGIN_STUB}/vm/ensure-box-ssh"
  run hw_plugin_ensure "${bin}" box-ssh
  expect_rc "ensure failure" "${status}" nz
}

@test "find reads every plugin's machines: no SIGPIPE under pipefail with two plugins" {
  stub_plugin p1
  stub_plugin p2
  echo '[{"label":"m-p1","target":"t-p1","dir":"~/hw","registered":true}]' > "${PLUGIN_STUB}/p1/machines.json"
  echo '[{"label":"m-p2","target":"t-p2","dir":"~/hw","registered":true}]' > "${PLUGIN_STUB}/p2/machines.json"
  # p2 answers late, after find already saw p1's machine
  local bin2="${HW_PLUGINS_DIR}/p2/bin/hw-plugin"
  mv "${bin2}" "${bin2}.real"
  # $1 and $@ belong to the generated script — single quotes are intentional
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[[ "$1" == machines ]] && sleep 0.3\nexec "%s" "$@"\n' "${bin2}.real" > "${bin2}"
  chmod +x "${bin2}"
  local found rc=0
  found="$(set -o pipefail; hw_plugin_find m-p1)" || rc=$?
  expect_rc "no failure" "${rc}" 0
  expect_eq "first plugin's machine" "${found}" "${HW_PLUGINS_DIR}/p1/bin/hw-plugin"$'\tm-p1\tt-p1'
}

@test "find prefers a target over another machine's label" {
  stub_plugin vm
  # hw-a (listed first) is labelled hw-b; hw-b is labelled bee
  echo '[{"label":"hw-b","target":"hw-a","dir":"~/hw","registered":true},{"label":"bee","target":"hw-b","dir":"~/hw","registered":true}]' > "${PLUGIN_STUB}/vm/machines.json"
  expect_eq "target wins" "$(hw_plugin_find hw-b | cut -f3)" "hw-b"
  expect_eq "label still found" "$(hw_plugin_find bee | cut -f3)" "hw-b"
}

@test "find by a label holding a backslash" {
  stub_plugin vm
  printf '%s' '[{"label":"lab\\1","target":"t1"},{"label":"dev&1\\x|y","target":"t2"}]' > "${PLUGIN_STUB}/vm/machines.json"
  local bin="${HW_PLUGINS_DIR}/vm/bin/hw-plugin"
  expect_eq "label with \\1" "$(hw_plugin_find 'lab\1')" "${bin}"$'\tlab\\1\tt1'
  expect_eq "label with \\x" "$(hw_plugin_find 'dev&1\x|y')" "${bin}"$'\tdev&1\\x|y\tt2'
}

@test "machines skip a label or target that would break the rows" {
  stub_plugin vm
  printf '%s' '[{"label":"tab\there","target":"t1"},{"label":"a b","target":"t2"},{"label":"x/y","target":"t3"},{"label":"ok","target":null},{"label":"good","target":"t5"}]' > "${PLUGIN_STUB}/vm/machines.json"
  local bin="${HW_PLUGINS_DIR}/vm/bin/hw-plugin" out
  out="$(hw_plugin_machines 2>"${t}/err")"
  expect_eq "only the usable machine" "${out}" "${bin}"$'\tgood\tt5'
  expect_eq "each skipped one reported" "$(grep -c 'unusable label or target' "${t}/err")" "4"
  expect_eq "the split label is not found" "$(hw_plugin_find here 2>/dev/null)" ""
}

@test "find compares names as strings, not numbers" {
  stub_plugin vm
  printf '%s' '[{"label":"01","target":"box-a"},{"label":"1","target":"box-b"},{"label":"n","target":"nan"}]' > "${PLUGIN_STUB}/vm/machines.json"
  local bin="${HW_PLUGINS_DIR}/vm/bin/hw-plugin"
  expect_eq "1 is not 01" "$(hw_plugin_find 1)" "${bin}"$'\t1\tbox-b'
  expect_eq "01 is not 1" "$(hw_plugin_find 01)" "${bin}"$'\t01\tbox-a'
  expect_eq "nan matches only nan" "$(hw_plugin_find nan)" "${bin}"$'\tn\tnan'
  expect_eq "a number never matches nan" "$(hw_plugin_find 16)" ""
}
