#!/usr/bin/env bash
# Usage: spawn-repo-agent.sh [--machine <machine>] [--kind <claude|agy|...>]
#          [--model <model>] [--effort <level>] [--reply-lang <language>]
#          <[org/]repo> [-- <task text...>]
#
# --machine dispatches on another machine that an enabled plugin provides
# (scripts/lib/plugins.sh; e.g. plugins/instances: a dev container or a
# remote host), named by its label or target. The plugin ensures it first
# (a stopped container is restarted), then the rest of the arguments go to
# that machine's own spawn-repo-agent.sh through the plugin's exec, so the
# clone, the worktree, the git credentials and the worker all stay there. Its output comes back with pane ids as <label>/<pane> and herdr
# commands as `herdr --machine <label> ...`, using the current label.
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
#      worktree/<repo>/task/<uuid> with a detached HEAD at origin/main (or master) —
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

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=scripts/lib/common.sh
source "${lib_dir}/common.sh"
# shellcheck source=scripts/lib/herdr.sh
source "${lib_dir}/herdr.sh"
# shellcheck source=scripts/lib/json.sh
source "${lib_dir}/json.sh"
# shellcheck source=scripts/lib/agent-trust.sh
source "${lib_dir}/agent-trust.sh"

usage() {
  echo "Usage: $0 [--machine <machine>] [--kind <claude|agy|...>] [--model <model>] [--effort <level>] [--reply-lang <language>] <[org/]repo> [-- <task text...>]" >&2
  exit 1
}

# dispatch_on_machine <machine> <args...> — run the machine's own
# spawn-repo-agent.sh with <args> through the plugin that provides it, and
# rewrite its pane ids and herdr commands so they can be used from here.
dispatch_on_machine() {
  local machine="$1"
  shift
  local found bin target
  found="$(hw_plugin_find "${machine}")"
  if [[ -z "${found}" ]]; then
    if [[ -z "$(hw_plugin_bins)" ]]; then
      echo "Error: --machine needs a plugin that provides machines; none is enabled (see: scripts/plugins.sh ls)." >&2
    else
      echo "Error: no machine labeled or named '${machine}' (see: scripts/plugins.sh machines)." >&2
    fi
    exit 1
  fi
  IFS=$'\t' read -r bin machine target <<< "${found}"
  # bring it into use first (a plugin restarts a stopped container and
  # explains a remote host that is down)
  hw_plugin_ensure "${bin}" "${target}" || {
    echo "Error: machine ${machine} is not available (see above)." >&2
    exit 1
  }
  # the label goes into sed replacements: escape \, & and the | delimiter
  local esc
  esc="$(printf '%s' "${machine}" | sed 's/[\\&|]/\\&/g')"
  hw_plugin_exec "${bin}" "${target}" scripts/spawn-repo-agent.sh "$@" 2>&1 |
    sed -e "s|Dispatched to pane \([^ ]*\)|Dispatched to pane ${esc}/\1|" \
      -e "s|herdr agent |herdr --machine ${esc} agent |g"
}

# fail_launch <pane_id> <message> — the agent CLI exited at startup.
fail_launch() {
  hw_die "the agent exited during startup in pane $1: $2"
}

main() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # --machine may appear anywhere before the task's `--`; the other
  # arguments pass through unchanged to the machine's own script.
  local machine="" rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --machine) machine="${2:?--machine needs a value}"; shift 2 ;;
      --machine=*)
        machine="${1#*=}"
        # empty would silently run here, with this machine's credentials
        [[ -n "${machine}" ]] || hw_die "--machine needs a value"
        shift ;;
      --) rest+=("$@"); break ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  set -- "${rest[@]+"${rest[@]}"}"
  if [[ -n "${machine}" ]]; then
    # shellcheck source=scripts/lib/plugins.sh
    source "${script_dir}/lib/plugins.sh"
    dispatch_on_machine "${machine}" "$@"
    return
  fi

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

  hw_require_herdr || exit 1

  local repo_name="${repo_arg##*/}"
  repo_name="${repo_name%.git}"
  local uuid leaf wt pane_id
  uuid="$(hw_short_id)"
  leaf="task/${uuid}"

  # create-worktree.sh also imports/refreshes repos/<repo> via setup-repo.sh
  # and installs herdr-worktree's git hooks. Its summary goes to stdout; only the
  # Path line is consumed here. The worktree starts on a detached HEAD at
  # origin/main (or master) — no branch is named until the work (and its slug) is known.
  wt="$("${script_dir}/create-worktree.sh" --detach "${repo_arg}" "${leaf}" |
    awk '/^  Path:/ {print $2; exit}')"
  [[ -n "${wt}" && -d "${wt}" ]] || {
    echo "Error: worktree was not created for ${repo_arg} ${leaf}." >&2
    exit 1
  }

  pane_id="$(hw_workspace_pane_for "${repo_name}" "${wt}" "${leaf//\//-}")"
  local tab_id
  tab_id="$(herdr pane get "${pane_id}" | jq -r '.result.pane.tab_id // empty')"

  # Pre-trust the worktree so the worker's first-run dialog does not block it.
  hw_trust_worktree "${wt}"

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
    err="$(hw_launch_error "${pane_id}" "${kind}")"
    if [[ -n "${err}" ]]; then
      kill "${start_pid}" 2>/dev/null || true
      wait "${start_pid}" 2>/dev/null || true
      fail_launch "${pane_id}" "${err}"
    fi
    sleep 1
  done
  wait "${start_pid}" || start_rc=$?
  if [[ ${start_rc} -ne 0 ]]; then
    err="$(hw_launch_error "${pane_id}" "${kind}")"
    [[ -n "${err}" ]] && fail_launch "${pane_id}" "${err}"
    if ! herdr agent get "${pane_id}" > /dev/null 2>&1; then
      herdr pane run "${pane_id}" "cd $(printf '%q' "${wt}") && ${kind}${quoted_flags}" >&2
      hw_wait_for_agent "${pane_id}" "${kind}" || exit 1
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
    if hw_pane_has_dialog "${pane_id}"; then
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
    echo "  Idle (standby prompt sent) — send a task with: herdr agent prompt ${pane_id} \"<task>\" --wait --until working --until blocked --timeout 15000"
  fi
}

# Run only when executed: tests source this file to call its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
