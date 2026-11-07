#!/usr/bin/env bash
# Entrypoint of the herdr-worktree container: creates the sshd host keys on
# first start (they live in a volume so clients keep trusting them across
# rebuilds), links the persisted paths into the state volume, starts dockerd
# when HW_DOCKER=1, and runs sshd
# in the foreground. With arguments, it runs them instead (e.g.
# `docker compose run --rm dev bash`).

readonly HOST_KEY_DIR="/etc/ssh/host_keys"
# HW_PERSIST_LIST: tests point it at their own list
readonly PERSIST_LIST="${HW_PERSIST_LIST:-/etc/herdr-worktree/persist}"

ensure_host_keys() {
  local type
  for type in ed25519 rsa; do
    if [[ ! -f "${HOST_KEY_DIR}/ssh_host_${type}_key" ]]; then
      ssh-keygen -q -t "${type}" -N '' -f "${HOST_KEY_DIR}/ssh_host_${type}_key"
    fi
  done
}

# move_in <src> <dst> — move src to dst, first dropping each link inside it
# that would point at itself once moved: a kept path's own link
# (.local/state/nix inside .local, when the volume lost .local). Other
# links stay. Runs as the user.
move_in() {
  local l
  if [[ -d "$1" && ! -L "$1" ]]; then
    while IFS= read -r -d '' l; do
      if [[ "$(readlink "${l}")" == "$2${l#"$1"}" ]]; then rm -f "${l}"; fi
    done < <(find "$1" -type l -print0)
  fi
  mv "$1" "$2"
}

# merge_into <src> <dst> — move what src holds into dst, keeping
# what dst already has: the first use of a path whose volume directory a
# path under it created earlier (.local after .local/state/nix). A link
# that would point at itself in dst is such a path's own and is dropped.
# Runs as the user.
merge_into() {
  local s="$1" d="$2" e
  if [[ -d "${s}" && ! -L "${s}" && -d "${d}" && ! -L "${d}" ]]; then
    shopt -s nullglob dotglob
    for e in "${s}"/*; do
      if [[ -L "${e}" && "$(readlink "${e}")" == "${d}/${e##*/}" ]]; then
        rm -f "${e}"
      elif [[ -e "${d}/${e##*/}" || -L "${d}/${e##*/}" ]]; then
        merge_into "${e}" "${d}/${e##*/}"
      else
        move_in "${e}" "${d}/${e##*/}"
      fi
    done
    rmdir "${s}"
  else
    rm -rf "${s}"
  fi
}

