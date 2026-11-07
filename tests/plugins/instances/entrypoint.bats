#!/usr/bin/env bats
# entrypoint.bats — plugins/instances/docker/default/entrypoint.sh: the paths
# it keeps in the state volume (link_persisted). getent, chown and runuser
# are stubbed so it runs as the current user on any machine.

# common_setup (helpers.bash) assigns repo_root, t and stub_bin; shellcheck
# does not follow bats `load`.
# shellcheck disable=SC2154
load ../../scripts/helpers

setup() {
  common_setup
  home="${t}/home"
  mkdir -p "${home}/.persist"
  printf '#!/usr/bin/env bash\necho "dev:x:1000:1000::%s:/bin/bash"\n' "${home}" > "${stub_bin}/getent"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/chown.log"\n' "${t}" > "${stub_bin}/chown"
  # runuser -u <user> -- <command…>
  printf '#!/usr/bin/env bash\nshift 3\nexec "$@"\n' > "${stub_bin}/runuser"
  chmod +x "${stub_bin}/getent" "${stub_bin}/chown" "${stub_bin}/runuser"
  export HW_PERSIST_LIST="${t}/persist"
  # shellcheck source=plugins/instances/docker/default/entrypoint.sh
  source "${repo_root}/plugins/instances/docker/default/entrypoint.sh"
}

teardown() {
  common_teardown
}

@test "a listed path becomes a link into the volume; what the image put there moves in once" {
  mkdir -p "${home}/.config/gh"
  echo token > "${home}/.config/gh/hosts.yml"
  printf '.config   # gh\n' > "${HW_PERSIST_LIST}"
  link_persisted
  expect_eq "linked" "$(readlink "${home}/.config")" "${home}/.persist/.config"
  expect_eq "moved in" "$(cat "${home}/.persist/.config/gh/hosts.yml")" "token"
  link_persisted
  expect_eq "a second start keeps it" "$(cat "${home}/.config/gh/hosts.yml")" "token"
}

@test "the volume and the record are given to the user and the user's group" {
  printf '.claude\n' > "${HW_PERSIST_LIST}"
  link_persisted
  # uutils chown (Ubuntu 26.04) leaves the group alone on `user:`
  expect_eq "both chowned with the gid" "$(sort -u "${t}/chown.log")" \
    "$(printf 'dev:1000 %s\ndev:1000 %s' "${home}/.persist" "${home}/.persist/persist.linked" | sort -u)"
}

@test "a path under one already kept is skipped, never deleted" {
  mkdir -p "${home}/.config/gh"
  echo token > "${home}/.config/gh/hosts.yml"
  printf '.config\n' > "${HW_PERSIST_LIST}"
  link_persisted
  printf '.config/gh\n' > "${home}/.persist/persist.list"
  run link_persisted
  expect_rc "start succeeds" "${status}" 0
  expect_grep "says why" "${output}" "persist: '.config/gh' is already kept through a parent path"
  expect_eq "the login survives" "$(cat "${home}/.config/gh/hosts.yml")" "token"
  expect_file "no link to itself" "${home}/.persist/.config/gh/hosts.yml" exists
}

@test "a child listed before its parent: the parent still moves in whole" {
  mkdir -p "${home}/.config/herdr" "${home}/.config/gh"
  echo image > "${home}/.config/herdr/config.toml"
  echo token > "${home}/.config/gh/hosts.yml"
  printf '.config/gh\n.config\n' > "${HW_PERSIST_LIST}"
  run link_persisted
  expect_rc "start succeeds" "${status}" 0
  expect_eq ".config linked" "$(readlink "${home}/.config")" "${home}/.persist/.config"
  expect_eq "the image's file kept" "$(cat "${home}/.config/herdr/config.toml")" "image"
  expect_eq "the login kept" "$(cat "${home}/.config/gh/hosts.yml")" "token"
}

@test "a parent listed after its child was kept: what the image put there is merged in" {
  mkdir -p "${home}/.local/bin" "${home}/.local/state/nix/profiles" "${home}/.local/state/other"
  echo claude > "${home}/.local/bin/claude"
  echo profile > "${home}/.local/state/nix/profiles/p"
  echo other > "${home}/.local/state/other/x"
  printf '.local/state/nix\n' > "${HW_PERSIST_LIST}"
  link_persisted
  printf '.local\n' > "${home}/.persist/persist.list"
  run link_persisted
  expect_rc "start succeeds" "${status}" 0
  expect_eq ".local linked" "$(readlink "${home}/.local")" "${home}/.persist/.local"
  expect_eq "the image's file kept" "$(cat "${home}/.local/bin/claude")" "claude"
  expect_eq "the child's data kept" "$(cat "${home}/.local/state/nix/profiles/p")" "profile"
  expect_eq "the image's file beside the child kept" "$(cat "${home}/.local/state/other/x")" "other"
  expect_eq "no link left inside the volume" "$(find "${home}/.persist" -type l | wc -l | tr -d ' ')" "0"
  # a rebuild puts the image's copy back; now the volume's copy wins
  rm "${home}/.local"
  mkdir -p "${home}/.local/bin"
  echo new > "${home}/.local/bin/claude"
  echo image > "${home}/.local/bin/extra"
  run link_persisted
  expect_rc "next start succeeds" "${status}" 0
  expect_eq "the volume's copy wins" "$(cat "${home}/.local/bin/claude")" "claude"
  expect_file "nothing merged after the first use" "${home}/.local/bin/extra" absent
}

