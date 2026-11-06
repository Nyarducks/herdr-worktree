#!/usr/bin/env bash
# Shared helpers for tests/scripts/*.sh — generic assertions plus PATH stubs
# for gh/herdr so script behaviour can be tested without network or a real
# herdr session.
#
# Sourcing this file also sets:
#   repo_root — the herdr-worktree checkout under test
#   t         — a fresh scratch dir (removed on EXIT)
#   stub_bin  — dir prepended to PATH containing stub commands

pass=0
fail=0
declare -a failed_names=()

ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); failed_names+=("$1"); printf '  fail %s\n' "$1"; }

# shellcheck disable=SC2034  # read by the sourcing test scripts
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
t="$(realpath "$(mktemp -d /tmp/wth-scripts.XXXXXX)")"
stub_bin="${t}/bin"
mkdir -p "${stub_bin}"
PATH="${stub_bin}:${PATH}"
trap 'rm -rf "${t}"' EXIT

expect_rc() { # <name> <rc> <want: 0|nz>
  if [[ "$3" == 0 && "$2" -eq 0 ]] || [[ "$3" == nz && "$2" -ne 0 ]]; then
    ok "$1"
  else
    bad "$1"; printf '       rc=%s\n' "$2"
  fi
}
expect_eq() { # <name> <got> <want>
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    bad "$1"; printf '       got=%s want=%s\n' "$2" "$3"
  fi
}
expect_file() { # <name> <path> <exists|absent>
  if [[ "$3" == exists && -e "$2" ]] || [[ "$3" == absent && ! -e "$2" ]]; then
    ok "$1"
  else
    bad "$1"; printf '       path=%s\n' "$2"
  fi
}
expect_grep() { # <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then
    ok "$1"
  else
    bad "$1"; printf '       missing: %s\n' "$3"
  fi
}
expect_not_grep() { # <name> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then
    ok "$1"
  else
    bad "$1"; printf '       unexpected: %s\n' "$3"
  fi
}

# --- stub builders -----------------------------------------------------------

# stub_gh — a `gh` whose `repo clone` clones from ${STUB_ORIGIN}/<name>.git
# (a local bare repo) and whose `api` serves canned PR bodies / captures PATCH.
stub_gh() {
  cat > "${stub_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# record every invocation
echo "gh $*" >> "${GH_STUB_LOG:?}"
if [[ "$1" == "repo" && "$2" == "clone" ]]; then
  slug="$3"; dest="$4"
  git clone "${STUB_ORIGIN:?}/$(basename "${slug}").git" "${dest}"
elif [[ "$1" == "api" ]]; then
  endpoint="$2"
  if [[ "$*" == *"-X PATCH"* ]]; then
    # capture -f body=... value
    for a in "$@"; do [[ "$a" == body=* ]] && printf '%s' "${a#body=}" > "${GH_STUB_BODY_FILE:?}"; done
    echo "Updated PR #1"
  else
    cat "${GH_STUB_BODY_FILE:?}"
  fi
fi
EOF
  chmod +x "${stub_bin}/gh"
  export STUB_ORIGIN="${t}/origin"
  mkdir -p "${STUB_ORIGIN}"
  export GH_STUB_LOG="${t}/gh.log" GH_STUB_BODY_FILE="${t}/pr-body.txt"
  : > "${GH_STUB_LOG}"
}

