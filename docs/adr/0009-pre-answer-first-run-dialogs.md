---
type: ADR
title: Pre-answer agent first-run dialogs for new worktrees
description: Before launching a worker, spawn-repo-agent.sh records the worktree as trusted for Claude Code, Antigravity and pi, and declines Claude Code's external CLAUDE.md imports; devin is launched with workspace trust off.
status: accepted
last_modified: 2026-11-03
tags: [dispatch, trust, worker]
---

# ADR-0009: Pre-answer agent first-run dialogs for new worktrees

## Status

Accepted

## Context

Every dispatch creates a fresh worktree path, and agent CLIs ask on the
first run in an unknown directory — a worker stuck at a dialog has not
started its task, and herdr can report it as idle (ADR-0008).

- Claude Code asks to trust the folder, and separately whether to allow
  `CLAUDE.md` imports that reach outside it.
- Antigravity asks to trust the workspace.
- pi asks to trust the project folder whenever a protected resource is
  found — including a `.agents/skills` in any parent directory, so the
  `.agents/skills` of herdr-worktree above a worktree triggers it. pi's
  skill discovery stops at the repository root (the worktree), so
  trusting the worktree loads only the repo's own resources.

## Decision

`ensure_trusted_workspace` writes, before launch:

- Claude Code: `~/.claude.json` → `projects[<wt>]` with
  `hasTrustDialogAccepted: true`, `hasClaudeMdExternalIncludesApproved:
  false`, `hasClaudeMdExternalIncludesWarningShown: true` (trusted, no
  external imports).
- Antigravity: `~/.gemini/antigravity-cli/settings.json` →
  `trustedWorkspaces`.
- pi: `${PI_CODING_AGENT_DIR:-~/.pi/agent}/trust.json` → `{<wt>: true}`.

Devin is launched with `--respect-workspace-trust false`. Merges are
atomic under a `mkdir` lock (ADR-0011).

## Consequences

- Workers start straight into their prompt.
- Entries accumulate in these files for removed worktrees; they are
  harmless and not cleaned up.
- A CLI that adds a new first-run dialog needs a new entry here; the
  dialog check of ADR-0008 keeps the dispatch from answering it blindly.