# lost_then_parent <volume path> — keep .local/state/nix, lose <volume path>
# from the volume, then add .local: no link may be left inside the volume
lost_then_parent() {
  mkdir -p "${home}/.local/bin" "${home}/.local/state/other"
  echo claude > "${home}/.local/bin/claude"
  echo other > "${home}/.local/state/other/x"
  printf '.local/state/nix\n' > "${HW_PERSIST_LIST}"
  link_persisted
  rm -rf "${home}/.persist/$1"
  printf '.local\n' > "${home}/.persist/persist.list"
  link_persisted # a failure fails the test
  expect_eq "the image's file kept" "$(cat "${home}/.local/bin/claude")" "claude"
  expect_eq "the image's file beside the child kept" "$(cat "${home}/.local/state/other/x")" "other"
  expect_eq "no link left inside the volume" "$(find "${home}/.persist" -type l | wc -l | tr -d ' ')" "0"
}

@test "merging a parent drops a child's link whose data the volume lost" {
  lost_then_parent .local/state/nix
}

@test "merging a parent drops a child's link when the volume lost a directory above it" {
  lost_then_parent .local/state
}

@test "moving a parent in drops a child's link when the volume lost the parent" {
  lost_then_parent .local
}

@test "a user's own link into another kept path survives a parent's first use" {
  printf '.claude\n' > "${HW_PERSIST_LIST}"
  link_persisted
  mkdir -p "${home}/.local/bin" "${home}/.persist/.claude/bin"
  echo tool > "${home}/.persist/.claude/bin/tool"
  ln -s "${home}/.persist/.claude/bin/tool" "${home}/.local/bin/tool"
  printf '.local\n' > "${home}/.persist/persist.list"
  link_persisted
  expect_eq "the link still works" "$(cat "${home}/.local/bin/tool")" "tool"
}

@test "a user's own link survives where a parent is merged" {
  mkdir -p "${home}/.local/state/nix"
  printf '.claude\n.local/state/nix\n' > "${HW_PERSIST_LIST}"
  link_persisted
  mkdir -p "${home}/.persist/.claude/bin"
  echo tool > "${home}/.persist/.claude/bin/tool"
  ln -s "${home}/.persist/.claude/bin/tool" "${home}/.local/state/tool"
  printf '.local\n' > "${home}/.persist/persist.list"
  link_persisted
  expect_eq "the link still works" "$(cat "${home}/.local/state/tool")" "tool"
}

@test "a listed path that is a file is refused: paths are directories" {
  echo '[user]' > "${home}/.gitconfig"
  printf '.gitconfig\n.claude\n' > "${HW_PERSIST_LIST}"
  run link_persisted
  expect_rc "start succeeds" "${status}" 0
  expect_grep "says why" "${output}" "persist: skipped '.gitconfig' (a file; list its directory instead)"
  expect_eq "the file untouched" "$(cat "${home}/.gitconfig")" "[user]"
  expect_file "not moved into the volume" "${home}/.persist/.gitconfig" absent
  expect_eq "the rest still linked" "$(readlink "${home}/.claude")" "${home}/.persist/.claude"
}

@test "a listed path that links elsewhere is refused, and the link left alone" {
  echo '[user]' > "${t}/gitconfig"
  ln -s "${t}/gitconfig" "${home}/.gitconfig"
  mkdir -p "${t}/dots/git" "${home}/.config"
  echo dots > "${t}/dots/git/config"
  ln -s "${t}/dots/git" "${home}/.config/git"
  printf '.gitconfig\n.config/git\n' > "${HW_PERSIST_LIST}"
  run link_persisted
  expect_rc "start succeeds" "${status}" 0
  expect_grep "file link: says why" "${output}" "persist: skipped '.gitconfig' (a link elsewhere; left as it is)"
  expect_grep "dir link: says why" "${output}" "persist: skipped '.config/git' (a link elsewhere; left as it is)"
  expect_eq "file link untouched" "$(readlink "${home}/.gitconfig")" "${t}/gitconfig"
  expect_eq "dir link untouched" "$(readlink "${home}/.config/git")" "${t}/dots/git"
  expect_file "nothing made in the volume" "${home}/.persist/.config/git" absent
}