# link_persisted — keep every path of ${PERSIST_LIST} (the image's list) and
# ~/.persist/persist.list (the instance's own additions, in the volume) in
# the state volume mounted at ~/.persist: each becomes a symlink into it. On
# first use what the image put at the path is moved into the volume; after
# that the volume's copy wins. Runs as the user, so the files stay theirs.
# Each path is a directory; a file or a link elsewhere is refused, and a
# path that fails is reported and left as it is. Paths are taken sorted, parents first; one
# under a path already kept (.config/gh under .config) is already in the
# volume and is skipped — linking it would delete it.
# ~/.persist/persist.linked records the paths used once, so a parent listed
# after its child was kept (.local after .local/state/nix) is still a first
# use: merged in, not deleted.
link_persisted() {
  local user="${HW_USER:-dev}" home store store_real linked
  home="$(getent passwd "${user}" | cut -d: -f6)"
  store="${home}/.persist"
  [[ -d "${store}" ]] || return 0
  chown "${user}:" "${store}"
  store_real="$(cd "${store}" && pwd -P)"
  linked="${store}/persist.linked"
  local list rel src dst parent first rels=()
  for list in "${PERSIST_LIST}" "${store}/persist.list"; do
    [[ -f "${list}" ]] || continue
    # `|| -n`: a last line without a newline still counts
    while IFS= read -r rel || [[ -n "${rel}" ]]; do
      rel="${rel%%#*}"
      rel="${rel//[[:space:]]/}"
      rel="${rel%/}"
      [[ -n "${rel}" ]] || continue
      if [[ "${rel}" == /* || "${rel}" == *..* || "/${rel}/" == */./* || "${rel}" == *//* ||
            "${rel}" == .persist* || "${rel%%/*}" == persist.list || "${rel%%/*}" == persist.linked ]]; then
        echo "persist: skipped '${rel}' (must be a path inside the home directory)" >&2
        continue
      fi
      rels+=("${rel}")
    done < "${list}"
  done
  [[ ${#rels[@]} -gt 0 ]] || return 0
  while IFS= read -r rel; do
    src="${home}/${rel}"
    dst="${store}/${rel}"
    if [[ -L "${src}" && "$(readlink "${src}")" == "${dst}" ]]; then
      # a restart keeps the link; the volume may have lost what it points at
      if [[ ! -e "${dst}" ]] && ! runuser -u "${user}" -- mkdir -p "${dst}"; then
        echo "persist: '${rel}' could not be linked; left as it is" >&2
        continue
      fi
      record_linked "${linked}" "${rel}"
      continue
    fi
    parent="$(cd "$(dirname "${src}")" 2>/dev/null && pwd -P)" || parent=""
    if [[ -n "${parent}" && ( "${parent}" == "${store_real}" || "${parent}" == "${store_real}/"* ) ]]; then
      echo "persist: '${rel}' is already kept through a parent path" >&2
      continue
    fi
    # a link elsewhere (a dotfile manager's) is not ours to replace; a stale
    # link into the volume is dropped by the step below
    if [[ -L "${src}" ]]; then
      case "$(readlink "${src}")" in
        "${store}"/* | "${store_real}"/*) ;;
        *)
          echo "persist: skipped '${rel}' (a link elsewhere; left as it is)" >&2
          continue
          ;;
      esac
    fi
    # paths are directories: a missing one is created as one
    if [[ -f "${src}" ]]; then
      echo "persist: skipped '${rel}' (a file; list its directory instead)" >&2
      continue
    fi
    first=1
    grep -qxF -- "${rel}" "${linked}" 2>/dev/null && first=0
    # the inner script gets its values as $1…$3; single quotes on purpose.
    # A path that fails is reported, not fatal: sshd must still start.
    # shellcheck disable=SC2016
    if ! runuser -u "${user}" -- bash -c "$(declare -f move_in merge_into)"'
      set -eu
      src="$1" dst="$2" first="$3"
      [ -L "${src}" ] && rm -f "${src}"
      mkdir -p "$(dirname "${dst}")" "$(dirname "${src}")"
      if [ -e "${src}" ]; then
        if [ ! -e "${dst}" ]; then move_in "${src}" "${dst}"
        elif [ "${first}" = 1 ]; then merge_into "${src}" "${dst}"
        else rm -rf "${src}"; fi
      elif [ ! -e "${dst}" ]; then
        mkdir -p "${dst}"
      fi
      ln -s "${dst}" "${src}"' _ "${src}" "${dst}" "${first}"; then
      echo "persist: '${rel}' could not be linked; left as it is" >&2
      continue
    fi
    record_linked "${linked}" "${rel}"
  done < <(printf '%s\n' "${rels[@]}" | LC_ALL=C sort -u)
  if [[ -e "${linked}" ]]; then chown "${user}:" "${linked}"; fi
}

# record_linked <file> <rel> — note that rel has had its first use. A
# record that cannot be written is reported, not fatal: sshd must start.
record_linked() {
  grep -qxF -- "$2" "$1" 2>/dev/null && return 0
  { printf '%s\n' "$2" >> "$1"; } 2>/dev/null ||
    echo "persist: cannot record '$2' in $1" >&2
}

# start_dockerd — with HW_DOCKER=1 (an instance with docker: true, sysbox-runc
# runtime) run a Docker daemon for the user (group docker). A daemon that
# does not come up is reported, not fatal: sshd must still start.
start_dockerd() {
  [[ "${HW_DOCKER:-0}" == "1" ]] || return 0
  dockerd >/var/log/dockerd.log 2>&1 </dev/null &
  local _
  for _ in $(seq 30); do
    docker info >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "dockerd did not start; see /var/log/dockerd.log" >&2
}

main() {
  if [[ "$#" -gt 0 ]]; then
    exec "$@"
  fi
  ensure_host_keys
  link_persisted
  start_dockerd
  mkdir -p /run/sshd
  exec /usr/sbin/sshd -D -e
}

# Run only when executed: tests source this file to call its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
