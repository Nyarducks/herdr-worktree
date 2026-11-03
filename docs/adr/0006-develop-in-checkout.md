---
type: ADR
title: Develop herdr-worktree in its own checkout on a feature branch
description: Changes to herdr-worktree are made by the orchestrator directly in this checkout on a feature branch; only other repositories go through dispatched worktrees.
status: accepted
last_modified: 2026-11-03
tags: [orchestrator, workflow]
---

# ADR-0006: Develop herdr-worktree in its own checkout on a feature branch

## Status

Accepted

## Context

herdr-worktree is the one repository the orchestrator changes itself:
its scripts and skills are what the orchestrator runs, and a dispatched
worker would know nothing about them. Creating a worktree of this
repository for every change added setup, path juggling and a second copy
of the scripts for no isolation benefit — only one orchestrator edits it.

## Decision

The orchestrator changes herdr-worktree directly in this checkout:
branch from the latest `main` (`feat/`, `fix/`, `refactor/`), implement
with tests and docs, commit, push, open a PR (`development` and
`git-operations` skills). Commits to `main` are blocked by the
pre-commit hook; humans approve and merge PRs.

## Consequences

- One herdr-worktree topic at a time per checkout; uncommitted work must
  be finished or set aside before switching topics.
- `repos/` and `worktree/` may sit inside the checkout as gitignored lab
  directories and are never staged.
