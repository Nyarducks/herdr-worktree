#!/usr/bin/env bats
# plugins.bats — scripts/plugins.sh: enabling a plugin by path links it
# under HW_PLUGINS_DIR after its describe answers contract 1 and links its
# skills under HW_SKILLS_DIR, ls shows it, machines lists what it provides,
# disable removes only the links, and a plugin with another contract, no
# hw-plugin, or a skill clashing with an existing one is refused.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load helpers

# make_plugin <dir> <id> <contract> [skill-name…] — a plugin directory outside
# the checkout; each skill is skills/<name>/SKILL.md, described by a relative
# path
make_plugin() {
  local dir="$1" id="$2" contract="$3" skills="" s
  shift 3
  for s in "$@"; do
    mkdir -p "${dir}/skills/${s}"
    printf -- '---\nname: %s\ndescription: x\n---\n' "${s}" > "${dir}/skills/${s}/SKILL.md"
    skills+="${skills:+,}\"skills/${s}\""
  done
  mkdir -p "${dir}/bin"
  cat > "${dir}/bin/hw-plugin" <<EOF
#!/usr/bin/env bash
case "\$1" in
  describe) echo '{"id":"${id}","name":"Fake ${id}","version":"1.2.3","contract":${contract},"skills":[${skills}]}' ;;
  machines) echo '[{"label":"vm","target":"vm-1","dir":"~/hw","registered":true}]' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "${dir}/bin/hw-plugin"
}

setup() {
  common_setup
  export HW_PLUGINS_DIR="${t}/enabled"
  export HW_SKILLS_DIR="${t}/skills"
  mkdir -p "${HW_SKILLS_DIR}/core-skill"
  printf -- '---\nname: core-skill\ndescription: x\n---\n' > "${HW_SKILLS_DIR}/core-skill/SKILL.md"
  plugins="${repo_root}/scripts/plugins.sh"
  make_plugin "${t}/src/fake" fake 1 fake-ops fake-setup
  make_plugin "${t}/src/clash" clash 1 core-skill
  make_plugin "${t}/src/old" old 0
  mkdir -p "${t}/src/empty"
}

teardown() {
  common_teardown
}

@test "arguments: no command or a missing plugin exits 1" {
  run "${plugins}"
  expect_rc "no command -> exit 1" "${status}" nz
  run "${plugins}" enable "${t}/nowhere"
  expect_rc "missing plugin -> exit 1" "${status}" nz
}

@test "enable by path links the plugin and its skills; ls shows it" {
  run "${plugins}" enable "${t}/src/fake"
  expect_rc "enable exits 0" "${status}" 0
  expect_grep "reports the plugin" "${output}" "fake: enabled (Fake fake;"
  expect_eq "linked by its id" "$(readlink "${HW_PLUGINS_DIR}/fake")" "$(cd "${t}/src/fake" && pwd -P)"
  run "${plugins}" enable "${t}/src/fake"
  expect_rc "enabling again is fine" "${status}" 0

  expect_eq "skills linked by name" "$(readlink "${HW_SKILLS_DIR}/plugin-fake-fake-ops")" "$(cd "${t}/src/fake" && pwd -P)/skills/fake-ops"
  expect_file "second skill linked" "${HW_SKILLS_DIR}/plugin-fake-fake-setup/SKILL.md" exists

  ls_out="$("${plugins}" ls)"
  expect_grep "ls shows it enabled with its version" "${ls_out}" $'fake\tyes\t1.2.3'
}

@test "machines lists the enabled plugin's machines" {
  "${plugins}" enable "${t}/src/fake" >/dev/null
  expect_eq "machines lists the plugin's machines" "$("${plugins}" machines)" $'fake\tvm\tvm-1'
}

