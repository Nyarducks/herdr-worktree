#!/usr/bin/env bash
# Usage: spawn-repo-agent.sh [--kind <claude|agy|...>] [--model <model>]
#          [--effort <level>] [--reply-lang <language>] <[org/]repo>
#          [-- <task text...>]
#
# --reply-lang names the human's natural language (e.g. Japanese). The
# prompt always tells the worker to think in English; with --reply-lang it
# also tells it to reply in that language, otherwise in the language the
# human writes in.
#
# --model / --effort are mapped to each CLI's own flags:
#   claude, agy  --model <m>  --effort <e>
#   codex        --model <m>  -c model_reasoning_effort=<e>
#   pi           --model <m>  --thinking <e>
#   devin        --model <m>  (no effort flag — the level is part of the
#                model id, e.g. claude-opus-5-5-high)
# Each is independent. Omitted or `inherit` means inherit: no flag is
# passed, so the worker uses the model/effort from the CLI's own settings.
# --effort is validated against the levels `agent-models.sh` (cached)
# reports for the given model, or the kind-wide list when the model has
# none; model ids are passed through as given — `agent-models.sh <kind>`
# lists the known ones.
#
# Dispatches a dedicated agent process via herdr:
#   1. imports/refreshes repos/<repo> and creates a worktree at
#      worktree/<repo>/task/<uuid> with a detached HEAD at origin/main —
#      the uuid leaf keeps concurrent dispatches collision-free and no
#      branch is named before the task is understood
#   2. reuses the repo's herdr workspace (one workspace per repo, matched by
#      label) or creates it, adding a tab bound to the new worktree
#   3. starts the agent in that tab's root pane with cwd=<worktree>, so the
#      repo's own AGENTS.md/.agents/skills load — the worker knows nothing
#      about herdr-worktree. The agent runs unconfined.
#   4. submits a prompt via `herdr agent prompt` (paste+Enter). It always
#      carries the self-naming contract — rename agent + tab to a
#      task-derived slug — so names stay meaningful. With a task the worker
#      starts immediately; with none the prompt is a standby instruction
#      and the worker idles until `herdr agent prompt <pane> "<task>"`.
#      TUI agents can swallow the trailing Enter (bracketed paste) — see
#      the agent_prompt_stalled recovery below.
#
# Monitoring is pull-based: `herdr agent wait <pane> --until idle` and
# `herdr agent read <pane>` — workers carry no reporting protocol.
set -euo pipefail

usage() {
  echo "Usage: $0 [--kind <claude|agy|...>] [--model <model>] [--effort <level>] [--reply-lang <language>] <[org/]repo> [-- <task text...>]" >&2
  exit 1
}

require_herdr() {
  command -v herdr > /dev/null 2>&1 || {
    echo "Error: herdr not found on PATH. Cannot dispatch a worker." >&2
    exit 1
  }
  [[ "${HERDR_ENV:-}" == "1" ]] || {
    echo "Error: not running inside a herdr session (HERDR_ENV is unset)." >&2
    exit 1
  }
}

