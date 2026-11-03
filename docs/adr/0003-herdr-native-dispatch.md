---
type: ADR
title: Dispatch workers through herdr-native workspaces, tabs and panes
description: One herdr workspace per repo, one tab per task, the worker in the tab's root pane; work on other repositories is always dispatched, after the agent kind and repository are confirmed.
status: accepted
last_modified: 2026-11-03
tags: [herdr, dispatch, orchestrator]
---

# ADR-0003: Dispatch workers through herdr-native workspaces, tabs and panes

## Status

Accepted

## Context

Wrapping herdr with custom ownership and reporting state duplicates what
herdr already tracks and breaks whenever herdr's model evolves. Letting
the orchestrator edit other repositories in-process, or silently pick
an agent kind or repository, makes it unclear who did what.

## Decision

- Dispatch maps onto herdr's own model: one workspace per repo (matched
  by label), one tab per task, the worker agent in the tab's root pane.
  `spawn-repo-agent.sh` is the single entry point and runs the whole
  sequence — worktree, tab, agent, prompt.
- Workers start with `cwd` = their worktree, so the target repo's own
  `AGENTS.md`/`CLAUDE.md` and `.agents/skills` apply; they learn nothing
  about herdr-worktree.
- Workers carry no reporting protocol: monitoring is pull-based
  (`herdr agent wait`, `read`, `prompt`).
- Work on any repository other than herdr-worktree is always dispatched
  (`worktree-development` skill); there is no in-process fallback when
  herdr is unavailable. When a request omits the agent kind or the
  repository, the orchestrator asks before dispatching.

## Consequences

- No herdr-worktree-side state to keep in sync; follow-ups and
  inspection use standard herdr commands.
- Requires the herdr CLI and an active session for any work on other
  repositories.
