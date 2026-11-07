#!/usr/bin/env bash
# Usage: plugins.sh ls
#        plugins.sh enable <id-or-path>
#        plugins.sh disable <id>
#        plugins.sh machines
#
# Adds and removes herdr-worktree plugins (ADR-0018). A plugin is a directory
# with an executable bin/hw-plugin speaking the contract in
# scripts/lib/plugins.sh; the plugins shipped here live in plugins/<id>/.
#
#   ls        every plugin under plugins/ and every enabled one, tab-separated:
#             id, enabled (yes/no), version (from describe; - when it cannot
#             answer), path.
#   enable    <id> is plugins/<id>; a path enables a plugin elsewhere (e.g. a
#             separate repository). Installs its Node.js dependencies first
#             when it has a package.json and no node_modules (npm ci
#             --omit=dev), checks `hw-plugin describe` answers contract 1,
#             and links <checkout>/.plugins/<id> to it (git-ignored). Each
#             skill directory its describe names is linked as
#             .agents/skills/plugin-<id>-<skill> (git-ignored), so agents
#             list the plugin's skills next to core's (ADR-0019); a skill
#             whose name a core skill already uses is refused. A plugin
#             whose describe lists the "enable" hook is then called with
#             `hw-plugin enable` (instances: brings back the machines its
#             disable took out of herdr).
#   disable   calls `hw-plugin disable` first when describe lists that hook
#             (instances: takes its machines out of herdr), then removes
#             those links. Nothing else the plugin created is touched (its
#             containers, volumes and manifest stay); enabling it again picks
#             them up. A hook that fails is a warning: the plugin is still
#             enabled or disabled.
#   machines  the machines enabled plugins provide: plugin id, label, target.
#
# HW_PLUGINS_DIR overrides <checkout>/.plugins and HW_SKILLS_DIR
# <checkout>/.agents/skills (tests).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/plugins.sh
source "${SCRIPT_DIR}/lib/plugins.sh"

readonly CONTRACT=1

