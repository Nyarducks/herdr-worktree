---
type: ADR
title: No sandbox and no guard hooks
description: Workers and the orchestrator run with their agent's own permission mode; herdr-worktree ships no OS sandbox, no PreToolUse guard hooks and no path allowlist.
status: accepted
last_modified: 2026-11-03
tags: [security, worker, simplification]
---

# ADR-0007: No sandbox and no guard hooks

## Status

Accepted

## Context

Confining workers with an OS sandbox (bubblewrap / Seatbelt) and the
orchestrator with `PreToolUse` guard hooks and a `.env` path allowlist
got in the way of the goal — a simple worktree per task: workers had to
be launched through generated command lines, dispatch failed without a
sandbox backend, the orchestrator's own edits were blocked, and every
agent CLI needed its own hook format.

## Decision

herdr-worktree confines nothing. Workers launch through
`herdr agent start` with the agent's own permission mode (claude
`--permission-mode auto`, agy `--dangerously-skip-permissions`, devin
`--permission-mode dangerous`); the orchestrator runs with its own.
There are no hook scripts, no hook registrations and no `.env`.

## Consequences

- Workers can read and write anywhere the user can; staying inside the
  worktree and never editing `repos/` are conventions.
- No platform sandbox tool, `realpath -m` or `.env` is required.
- Safety relies on each agent CLI's permission model and on review of
  the resulting PRs.