@test "a stale link into the volume is replaced by the path's own" {
  mkdir -p "${home}/.persist/.claude-old"
  ln -s "${home}/.persist/.claude-old" "${home}/.claude"
  printf '.claude\n' > "${HW_PERSIST_LIST}"
  run link_persisted
  expect_rc "start succeeds" "${status}" 0
  expect_eq "relinked" "$(readlink "${home}/.claude")" "${home}/.persist/.claude"
  expect_file "the old directory kept" "${home}/.persist/.claude-old" exists
}

@test "a record that cannot be written is reported; the start goes on under set -e" {
  mkdir -p "${home}/.persist/persist.linked"
  printf '.claude\n' > "${HW_PERSIST_LIST}"
  run bash -c 'set -euo pipefail; source "$1"; link_persisted' _ \
    "${repo_root}/plugins/instances/docker/default/entrypoint.sh"
  expect_rc "start succeeds" "${status}" 0
  expect_grep "says so" "${output}" "persist: cannot record '.claude'"
  expect_eq "still linked" "$(readlink "${home}/.claude")" "${home}/.persist/.claude"
}

@test "a path that cannot be linked is reported; the start goes on under set -e" {
  echo 'export X=1' > "${home}/.profile"
  printf '.profile/sub\n.zz\n' > "${HW_PERSIST_LIST}"
  run bash -c 'set -euo pipefail; source "$1"; link_persisted' _ \
    "${repo_root}/plugins/instances/docker/default/entrypoint.sh"
  expect_rc "start succeeds" "${status}" 0
  expect_grep "says which" "${output}" "persist: '.profile/sub' could not be linked; left as it is"
  expect_eq "the next path still linked" "$(readlink "${home}/.zz")" "${home}/.persist/.zz"
  expect_file "record written" "${home}/.persist/persist.linked" exists
  expect_not_grep "only the linked one recorded" "$(cat "${home}/.persist/persist.linked")" ".profile/sub"
}

@test "a restart that cannot recreate a lost path reports it and goes on" {
  printf '.claude\n.zz\n' > "${HW_PERSIST_LIST}"
  link_persisted
  rm -rf "${home}/.persist/.claude" "${home}/.persist/.zz" "${home}/.persist/persist.linked"
  ln -s "${t}/nowhere" "${home}/.persist/.claude"
  run bash -c 'set -euo pipefail; source "$1"; link_persisted' _ \
    "${repo_root}/plugins/instances/docker/default/entrypoint.sh"
  expect_rc "start succeeds" "${status}" 0
  expect_grep "says which" "${output}" "persist: '.claude' could not be linked; left as it is"
  expect_file "the next path recreated" "${home}/.persist/.zz" exists
}

@test "a kept path the volume lost is recreated on a restart" {
  printf '.claude\n' > "${HW_PERSIST_LIST}"
  link_persisted
  rm -rf "${home}/.persist/.claude"
  link_persisted
  expect_file "recreated in the volume" "${home}/.persist/.claude" exists
  mkdir -p "${home}/.claude/projects"
}

@test "a path linked before the record existed is recorded on the next start" {
  printf '.local\n' > "${HW_PERSIST_LIST}"
  link_persisted
  rm "${home}/.persist/persist.linked"
  link_persisted
  # a rebuild puts the image's copy back
  rm "${home}/.local"
  mkdir -p "${home}/.local/bin"
  echo image > "${home}/.local/bin/extra"
  run link_persisted
  expect_rc "start succeeds" "${status}" 0
  expect_file "not a first use any more" "${home}/.local/bin/extra" absent
}

@test "a list without a final newline keeps its last path, in both lists" {
  printf '.claude\n.codex' > "${HW_PERSIST_LIST}"
  printf '.gh-extra' > "${home}/.persist/persist.list"
  run link_persisted
  expect_rc "start succeeds" "${status}" 0
  expect_eq ".codex linked" "$(readlink "${home}/.codex")" "${home}/.persist/.codex"
  expect_eq ".gh-extra linked" "$(readlink "${home}/.gh-extra")" "${home}/.persist/.gh-extra"
  expect_file "nothing glued" "${home}/.codex.gh-extra" absent
}

@test "paths outside the home directory are refused" {
  printf '/etc\n../x\n.persist/y\n.\n./\n.config/.\na//b\npersist.list\n.claude\n' > "${HW_PERSIST_LIST}"
  run link_persisted
  expect_rc "start succeeds" "${status}" 0
  expect_eq "each refused" "$(grep -c "must be a path inside the home directory" <<< "${output}")" "8"
  expect_eq "the rest still linked" "$(readlink "${home}/.claude")" "${home}/.persist/.claude"
}
