# shellcheck shell=bash
# Editing JSON settings files that other processes may edit too. Source,
# don't run. Needs jq.

# hw_json_merge <file> <path-arg> <jq-filter>
# Applies <jq-filter> (with $path bound to <path-arg>) to <file> in place,
# atomically (lock + mktemp + mv). The lock is a directory — mkdir(2) is
# atomic on every platform, so no flock(1) dependency (flock is Linux-only
# and was never in Requirements). mktemp templates keep their X's trailing
# for BSD mktemp. Recovers an empty object first when the file is corrupt.
hw_json_merge() {
  local settings_file="$1" path_arg="$2" filter="$3"
  local lockdir="${settings_file}.lock.d" tries=0
  until mkdir "${lockdir}" 2>/dev/null; do
    tries=$((tries + 1))
    # every ~10s assume the holder died mid-merge and break the stale lock
    # (the lockdir is always empty, so rmdir is a safe reclaim)
    if (( tries % 100 == 0 )); then
      rmdir "${lockdir}" 2>/dev/null || true
    fi
    if (( tries > 300 )); then
      echo "Error: timed out locking ${settings_file}" >&2
      return 1
    fi
    sleep 0.1
  done
  local rc=0
  (
    if ! jq -e 'type == "object"' "${settings_file}" >/dev/null 2>&1; then
      local backup_file recovery_tmp
      backup_file="$(mktemp "${settings_file}.corrupt-XXXXXX")"
      mv "${backup_file}" "${backup_file}.bak"
      backup_file="${backup_file}.bak"
      cp "${settings_file}" "${backup_file}" 2>/dev/null || true
      recovery_tmp="$(mktemp "${settings_file}.XXXXXX")"
      echo "{}" > "${recovery_tmp}"
      mv "${recovery_tmp}" "${settings_file}" 2>/dev/null || rm -f "${recovery_tmp}"
    fi

    local tmp_file
    tmp_file="$(mktemp "${settings_file}.XXXXXX")"
    if jq --arg path "${path_arg}" "${filter}" "${settings_file}" > "${tmp_file}" 2>/dev/null; then
      mv "${tmp_file}" "${settings_file}" 2>/dev/null || rm -f "${tmp_file}"
    else
      rm -f "${tmp_file}"
    fi
  ) || rc=$?
  rmdir "${lockdir}"
  return "${rc}"
}
