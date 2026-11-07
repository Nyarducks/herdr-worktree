#!/usr/bin/env bats
# agent-prompt-wait.bats — every `herdr agent prompt ... --wait` the skills
# and scripts give names the states to wait for (ADR-0023). A bare --wait
# matches idle, done or blocked, the end of the worker's turn, so sending
# to a busy worker would block until the timeout.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  fixture=""
}

teardown() {
  [[ -n "${fixture}" && -d "${fixture}" ]] && rm -rf "${fixture}"
  return 0
}

# bare_waits <file>... — prints each `agent prompt` command that has --wait
# but no --until, with backslash-continued lines joined first.
bare_waits() {
  local f
  for f in "$@"; do
    awk -v f="${f}" '
      /\\$/ { if (!cmd) start = FNR; sub(/\\$/, ""); cmd = cmd $0; next }
      { if (!cmd) start = FNR; cmd = cmd $0
        if (cmd ~ /agent prompt/ && cmd ~ /--wait/ && cmd !~ /--until/)
          print f ":" start ": " cmd
        cmd = "" }' "${f}"
  done
}

@test "no agent prompt in the skills or scripts waits with a bare --wait" {
  git -C "${repo_root}" rev-parse --git-dir >/dev/null
  local files=()
  mapfile -t files < <(git -C "${repo_root}" grep -l -e 'agent prompt' -- .agents/skills scripts)
  [[ "${#files[@]}" -gt 0 ]]
  bare="$(cd "${repo_root}" && bare_waits "${files[@]}")"
  if [[ -n "${bare}" ]]; then
    printf 'bare --wait (add --until working --until blocked):\n%s\n' "${bare}" >&2
    return 1
  fi
}

@test "a bare --wait is caught on one line and across continued lines" {
  mkdir -p "${repo_root}/tmp"
  fixture="$(mktemp -d "${repo_root}/tmp/agent-prompt-wait.XXXXXX")"
  printf '%s\n' \
    'herdr agent prompt p "x" --wait --timeout 5' \
    "herdr agent prompt p 'x' \\" \
    '  --wait --timeout 5' \
    "herdr agent prompt p 'x' \\" \
    '  --wait --until working --timeout 5' \
    'herdr agent prompt p "x" --wait --until working' > "${fixture}/s.sh"
  out="$(bare_waits "${fixture}/s.sh")"
  [[ "$(wc -l <<< "${out}" | tr -d ' ')" == 2 ]]
  grep -q ':1: ' <<< "${out}"
  grep -q ':2: ' <<< "${out}"
}