@test "refused: another contract, no hw-plugin, a clashing skill" {
  run "${plugins}" enable "${t}/src/old"
  expect_rc "another contract -> exit 1" "${status}" nz
  expect_grep "names the contract" "${output}" "speaks contract '0', this checkout needs 1"
  run "${plugins}" enable "${t}/src/empty"
  expect_rc "no hw-plugin -> exit 1" "${status}" nz
  expect_grep "explains" "${output}" "has no executable bin/hw-plugin"
  expect_file "nothing linked for a refused plugin" "${HW_PLUGINS_DIR}/old" absent
  run "${plugins}" enable "${t}/src/clash"
  expect_rc "skill clashing with a core skill -> exit 1" "${status}" nz
  expect_grep "names the clash" "${output}" "skill 'core-skill' clashes with"
  expect_file "clashing plugin not linked" "${HW_PLUGINS_DIR}/clash" absent
  expect_file "clashing skill not linked" "${HW_SKILLS_DIR}/plugin-clash-core-skill" absent
}

@test "disable removes only the links" {
  "${plugins}" enable "${t}/src/fake" >/dev/null
  run "${plugins}" disable fake
  expect_rc "disable exits 0" "${status}" 0
  expect_file "link removed" "${HW_PLUGINS_DIR}/fake" absent
  expect_file "skill links removed" "${HW_SKILLS_DIR}/plugin-fake-fake-ops" absent
  expect_file "core skill kept" "${HW_SKILLS_DIR}/core-skill/SKILL.md" exists
  expect_file "plugin itself kept" "${t}/src/fake/bin/hw-plugin" exists
  run "${plugins}" disable fake
  expect_rc "disabling a disabled plugin -> exit 1" "${status}" nz
  expect_eq "no machines without plugins" "$("${plugins}" machines)" ""
}

@test "skill_name (sourced): the frontmatter name, empty without one" {
  # shellcheck source=scripts/plugins.sh
  source "${repo_root}/scripts/plugins.sh"
  mkdir -p "${t}/s1" "${t}/s2"
  printf -- '---\nname: "quoted-name"\ndescription: x\n---\nname: body\n' > "${t}/s1/SKILL.md"
  printf 'no frontmatter\nname: x\n' > "${t}/s2/SKILL.md"
  expect_eq "frontmatter name, quotes dropped" "$(skill_name "${t}/s1")" "quoted-name"
  expect_eq "no frontmatter -> empty" "$(skill_name "${t}/s2")" ""
}

@test "plugins a and a-b keep each other's skill links" {
  make_plugin "${t}/src/a-b" a-b 1 s-a-b
  make_plugin "${t}/src/a" a 1 s-a
  "${plugins}" enable "${t}/src/a-b" >/dev/null
  "${plugins}" enable "${t}/src/a" >/dev/null
  expect_file "a-b's link kept when a is enabled" "${HW_SKILLS_DIR}/plugin-a-b-s-a-b/SKILL.md" exists
  expect_file "a's link made" "${HW_SKILLS_DIR}/plugin-a-s-a/SKILL.md" exists
  "${plugins}" enable "${t}/src/a" >/dev/null
  expect_file "re-enabling a keeps a-b's link" "${HW_SKILLS_DIR}/plugin-a-b-s-a-b/SKILL.md" exists
  "${plugins}" disable a >/dev/null
  expect_file "disabling a removes a's link" "${HW_SKILLS_DIR}/plugin-a-s-a" absent
  expect_file "disabling a keeps a-b's link" "${HW_SKILLS_DIR}/plugin-a-b-s-a-b/SKILL.md" exists
}

@test "ls and disable use the describe id when the directory is named otherwise" {
  make_plugin "${t}/src/my-plugin" buildbox 1
  "${plugins}" enable "${t}/src/my-plugin" >/dev/null
  expect_grep "listed as enabled under its id" "$("${plugins}" ls)" $'buildbox\tyes\t1.2.3'
  run "${plugins}" disable buildbox
  expect_rc "disable by id" "${status}" 0
  expect_file "link removed" "${HW_PLUGINS_DIR}/buildbox" absent
}

