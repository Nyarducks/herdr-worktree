---
type: Reference
title: Agent config directories
description: Which config directory each supported agent CLI reads, and what lives there.
status: current
last_modified: 2026-11-06
tags: [agents, config, reference]
sources: [.claude, .agents]
---

# Agent config directories

herdr-worktree ships no hooks for any agent (ADR-0007); the config dirs
carry skills and settings only. Codex and Devin CLI need no dir of their
own — they read `.agents/skills/` natively.

| Directory | Agent | Defines |
|---|---|---|
| `.claude/` | Claude Code | `skills` → symlink to `../.agents/skills` |
| `.agents/` | Antigravity (+ Codex, Devin for skills) | `settings.json`; canonical `skills/` |

Notes:

- `.agents/skills/` is canonical — Codex, Devin, Antigravity read it
  natively; `.claude/skills` is a symlink (ADR-0005). Dispatching work to
  other repos lives solely in the `worktree-development` skill —
  `spawn-repo-agent.sh` is the single entry point — task text optional;
  an idle spawn still receives a standby prompt carrying the self-naming
  contract, and user-facing reports stay natural-language (the
  orchestrator runs herdr itself). Steering workers that are already
  running (focus, relayed instructions, status, interrupt) — here or on
  another herdr machine — lives in the `herdr-control` skill; waiting for
  a worker treats `done` (finished, not yet seen) like `idle`. See
  `orchestration.md`.
- There is no root `AGENTS.md`/`CLAUDE.md`: the rules for changing
  herdr-worktree live in the
  `development` skill so they never reach workers through parent-directory
  context loading (ADR-0005).
- Live-verified for dispatch (`--kind`): Claude Code, Devin CLI,
  Antigravity, pi. Codex CLI flags are implemented but not live-verified
  (no account). Model/effort flags per kind: see `spawn-repo-agent.sh`
  in [scripts.md](scripts.md).