# gen_uuid — short lowercase id for the worktree dir and branch suffix.
gen_uuid() {
  local u=""
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    u="$(cat /proc/sys/kernel/random/uuid)"
  elif command -v uuidgen > /dev/null 2>&1; then
    u="$(uuidgen)"
  else
    u="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  # macOS uuidgen is uppercase; herdr agent names must be lowercase.
  u="$(printf '%s' "${u//-/}" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "${u:0:12}"
}

# launch_error <pane_id> <kind>
# Prints the first `Error:` line the agent CLI wrote after its most recent
# launch command in the pane (e.g. devin's "Error: Upgrade to Pro to access
# this model"), or nothing. A CLI that exits at startup leaves the agent
# unregistered, so herdr would otherwise wait out its full timeout.
launch_error() {
  local pane_id="$1" kind="$2"
  herdr pane read "${pane_id}" --source recent-unwrapped --lines 40 2>/dev/null |
    awk -v k="${kind}" '
      { line[NR] = $0 }
      $0 ~ ("(^|[ /])" k "( |$)") { start = NR }
      END {
        if (!start) exit
        for (i = start + 1; i <= NR; i++) {
          l = line[i]; sub(/^[ \t]+/, "", l)
          if (l ~ /^([Ee]rror|fatal)[: ]/) { print l; exit }
        }
      }'
}

# pane_has_dialog <pane_id>
# True when the pane shows a selection/confirmation dialog (trust prompts,
# import approvals, …). herdr can report such an agent as idle, so an Enter
# nudge or a resent prompt would answer the dialog — check before either.
pane_has_dialog() {
  herdr pane read "$1" --source recent-unwrapped --lines 30 2>/dev/null |
    grep -Eqi 'enter (to )?(select|confirm|continue)|esc (to )?(skip|cancel)|do not trust|trust (this|project)|allow external|update available'
}

# fail_launch <pane_id> <message>
fail_launch() {
  echo "Error: the agent exited during startup in pane $1: $2" >&2
  exit 1
}

# wait_for_agent <pane_id> <kind>
# After `herdr pane run`, `herdr agent wait` errors with "agent_not_found"
# until the agent's SessionStart hook registers the pane — retry briefly.
wait_for_agent() {
  local pane_id="$1" kind="$2" attempt=0 err
  until herdr agent wait "${pane_id}" --until idle --until blocked --timeout 5000 >&2; do
    err="$(launch_error "${pane_id}" "${kind}")"
    [[ -n "${err}" ]] && fail_launch "${pane_id}" "${err}"
    attempt=$((attempt + 1))
    if [[ ${attempt} -ge 6 ]]; then
      echo "Error: agent at pane ${pane_id} did not register/become ready in time." >&2
      exit 1
    fi
    sleep 1
  done
}

# json_merge_atomic <file> <path-arg> <jq-filter>
# Applies <jq-filter> (with $path bound to <path-arg>) to <file> in place,
# atomically (lock + mktemp + mv). The lock is a directory — mkdir(2) is
# atomic on every platform, so no flock(1) dependency (flock is Linux-only
# and was never in Requirements). mktemp templates keep their X's trailing
# for BSD mktemp. Recovers an empty object first when the file is corrupt.
json_merge_atomic() {
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

# ensure_trusted_workspace <worktree_path>
# Pre-trusts the worktree for supported agent CLIs so the worker does not
# stop at a first-run workspace-confirmation dialog:
#   - agy:    ~/.gemini/antigravity-cli/settings.json → trustedWorkspaces
#   - claude: ~/.claude.json → projects[<wt>].hasTrustDialogAccepted, plus
#             the external-CLAUDE.md-imports dialog pre-answered "No"
#             (hasClaudeMdExternalIncludesApproved=false, ...WarningShown=true).
#             Worktrees can sit under the herdr-worktree checkout or another dir
#             with a CLAUDE.md; any import reaching outside the worktree
#             would otherwise stop the worker at that dialog, and declining
#             keeps foreign rules out of it.
#   - pi:     ${PI_CODING_AGENT_DIR:-~/.pi/agent}/trust.json → {<wt>: true}.
#             pi's trust check walks every ancestor for a project
#             `.agents/skills`, so herdr-worktree's own skills above the
#             worktree trigger "Trust project folder?" even when the repo
#             has nothing protected. Skill discovery stops at the repo root
#             (the worktree), so trusting it loads only the repo's own
#             resources, never herdr-worktree's skills.
ensure_trusted_workspace() {
  local worktree_path="$1"
  command -v jq >/dev/null 2>&1 || return 0

  local agy_settings="${HOME}/.gemini/antigravity-cli/settings.json"
  if [[ -f "${agy_settings}" ]]; then
    # single quotes are intentional — $path is a jq variable, not shell
    # shellcheck disable=SC2016
    json_merge_atomic "${agy_settings}" "${worktree_path}" \
      '.trustedWorkspaces = ((.trustedWorkspaces // []) + [$path] | unique)'
  fi

  local claude_settings="${HOME}/.claude.json"
  if [[ -f "${claude_settings}" ]]; then
    # single quotes are intentional — $path is a jq variable, not shell
    # shellcheck disable=SC2016
    json_merge_atomic "${claude_settings}" "${worktree_path}" \
      '.projects[$path] = ((.projects[$path] // {}) + {
         hasTrustDialogAccepted: true,
         hasClaudeMdExternalIncludesApproved: false,
         hasClaudeMdExternalIncludesWarningShown: true
       })'
  fi

  local pi_trust="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}/trust.json"
  if [[ -d "$(dirname "${pi_trust}")" ]]; then
    [[ -f "${pi_trust}" ]] || echo '{}' > "${pi_trust}"
    # single quotes are intentional — $path is a jq variable, not shell
    # shellcheck disable=SC2016
    json_merge_atomic "${pi_trust}" "${worktree_path}" '.[$path] = true'
  fi
}