usage() {
  sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

core_dir() {
  dirname "${SCRIPT_DIR}"
}

# run_hook <id> <plugin dir> <describe json> <hook> — call `hw-plugin <hook>`
# when the plugin's describe lists it; its messages pass through, and a
# failure is a warning
run_hook() {
  local id="$1" dir="$2" json="$3" hook="$4"
  jq -e --arg h "${hook}" '(.hooks // []) | index($h) != null' <<< "${json}" >/dev/null 2>&1 || return 0
  if ! "${dir}/bin/hw-plugin" "${hook}" </dev/null >&2; then
    echo "Warning: ${id}: its ${hook} step failed (see above); it is ${hook}d anyway" >&2
  fi
}

# describe_field <plugin dir> <jq path> — a field of its describe; empty when
# it cannot answer.
describe_field() {
  "$1/bin/hw-plugin" describe </dev/null 2>/dev/null | jq -r "$2 // empty" 2>/dev/null || true
}

skills_root() {
  printf '%s\n' "${HW_SKILLS_DIR:-$(core_dir)/.agents/skills}"
}

# skill_name <skill dir> — the name in its SKILL.md frontmatter; empty when
# there is none.
skill_name() {
  awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
       NR > 1 && /^name:[ \t]*/ { sub(/^name:[ \t]*/, ""); gsub(/["\047]/, ""); print; exit }' "$1/SKILL.md" 2>/dev/null
}

# links_into <plugin dir> — the plugin-* skill links that point into <plugin
# dir> (a physical path), one per line. A link is told by its target, not by
# its name: ids may contain '-', so plugin-a-… could belong to plugin a-b.
links_into() {
  local pdir="$1" link raw target
  [[ -n "${pdir}" ]] || return 0
  for link in "$(skills_root)"/plugin-*; do
    [[ -L "${link}" ]] || continue
    raw="$(readlink "${link}")"
    target="$(cd "${link}" 2>/dev/null && pwd -P)" || target="${raw}"
    if [[ "${target}/" == "${pdir}/"* || "${raw}/" == "${pdir}/"* ]]; then
      printf '%s\n' "${link}"
    fi
  done
  return 0
}

# skills_record <id> — the file listing the skill links plugin <id> made, so
# they are found again after the plugin moves or when a skill lives outside
# the plugin directory: one "<link name>\t<target>" per line. Names, not
# paths, so another spelling of the checkout (a symlinked parent) still
# matches; the target, so a link someone else made since is not taken.
skills_record() {
  printf '%s/.%s.skills\n' "$(hw_plugins_root)" "$1"
}

# recorded_links <id> — the links in plugin <id>'s record that still point
# where it linked them.
recorded_links() {
  local record root name target
  record="$(skills_record "$1")"
  [[ -f "${record}" ]] || return 0
  root="$(skills_root)"
  while IFS=$'\t' read -r name target; do
    [[ -n "${name}" && "${name}" != */* ]] || continue
    if [[ -L "${root}/${name}" && "$(readlink "${root}/${name}")" == "${target}" ]]; then
      printf '%s\n' "${root}/${name}"
    fi
  done < "${record}"
  return 0
}

# own_links <id> <plugin dir> — the skill links plugin <id> made: those in its
# record, and (for links made before records existed) those pointing into
# <plugin dir> or into the directory .plugins/<id> points to.
own_links() {
  local id="$1" pdir="$2" link
  link="$(hw_plugins_root)/${id}"
  {
    recorded_links "${id}"
    links_into "${pdir}"
    if [[ -L "${link}" ]]; then links_into "$(plugin_dir_of "${link}")"; fi
  } | awk 'NF && !seen[$0]++'
}

# unlink_skills <id> <plugin dir> — remove the skill links plugin <id> made
# and its record.
unlink_skills() {
  local link
  while IFS= read -r link; do
    [[ -L "${link}" ]] && rm -f "${link}"
  done < <(own_links "$1" "$2")
  rm -f "$(skills_record "$1")"
}

# plugin_dir_of <link> — the physical directory an enabled plugin's link
# points to (the raw target when the directory is gone).
plugin_dir_of() {
  (cd "$1" 2>/dev/null && pwd -P) || readlink "$1"
}

# link_skills <id> <plugin dir> <describe json> — link each skill the plugin
# describes (a relative path is taken from the plugin dir) and record the
# links; refuses (before linking any) a skill without SKILL.md or one whose
# name a skill not from this plugin already uses.
link_skills() {
  local id="$1" pdir="$2" json="$3" root dir name other own link taken=" " links=()
  root="$(skills_root)"
  own="$(own_links "${id}" "${pdir}")"
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    [[ "${dir}" == /* ]] || dir="${pdir}/${dir}"
    [[ -f "${dir}/SKILL.md" ]] || hw_die "plugin ${id} describes a skill without SKILL.md: ${dir}"
    name="$(skill_name "${dir}")"
    [[ -n "${name}" ]] || name="$(basename "${dir}")"
    for other in "${root}"/*/; do
      other="${other%/}"
      # this plugin's own links (from an earlier enable) do not clash
      [[ -n "${own}" ]] && grep -qxF "${other}" <<< "${own}" && continue
      [[ "$(skill_name "${other}")" == "${name}" || "$(basename "${other}")" == "${name}" ]] &&
        hw_die "plugin ${id}'s skill '${name}' clashes with ${other}"
    done
    [[ "${taken}" == *" ${name} "* ]] && hw_die "plugin ${id} describes the skill '${name}' twice"
    taken+="${name} "
    link="${root}/plugin-${id}-${name}"
    # another plugin's link of the same name (plugin a's b-x and plugin a-b's
    # x), even a dangling one
    if [[ -e "${link}" || -L "${link}" ]] && ! grep -qxF "${link}" <<< "${own}"; then
      hw_die "plugin ${id}'s skill '${name}' clashes with ${link}"
    fi
    links+=("${dir}" "${link}")
  done < <(jq -r '.skills[]? // empty' <<< "${json}")
  unlink_skills "${id}" "${pdir}"
  [[ ${#links[@]} -gt 0 ]] || return 0
  mkdir -p "${root}" "$(hw_plugins_root)"
  local i record
  record="$(skills_record "${id}")"
  for ((i = 0; i < ${#links[@]}; i += 2)); do
    ln -s "${links[i]}" "${links[i + 1]}"
    printf '%s\t%s\n' "$(basename "${links[i + 1]}")" "${links[i]}" >> "${record}"
  done
}

cmd_ls() {
  local root dir id enabled seen=" "
  root="$(hw_plugins_root)"
  for dir in "$(core_dir)"/plugins/*/ "${root}"/*/; do
    [[ -x "${dir}bin/hw-plugin" ]] || continue
    dir="$(cd "${dir}" && pwd -P)"
    [[ "${seen}" == *" ${dir} "* ]] && continue
    seen+="${dir} "
    # the id is what describe says (a plugin enabled by path may sit in a
    # directory named otherwise); the directory name when it cannot answer
    id="$(describe_field "${dir}" .id)"
    id="${id:-$(basename "${dir}")}"
    enabled="no"
    if [[ -L "${root}/${id}" && "$(cd "${root}/${id}" && pwd -P)" == "${dir}" ]]; then
      enabled="yes"
    fi
    local version
    version="$(describe_field "${dir}" .version)"
    printf '%s\t%s\t%s\t%s\n' "${id}" "${enabled}" "${version:--}" "${dir}"
  done
}

cmd_enable() {
  [[ $# -eq 1 ]] || usage
  local arg="$1" dir
  if [[ "${arg}" != */* && -d "$(core_dir)/plugins/${arg}" ]]; then
    dir="$(core_dir)/plugins/${arg}"
  else
    dir="${arg}"
  fi
  [[ -d "${dir}" ]] || hw_die "no plugin '${arg}' (see: plugins.sh ls)"
  dir="$(cd "${dir}" && pwd -P)"
  [[ -x "${dir}/bin/hw-plugin" ]] || hw_die "${dir} has no executable bin/hw-plugin"

  if [[ -f "${dir}/package.json" && ! -d "${dir}/node_modules" ]]; then
    command -v npm >/dev/null 2>&1 || hw_die "${dir} needs Node.js (npm) to install its dependencies"
    echo "installing the dependencies of ${dir} (npm ci --omit=dev) ..." >&2
    (cd "${dir}" && npm ci --omit=dev --no-audit --no-fund >&2) || hw_die "npm ci failed in ${dir}"
  fi

  local json id contract
  json="$("${dir}/bin/hw-plugin" describe </dev/null)" || hw_die "${dir}/bin/hw-plugin describe failed"
  id="$(jq -r '.id // empty' <<< "${json}")"
  contract="$(jq -r '.contract // empty' <<< "${json}")"
  [[ "${id}" =~ ^[a-z][a-z0-9-]*$ ]] || hw_die "plugin at ${dir} describes an invalid id '${id}'"
  [[ "${contract}" == "${CONTRACT}" ]] || hw_die "plugin ${id} speaks contract '${contract}', this checkout needs ${CONTRACT}"

  link_skills "${id}" "${dir}" "${json}"

  local root
  root="$(hw_plugins_root)"
  mkdir -p "${root}"
  if [[ -e "${root}/${id}" || -L "${root}/${id}" ]]; then
    [[ -L "${root}/${id}" ]] || hw_die "${root}/${id} exists and is not a plugin link"
    rm -f "${root}/${id}"
  fi
  ln -s "${dir}" "${root}/${id}"
  echo "${id}: enabled ($(jq -r '.name // empty' <<< "${json}"); ${dir})"
  run_hook "${id}" "${dir}" "${json}" enable
}

cmd_disable() {
  [[ $# -eq 1 ]] || usage
  local link
  link="$(hw_plugins_root)/$1"
  [[ -L "${link}" ]] || hw_die "plugin '$1' is not enabled (see: plugins.sh ls)"
  local dir json
  dir="$(plugin_dir_of "${link}")"
  # a dangling link (the plugin moved away) has nothing to ask; a plugin
  # that is there but cannot describe itself (no Node.js) is a warning
  if [[ -x "${dir}/bin/hw-plugin" ]]; then
    if json="$("${dir}/bin/hw-plugin" describe </dev/null)"; then
      run_hook "$1" "${dir}" "${json}" disable
    else
      echo "Warning: $1: cannot ask it for its disable step (describe failed, see above); what it registered elsewhere (herdr machines) may remain" >&2
    fi
  fi
  unlink_skills "$1" "${dir}"
  rm -f "${link}"
  echo "$1: disabled (its manifest, containers and volumes are kept; enable it again to use them)"
}

cmd_machines() {
  [[ $# -eq 0 ]] || usage
  local bin label target
  while IFS=$'\t' read -r bin label target; do
    printf '%s\t%s\t%s\n' "$(basename "$(dirname "$(dirname "${bin}")")")" "${label}" "${target}"
  done < <(hw_plugin_machines)
}

main() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || usage
  shift
  command -v jq >/dev/null 2>&1 || hw_die "jq not found on PATH"
  case "${cmd}" in
    ls) cmd_ls "$@" ;;
    enable) cmd_enable "$@" ;;
    disable) cmd_disable "$@" ;;
    machines) cmd_machines "$@" ;;
    *) usage ;;
  esac
}

# Run only when executed: tests source this file to call its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
