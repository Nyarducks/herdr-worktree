---
type: ADR
title: Canonical .agents/skills; no root AGENTS.md or CLAUDE.md
description: Skills live in .agents/skills (symlinked for Claude Code); the rules for changing herdr-worktree live in the development skill, because agents load root context files from every parent directory of a worker's worktree.
status: accepted
last_modified: 2026-11-03
tags: [agents, skills, context]
---

# ADR-0005: Canonical .agents/skills; no root AGENTS.md or CLAUDE.md

## Status

Accepted

## Context

Several agent CLIs drive this repository (Claude Code, Codex, Devin,
Antigravity, pi). Codex, Devin, Antigravity and pi read `.agents/skills`
natively; Claude Code reads `.claude/skills`.

Dispatched worktrees live under `worktree/`, which can sit inside this
checkout. pi loads `AGENTS.md`/`CLAUDE.md` from the working directory and
every parent directory, regardless of project trust, so a root
`AGENTS.md` here reached pi workers — breaking the rule that a worker
sees only its target repo's conventions. Claude Code reached the same
file through a root `CLAUDE.md` (`@AGENTS.md`) and stopped at its
external-imports dialog.

## Decision

- `.agents/skills/<name>/SKILL.md` is canonical; `.claude/skills` is a
  symlink to it.
- There is no root `AGENTS.md` or `CLAUDE.md`. The must-follow rules for
  changing herdr-worktree live in the `development` skill, which the
  orchestrator loads before editing this repository. Routing between
  developing herdr-worktree and dispatching other work is carried by the
  `development` and `worktree-development` skill descriptions.

## Consequences

- No rule file sits above a worker's worktree; workers load only their
  repo's own context files.
- The rules apply when the orchestrator loads the `development` skill,
  not in every session.
- pi's trust check still sees `.agents/skills` above a worktree; see
  ADR-0009.
