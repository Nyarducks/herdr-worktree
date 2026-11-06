---
type: ADR
title: One detached git worktree per dispatched task; base clones never edited
description: Each dispatched task gets worktree/<repo>/task/<uuid> on a detached HEAD at origin/main; repos/ holds base clones that are never edited.
status: accepted
last_modified: 2026-11-03
tags: [worktree, isolation, dispatch]
---

# ADR-0002: One detached git worktree per dispatched task; base clones never edited

## Status

Accepted

## Context

Concurrent tasks on a shared checkout collide on branch state, index and
uncommitted files; separate clones waste setup and lose a shared base.
A dispatcher also cannot name a branch before the worker has understood
the task, and a worker knows nothing about herdr-worktree's naming
conventions.

## Decision

- `repos/<repo>` is a base clone (imported and fast-forwarded by
  `setup-repo.sh`) and is never edited.
- Every dispatched task gets its own worktree,
  `worktree/<repo>/task/<uuid>`, created by `create-worktree.sh --detach`
  on a **detached HEAD at `origin/main`**. The uuid leaf keeps concurrent
  dispatches collision-free; no branch is named up front — the worker
  names one if and when it needs it.

## Consequences

- Unlimited parallel tasks per repo at negligible disk cost; `repos/`
  stays clean and shareable.
- Isolation is a convention, not enforced (ADR-0007).
- Finished task worktrees are removed by the orchestrator after the human
  approves.