# workspace_pane_for <repo_name> <worktree_path> <tab_label>
# Prints the pane_id hosting the new worktree: a new tab in the repo's
# existing workspace when one exists, otherwise a new workspace's root pane.
workspace_pane_for() {
  local repo_name="$1" wt="$2" tab_label="$3"
  local ws_id pane_id
  ws_id="$(herdr workspace list 2>/dev/null | jq -r --arg l "${repo_name}" \
    '[.result.workspaces[]? | select(.label == $l)][0].workspace_id // empty')"

  if [[ -n "${ws_id}" ]]; then
    pane_id="$(herdr tab create --workspace "${ws_id}" --cwd "${wt}" \
      --label "${tab_label}" --no-focus |
      jq -r '.result.root_pane.pane_id // .result.pane.pane_id // empty')"
  else
    pane_id="$(herdr workspace create --cwd "${wt}" --label "${repo_name}" --no-focus |
      jq -r '.result.root_pane.pane_id // empty')"
  fi
  [[ -n "${pane_id}" && "${pane_id}" != "null" ]] || {
    echo "Error: could not obtain a pane for ${wt}." >&2
    exit 1
  }
  printf '%s\n' "${pane_id}"
}

main() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local kind="claude" model="" effort="" reply_lang=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) kind="${2:?--kind needs a value}"; shift 2 ;;
      --kind=*) kind="${1#*=}"; shift ;;
      --model) model="${2:?--model needs a value}"; shift 2 ;;
      --model=*) model="${1#*=}"; shift ;;
      --effort) effort="${2:?--effort needs a value}"; shift 2 ;;
      --effort=*) effort="${1#*=}"; shift ;;
      --reply-lang) reply_lang="${2:?--reply-lang needs a value}"; shift 2 ;;
      --reply-lang=*) reply_lang="${1#*=}"; shift ;;
      *) break ;;
    esac
  done
  [[ "${model}" == "inherit" ]] && model=""
  [[ "${effort}" == "inherit" ]] && effort=""

  [[ "${kind}" == "antigravity" ]] && kind="agy"
  if [[ -n "${model}" || -n "${effort}" ]]; then
    case "${kind}" in
      claude|agy|codex|pi|devin) ;;
      *)
        echo "Error: --model/--effort are not supported for --kind ${kind}." >&2
        exit 1
        ;;
    esac
  fi
  if [[ -n "${effort}" ]]; then
    local efforts scope="${kind}"
    efforts="$("${script_dir}/agent-models.sh" "${kind}" efforts)"
    if [[ -z "${efforts}" ]]; then
      echo "Error: --effort cannot be set from the command line for --kind ${kind}." >&2
      [[ "${kind}" == "devin" ]] &&
        echo "  Devin encodes the level in the model id (e.g. claude-opus-5-5-high) — pick one from: scripts/agent-models.sh devin" >&2
      exit 1
    fi
    if [[ -n "${model}" ]]; then
      local model_efforts
      model_efforts="$("${script_dir}/agent-models.sh" "${kind}" models |
        awk -F'\t' -v m="${model}" '$1 == m {print $3; exit}')"
      if [[ -n "${model_efforts}" ]]; then
        efforts="$(tr ',' '\n' <<< "${model_efforts}")"
        scope="${kind} ${model}"
      fi
    fi
    if ! grep -qxF -- "${effort}" <<< "${efforts}"; then
      echo "Error: --effort for ${scope} must be one of: $(tr '\n' ' ' <<< "${efforts}")inherit (got: ${effort})." >&2
      exit 1
    fi
  fi

  [[ $# -lt 1 ]] && usage
  local repo_arg="$1"
  shift
  local task_text=""
  if [[ $# -gt 0 ]]; then
    [[ "$1" == "--" ]] || usage
    shift
    task_text="$*"
  fi

  require_herdr

  local repo_name="${repo_arg##*/}"
  repo_name="${repo_name%.git}"
  local uuid leaf wt pane_id
  uuid="$(gen_uuid)"
  leaf="task/${uuid}"

  # create-worktree.sh also imports/refreshes repos/<repo> via setup-repo.sh
  # and installs herdr-worktree's git hooks. Its summary goes to stdout; only the
  # Path line is consumed here. The worktree starts on a detached HEAD at
  # origin/main — no branch is named until the work (and its slug) is known.
  wt="$("${script_dir}/create-worktree.sh" --detach "${repo_arg}" "${leaf}" |
    awk '/^  Path:/ {print $2; exit}')"
  [[ -n "${wt}" && -d "${wt}" ]] || {
    echo "Error: worktree was not created for ${repo_arg} ${leaf}." >&2
    exit 1
  }

  pane_id="$(workspace_pane_for "${repo_name}" "${wt}" "${leaf//\//-}")"
  local tab_id
  tab_id="$(herdr pane get "${pane_id}" | jq -r '.result.pane.tab_id // empty')"

  # Pre-trust the worktree so the worker's first-run dialog does not block it.
  ensure_trusted_workspace "${wt}"

  local -a agent_flags=()
  case "${kind}" in
    claude) agent_flags=(--permission-mode auto) ;;
    agy) agent_flags=(--dangerously-skip-permissions) ;;
    devin) agent_flags=(--permission-mode dangerous --respect-workspace-trust false) ;;
  esac
  [[ -n "${model}" ]] && agent_flags+=(--model "${model}")
  if [[ -n "${effort}" ]]; then
    case "${kind}" in
      codex) agent_flags+=(-c "model_reasoning_effort=\"${effort}\"") ;;
      pi) agent_flags+=(--thinking "${effort}") ;;
      *) agent_flags+=(--effort "${effort}") ;;
    esac
  fi

  # Placeholder name; the worker renames itself (and its tab) to a task slug
  # once it reads the prompt — the dispatcher cannot know a meaningful name
  # before the worker does. herdr agent names: [a-z][a-z0-9_-]{0,31}
  local agent_name="w-${uuid}"
  # `agent start` is the native path (waits for readiness itself). It can be
  # denied by the calling agent's own permission classifier; `pane run`
  # (typing the launch command into an existing pane) is not, and the agent
  # still self-registers via its SessionStart hook.
  # The ${arr[@]+...} form keeps an empty array safe under `set -u` on
  # bash 4.3. The pane-run command line is typed into a shell, so each flag
  # is %q-quoted (a model like `opus[1m]` would otherwise glob).
  local quoted_flags=""
  if [[ ${#agent_flags[@]} -gt 0 ]]; then
    quoted_flags="$(printf ' %q' "${agent_flags[@]}")"
  fi
  # `agent start` runs in the background while the pane is polled: a CLI
  # that exits at startup (unavailable model, bad flag, not logged in) is
  # reported at once instead of after herdr's 30s readiness timeout, and
  # the pane-run fallback is skipped — it would only fail the same way.
  herdr agent start "${agent_name}" --kind "${kind}" --pane "${pane_id}" -- \
    ${agent_flags[@]+"${agent_flags[@]}"} >&2 &
  local start_pid=$! start_rc=0 err=""
  while kill -0 "${start_pid}" 2>/dev/null; do
    err="$(launch_error "${pane_id}" "${kind}")"
    if [[ -n "${err}" ]]; then
      kill "${start_pid}" 2>/dev/null || true
      wait "${start_pid}" 2>/dev/null || true
      fail_launch "${pane_id}" "${err}"
    fi
    sleep 1
  done
  wait "${start_pid}" || start_rc=$?
  if [[ ${start_rc} -ne 0 ]]; then
    err="$(launch_error "${pane_id}" "${kind}")"
    [[ -n "${err}" ]] && fail_launch "${pane_id}" "${err}"
    if ! herdr agent get "${pane_id}" > /dev/null 2>&1; then
      herdr pane run "${pane_id}" "cd $(printf '%q' "${wt}") && ${kind}${quoted_flags}" >&2
      wait_for_agent "${pane_id}" "${kind}"
    fi
  fi

  # Every spawn sends a prompt carrying the self-naming contract — with a
  # task the worker renames from it and starts immediately; without one the
  # prompt is a standby instruction so the contract survives for follow-up
  # `herdr agent prompt`s (names like w-<uuid> mean nothing otherwise).
  # Language contract: reasoning in English (the prompt is English too);
  # replies to the human in their language — named by the orchestrator via
  # --reply-lang, or whatever the human writes in when it is not given.
  local lang_rule
  if [[ -n "${reply_lang}" ]]; then
    lang_rule="Language: think in English, but write every reply to the human in ${reply_lang} — including replies to English prompts like this one. Code, commits and repository files follow the repository's own conventions."
  else
    lang_rule="Language: think in English, but reply to the human in the natural language they write to you in. Code, commits and repository files follow the repository's own conventions."
  fi

  local prompt
  if [[ -n "${task_text}" ]]; then
    prompt="You are running inside a herdr pane (pane id: ${pane_id}, tab id: ${tab_id:-unknown}).

First, once the task below is clear to you, pick a short lowercase slug for it and rename yourself and your tab:
  herdr agent rename ${pane_id} <slug>
  herdr tab rename ${tab_id:-<tab-id>} <short-title>
Slug rules: starts with a lowercase letter, only [a-z0-9_-], at most 32 chars. Then proceed with the task.

${lang_rule}

Task: ${task_text}"
  else
    prompt="You are running inside a herdr pane (pane id: ${pane_id}, tab id: ${tab_id:-unknown}) as a standby worker for ${repo_name} (worktree: ${wt}).

No task is assigned yet — wait for follow-up prompts. When you receive a task, first pick a short lowercase slug for it and rename yourself and your tab:
  herdr agent rename ${pane_id} <slug>
  herdr tab rename ${tab_id:-<tab-id>} <short-title>
Slug rules: starts with a lowercase letter, only [a-z0-9_-], at most 32 chars. For now just acknowledge briefly and make no changes.

${lang_rule}"
  fi

  # agent prompt pastes the text + Enter "atomically"; --wait --until
  # working confirms the agent picked the task up without blocking on
  # completion. TUI agents (devin, claude) running bracketed paste can
  # swallow the trailing Enter — the paste sits in the input unsubmitted
  # and herdr's fixed 5s stall window fires agent_prompt_stalled (or the
  # caller timeout fires first). Recover by sending a real Enter keypress
  # and waiting again. If the agent is still plainly idle after that, the
  # paste never reached its input — resend the prompt once. (A pi worker
  # that looked like this was in fact sitting in its trust dialog; the
  # dialog check below now stops both the nudge and the resend there.) Never nudge or
  # resend on other errors — a stray Enter could accept a blocked agent's
  # permission prompt.
  local prompt_out
  if ! prompt_out="$(herdr agent prompt "${pane_id}" "${prompt}" \
      --wait --until working --until blocked --timeout 15000 2>&1)"; then
    if pane_has_dialog "${pane_id}"; then
      echo "Warning: the agent is showing a dialog; nothing was sent to it. Answer it in the pane:" >&2
      echo "  herdr agent read ${pane_id} --lines 30" >&2
    elif grep -Eq 'agent_prompt_stalled|"code": ?"timeout"' <<< "${prompt_out}"; then
      sleep 1
      herdr pane send-keys "${pane_id}" Enter >&2 || true
      if herdr agent wait "${pane_id}" --until working --until blocked \
          --until 'done' --timeout 15000 >&2; then
        echo "Note: prompt needed an explicit Enter nudge (agent TUI swallowed prompt's trailing Enter)." >&2
      elif [[ "$(herdr agent get "${pane_id}" 2>/dev/null |
                 jq -r '.result.agent.agent_status // empty')" == "idle" ]] &&
           herdr agent prompt "${pane_id}" "${prompt}" \
             --wait --until working --until blocked --timeout 15000 >&2; then
        echo "Note: prompt was resent (the first paste never reached the agent's input)." >&2
      else
        echo "Warning: task submission was not confirmed as started. Check the pane:" >&2
        echo "  herdr agent read ${pane_id} --lines 30" >&2
      fi
    else
      printf '%s\n' "${prompt_out}" >&2
      echo "Warning: task submission was not confirmed as started. Check the pane:" >&2
      echo "  herdr agent read ${pane_id} --lines 30" >&2
    fi
  fi

  echo "Dispatched to pane ${pane_id} (repo=${repo_name} worktree=${wt})."
  if [[ -z "${task_text}" ]]; then
    echo "  Idle (standby prompt sent) — send a task with: herdr agent prompt ${pane_id} \"<task>\" --wait"
  fi
}

main "$@"