# stub_herdr — records invocations, serves canned JSON for the queries
# spawn-repo-agent.sh makes, and exits 0 for everything else.
# HERDR_STUB_PROMPT_STALL=1 makes `agent prompt` fail like a TUI that
# swallowed the trailing Enter (agent_prompt_stalled); `agent wait` still
# succeeds, simulating recovery via `pane send-keys Enter`.
# HERDR_STUB_START_HANG=1 makes `agent start` hang; HERDR_STUB_PANE_OUTPUT
# is what `pane read` returns.
# HERDR_STUB_PASTE_LOST=1 makes the first `agent prompt` time out and
# `agent wait` fail while `agent get` reports idle — the paste was lost —
# so only a resent prompt succeeds.
stub_herdr() {
  cat > "${stub_bin}/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "herdr $*" >> "${HERDR_STUB_LOG:?}"
case "$1 $2" in
  "workspace list")   echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"root_pane":{"pane_id":"pane-1"},"workspace_id":"ws-1"}}' ;;
  "tab create")       echo '{"result":{"root_pane":{"pane_id":"pane-1"},"pane":{"pane_id":"pane-1"}}}' ;;
  "pane get")         echo '{"result":{"pane":{"tab_id":"tab-1"}}}' ;;
  "agent prompt")
    if [[ "${HERDR_STUB_PASTE_LOST:-0}" == "1" && ! -e "${HERDR_STUB_LOG}.prompted" ]]; then
      : > "${HERDR_STUB_LOG}.prompted"
      echo '{"error":{"code":"timeout","message":"timed out waiting for agent status"},"id":"cli:agent:prompt"}'
      exit 1
    fi
    if [[ "${HERDR_STUB_PROMPT_STALL:-0}" == "1" ]]; then
      echo '{"error":{"code":"agent_prompt_stalled","message":"agent prompt produced no observed working or blocked state within 5000ms"},"id":"cli:agent:prompt"}'
      exit 1
    fi
    ;;
  "agent wait")
    [[ "${HERDR_STUB_PASTE_LOST:-0}" == "1" ]] && exit 1
    exit "${HERDR_STUB_RC:-0}"
    ;;
  "agent get") echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  "agent start")
    # HERDR_STUB_START_HANG=1: never becomes ready (herdr would sit out its
    # 30s timeout) — the pane output decides whether the launch failed.
    if [[ "${HERDR_STUB_START_HANG:-0}" == "1" ]]; then
      exec sleep 20   # exec: a kill from spawn-repo-agent.sh ends it
    fi
    ;;
  "pane read") printf '%s\n' "${HERDR_STUB_PANE_OUTPUT:-}" ;;
  *) exit "${HERDR_STUB_RC:-0}" ;;
esac
EOF
  chmod +x "${stub_bin}/herdr"
  export HERDR_STUB_LOG="${t}/herdr.log" HERDR_ENV=1
  : > "${HERDR_STUB_LOG}"
}

# stub_agent_clis — claude/agy/codex/pi/devin stand-ins that answer the
# help / model-list queries agent-models.sh makes, and point the model
# cache at the scratch dir so tests never touch the real CLIs or cache.
stub_agent_clis() {
  cat > "${stub_bin}/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "  --effort <level>   Effort level for the current session" \
  "                     (low, medium, high, xhigh, max)"
EOF
  cat > "${stub_bin}/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" ]]; then
  printf 'gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)\n'
else
  echo "  --effort   Reasoning effort for the current CLI session (low|medium|high|xhigh|max)"
fi
EOF
  cat > "${stub_bin}/codex" <<'EOF'
#!/usr/bin/env bash
echo '{"models":[{"slug":"gpt-6-luna","display_name":"GPT-6 Luna","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},{"slug":"gpt-6-sol","display_name":"GPT-6 Sol","visibility":"list","supported_reasoning_levels":[{"effort":"high"},{"effort":"ultra"}]},{"slug":"hidden-model","visibility":"hide","supported_reasoning_levels":[{"effort":"secret"}]}]}'
EOF
  cat > "${stub_bin}/pi" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list-models" ]]; then
  printf '%s\n' "provider  model         context" "mlx       org/Qwen-4bit 131K"
else
  printf '%s\n' "  --tools, -t <tools>   Comma-separated allowlist" \
    "                        Keeps MCP tools (can be used multiple times)" \
    "  --thinking <level>    Set thinking level: off, minimal, low, medium, high, xhigh, max"
fi
EOF
  cat > "${stub_bin}/devin" <<'EOF'
#!/usr/bin/env bash
if [[ "${DEVIN_STUB_LOGGED_IN:-0}" == "1" ]]; then
  echo '{"families":[{"family_label":"SWE-2","slug":"swe-2","aliases":["swe"],"variants":[{"model_uid":"swe-2-high","label":"SWE-2 High"},{"model_uid":"swe-2-medium","label":"SWE-2 Medium"}]}]}'
else
  echo "Error: Not logged in." >&2
  exit 1
fi
EOF
  chmod +x "${stub_bin}"/{claude,agy,codex,pi,devin}
  export AGENT_MODELS_CACHE_DIR="${t}/agent-models"
}

# seed_origin <name> [branch] — create a local bare origin with one branch
# (default main) holding one commit; stub_gh clones from it.
seed_origin() {
  local name="$1" branch="${2:-main}"
  local seed="${t}/seed-${name}"
  git init -q -b "${branch}" "${seed}"
  git -C "${seed}" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
  git clone -q --bare "${seed}" "${STUB_ORIGIN}/${name}.git"
}

# make_lab <dir> — a lab root with repos/ + worktree/ for WORKTREE_LAB_DIR.
make_lab() { mkdir -p "$1/repos" "$1/worktree"; }