@test "re-enabling a plugin moved elsewhere replaces its old skill links" {
  make_plugin "${t}/src/pp" pp 1 sk
  "${plugins}" enable "${t}/src/pp" >/dev/null
  mv "${t}/src/pp" "${t}/src/pp2"
  run "${plugins}" enable "${t}/src/pp2"
  expect_rc "enable from the new place" "${status}" 0
  expect_eq "skill link points to the new place" "$(readlink "${HW_SKILLS_DIR}/plugin-pp-sk")" "$(cd "${t}/src/pp2" && pwd -P)/skills/sk"
  expect_eq "plugin link points to the new place" "$(readlink "${HW_PLUGINS_DIR}/pp")" "$(cd "${t}/src/pp2" && pwd -P)"
}

@test "a skill outside the plugin directory is re-enabled and disabled cleanly" {
  mkdir -p "${t}/shared/sk"
  printf -- '---\nname: sk\ndescription: x\n---\n' > "${t}/shared/sk/SKILL.md"
  make_plugin "${t}/src/pp" pp 1
  sed -i.bak "s|\"skills\":\[\]|\"skills\":[\"${t}/shared/sk\"]|" "${t}/src/pp/bin/hw-plugin"
  "${plugins}" enable "${t}/src/pp" >/dev/null
  expect_file "linked" "${HW_SKILLS_DIR}/plugin-pp-sk/SKILL.md" exists
  run "${plugins}" enable "${t}/src/pp"
  expect_rc "enabling again is no clash with its own link" "${status}" 0
  "${plugins}" disable pp >/dev/null
  expect_file "disable removes it" "${HW_SKILLS_DIR}/plugin-pp-sk" absent
  expect_file "the skill itself kept" "${t}/shared/sk/SKILL.md" exists
}

@test "another plugin's link of the same name, even dangling, refuses the enable" {
  make_plugin "${t}/src/a-b" a-b 1 x
  make_plugin "${t}/src/a" a 1 b-x
  "${plugins}" enable "${t}/src/a-b" >/dev/null
  rm -rf "${t}/src/a-b/skills/x"
  run "${plugins}" enable "${t}/src/a"
  expect_rc "refused" "${status}" nz
  expect_grep "names the link" "${output}" "clashes with ${HW_SKILLS_DIR}/plugin-a-b-x"
  expect_file "a not linked" "${HW_PLUGINS_DIR}/a" absent
}

@test "a skill outside the plugin is still its own when the skills dir is spelled otherwise" {
  mkdir -p "${t}/shared/sk"
  printf -- '---\nname: sk\ndescription: x\n---\n' > "${t}/shared/sk/SKILL.md"
  make_plugin "${t}/src/pp" pp 1
  sed -i.bak "s|\"skills\":\[\]|\"skills\":[\"${t}/shared/sk\"]|" "${t}/src/pp/bin/hw-plugin"
  "${plugins}" enable "${t}/src/pp" >/dev/null
  ln -s "${t}" "${t}/alias"
  HW_SKILLS_DIR="${t}/alias/skills" run "${plugins}" enable "${t}/src/pp"
  expect_rc "re-enable through another spelling" "${status}" 0
  expect_file "still linked" "${HW_SKILLS_DIR}/plugin-pp-sk/SKILL.md" exists
}

@test "a stale record never removes another plugin's link of the same name" {
  make_plugin "${t}/src/a" a 1 b-x
  make_plugin "${t}/src/a-b" a-b 1 x
  "${plugins}" enable "${t}/src/a" >/dev/null
  rm "${HW_SKILLS_DIR}"/plugin-*
  "${plugins}" enable "${t}/src/a-b" >/dev/null
  run "${plugins}" enable "${t}/src/a"
  expect_rc "a's re-enable clashes with a-b's link" "${status}" nz
  expect_eq "a-b's link untouched" "$(readlink "${HW_SKILLS_DIR}/plugin-a-b-x")" "$(cd "${t}/src/a-b" && pwd -P)/skills/x"
  "${plugins}" disable a >/dev/null
  expect_eq "disabling a keeps a-b's link" "$(readlink "${HW_SKILLS_DIR}/plugin-a-b-x")" "$(cd "${t}/src/a-b" && pwd -P)/skills/x"
}
