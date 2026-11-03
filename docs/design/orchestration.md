---
type: Design Doc
title: Orchestration — Orchestrator and Worker lifecycle
description: How the orchestrator dispatches, monitors, and steers workers through herdr; worker lifecycle and ownership.
status: current
last_modified: 2026-11-03
tags: [orchestrator, herdr, dispatch, worker]
sources: [scripts/spawn-repo-agent.sh, .agents/skills/worktree-development/SKILL.md]
---

# Orchestration

## Goal

Let the human delegate work to a separate worker process that runs inside
the target repository — so the repo's own `AGENTS.md` and `.agents/skills`
load — while the orchestrator retains control through herdr.

## Design

```mermaid
sequenceDiagram
    participant H as Human
    participant O as Orchestrator
    participant G as git
    participant R as herdr
    participant W as Worker

    H->>O: "do task X in repo R"
    O->>H: confirm agent kind + repo via ask-question tool<br/>(only when the request omits them)
    O->>G: create-worktree.sh --detach → worktree/R/task/<uuid><br/>(detached HEAD at origin/main)
    O->>R: workspace get/create (label = repo)<br/>tab create → pane
    O->>R: agent start — agent in the tab's pane, cwd=worktree
    O->>R: agent prompt — task + self-name preamble,<br/>or standby contract when no task given
    R->>W: start
    W->>R: agent rename / tab rename
    W->>W: implement inside worktree
    H->>O: "how is it going?"
    O->>R: agent wait / read <pane>
    O->>H: status report
    H->>O: "also fix Y"
    O->>R: agent prompt <pane> (follow-up)
```

Key decisions (see ADR-0003, ADR-0004, ADR-0008, ADR-0009, ADR-0010):

- **Herdr-native model**: one workspace per repo (matched by label), one
  tab per task, the worker in the tab's root pane. No herdr-worktree-side state
  to keep in sync.
- **Self-naming**: agents spawn as `w-<uuid>`; the prompt preamble asks
  the worker to rename itself and its tab once it understands the task.
  The worker knows nothing about herdr-worktree — the preamble is the whole
  contract.
- **Detached start**: task worktrees begin on a detached HEAD at
  `origin/main`; a branch is named only once the work — and its slug —
  is known (see ADR-0002).
- **Ask before dispatch**: when the request omits the agent kind or the
  repository, the orchestrator asks the user through its ask-question
  tool (`AskUserQuestion`/`ask_user_question`/`ask_question` — the name
  varies per agent) rather than defaulting silently (ADR-0003).
- **Dispatch is a single call**: `spawn-repo-agent.sh` is the only entry
  point and runs the whole sequence — worktree, tab, spawned agent,
  prompt. The orchestrator never runs `create-worktree.sh` for another
  repo and stops there: a worktree without a worker is a half-finished
  task. Missing inputs are collected *before* dispatch, not after.
- **The task is optional**: spawning alone is a valid use (pre-warmed
  standby, interactive steering). With no task the worker still gets a
  standby prompt carrying only the self-naming contract — rename agent +
  tab when a real task arrives — so follow-up
  `herdr agent prompt <pane> "<task>"` keeps names meaningful.
- **Model and effort pass-through**: when the human names a model or an
  effort level, the orchestrator passes it via `--model` / `--effort`,
  independently; the script maps them to each CLI's flags. Unspecified
  means inherit — no flag is passed and the CLI's own settings apply.
  A value a kind or model cannot take is rejected, not silently ignored.
- **Cached model catalog**: model ids and effort levels come from
  `agent-models.sh`, which caches each CLI's answer, so dispatch never
  re-queries the CLIs and the orchestrator resolves names from one list.
- **Pull-based monitoring**: workers carry no reporting protocol;
  `herdr agent wait/read/prompt` is the interface.
- **Dispatch output is the startup confirmation**: the script already
  waits for agent readiness and prompt pickup, so after a clean
  `Dispatched to pane …` the orchestrator reports immediately — no extra
  `agent wait`/`read`. The pane is inspected only on a `Warning:`/`Error:`
  or when the human asks for status.
- **Stall recovery on prompt submit**: `herdr agent prompt` pastes the
  prompt + Enter "atomically", but TUI agents running bracketed paste
  can swallow the trailing Enter — the paste sits unsubmitted while
  herdr reports `agent_prompt_stalled`. The script recovers by sending
  a real `herdr pane send-keys <pane> Enter` and re-waiting; other
  failure modes (e.g. `agent_blocked`) are never nudged, since a stray
  Enter could accept a permission prompt.

## Responsibilities

- **Orchestrator**: workspace and worker lifecycle management, status
  checks on request. Does not perform the delegated work itself. Reports
  to the human in natural language — the orchestrator runs every herdr
  command itself; a command is quoted only when the human asks how to do
  it by hand.
- **Worker**: executes the task in its worktree; may use repo-local and
  global skills. It runs unconfined — staying inside the worktree is a
  convention, not enforced.

## Steering a worker

The orchestrator is not the worker's owner — it is the spawner. Once a
worker is running, the human can always talk to it directly: focus the
herdr tab and type, or `herdr agent prompt <pane> "<instruction>"` from
any shell.

Only caveat: avoid the human and the orchestrator prompting the same
worker concurrently — contexts interleave. In principle the side that
spawned the worker manages it, but human intervention is always allowed.

## Ownership and cleanup

A dispatched worktree belongs to its worker while follow-up work may be
routed there — the orchestrator never edits it directly. After the task is
done and the human approves, remove the worktree (and its branch, if the
worker created one) and close the tab.

## Security

Workers are launched with `herdr agent start` and run unconfined, with
the agent's own permission mode — no OS sandbox and no guard hooks
(ADR-0007).

## Testing

`tests/scripts/test-spawn-repo-agent.sh` stubs `gh` and `herdr` and
asserts the call sequence, the lowercase placeholder name, and the
prompt preamble.

## Notes

There is no in-process fallback for other repositories: when herdr is
unavailable the orchestrator reports that and does not dispatch. (Work on
the herdr-worktree repo itself is the exception — see the `development`
skill.)
