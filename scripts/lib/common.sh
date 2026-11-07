# shellcheck shell=bash
# Small helpers every script uses. Source, don't run.

# hw_die <message...> — print "Error: <message>" to stderr and exit 1.
hw_die() {
  echo "Error: $*" >&2
  exit 1
}

# hw_short_id — a 12-character lowercase hex id (worktree dirs, branch
# suffixes, agent names: herdr names must be lowercase).
hw_short_id() {
  local u=""
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    u="$(cat /proc/sys/kernel/random/uuid)"
  elif command -v uuidgen > /dev/null 2>&1; then
    u="$(uuidgen)"
  else
    u="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  u="$(printf '%s' "${u//-/}" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "${u:0:12}"
}
