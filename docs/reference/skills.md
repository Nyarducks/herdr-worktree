---
type: Reference
title: Agent Skills
description: The slash-command skills shipped in .agents/skills and what each one orchestrates.
status: current
last_modified: 2026-11-04
tags: [skills, workflow]
sources: [.agents/skills]
---

# Agent Skills

Skills live canonically in `.agents/skills/<name>/SKILL.md`. Codex, Devin,
and Antigravity read `.agents/skills` natively; Claude Code sees the same
set via the `.claude/skills` symlink.

| Skill | Purpose |
|---|---|
| `development` | Must-follow rules and workflow for changing herdr-worktree itself (replaces a root `AGENTS.md`, ADR-0005): work directly in this checkout on a feature branch — implement, test, commit, push, open a PR. Also routes other-repo work to `worktree-development`. |
| `worktree-development` | Orchestrator mode for every other repository: confirm agent kind + repo with the user, then dispatch via `spawn-repo-agent.sh --reply-lang <human's language>` — a single call that goes all the way to a spawned worker in a fresh detached task worktree (one workspace per repo, one tab per task; task text optional — an idle spawn gets a standby prompt and is tasked later). Never stops at bare worktree creation; reports to the user in natural language, never raw commands to run. See `orchestration.md`. |
| `herdr-control` | Orchestrator mode for running workers: resolve the human's description of a worker (task, repo, name) to a pane with `list-workers.sh`, then focus it, relay an instruction (in English, after checking it is not busy or blocked), report status, or interrupt. Asks when several workers match. Language rule: think in English, reply in the human's language. |
| `git-operations` | Git discipline for herdr-worktree development only: clone via `gh`, branch from latest `main`, commit/PR conventions, PATCH-based PR edits. Used from `development`. |
| `workflow-shell-test` | Extract testable shell logic from GitHub Actions workflows and cover it with BATS. |

## Design intent

Skills encode *procedures* the orchestrator follows; they assume the
calling agent already sits at the lab root. A dispatched worker does **not**
receive these skills — it only sees the target repo's own `AGENTS.md`,
`.agents/skills`, and conventions.

## Frontmatter

Skills carry only `name` + `description`. `allowed-tools` is
deliberately unset: the spec field is experimental and tool
vocabularies/semantics differ per agent — Claude treats it as per-turn
pre-approval (not a restriction), Devin accepts a small lowercase tool
set, Antigravity uses its own `tools:` field, and Codex ignores
everything past `name`/`description`. Skill metadata enforces no
restrictions; herdr-worktree has no guard hooks (ADR-0007).
