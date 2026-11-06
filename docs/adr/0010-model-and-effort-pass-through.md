---
type: ADR
title: Pass model and effort to workers; cache each CLI's model catalog
description: spawn-repo-agent.sh maps --model/--effort to each agent CLI's flags (inherit when omitted) and validates the effort against agent-models.sh, which caches the CLIs' model and effort lists.
status: accepted
last_modified: 2026-11-03
tags: [dispatch, models, worker]
---

# ADR-0010: Pass model and effort to workers; cache each CLI's model catalog

## Status

Accepted

## Context

Requests name a model and an effort level in loose terms ("haiku 5.5
medium", "flash"), and every agent CLI spells them differently: some
take an effort flag, some a config key, some encode the level in the
model id, and the valid levels differ per model. Querying the CLIs on
every dispatch is slow (network, login) and repeats the same answer.

## Decision

- `spawn-repo-agent.sh --model <m> --effort <e>` maps to each CLI:
  claude and agy `--model`/`--effort`; codex `--model` and
  `-c model_reasoning_effort="<e>"`; pi `--model`/`--thinking`; devin
  `--model` only (its level is part of the model id). Each flag is
  independent; omitted or `inherit` passes nothing, so the CLI's own
  settings apply.
- `agent-models.sh <kind> [models|efforts]` lists model ids (with
  per-model levels where the CLI reports them: codex's catalog, pi's
  `thinkingLevelMap`) and kind-wide effort levels, from a cache under
  `~/.cache/herdr-worktree/agent-models` refreshed after 7 days or with
  `--refresh`.
- The effort is validated against the chosen model's levels, else the
  kind-wide list; a value a kind or model cannot take is rejected, not
  ignored. Model ids are passed through.
- The orchestrator resolves names from `agent-models.sh`, never from the
  CLIs directly, and asks when several ids match.

## Consequences

- One cached list per kind; dispatch does not touch the network for
  model lookups.
- Lists can include models the account cannot use (devin lists
  plan-locked models); such a launch fails fast (ADR-0008).
- Claude Code has no list command; its aliases and ids are a built-in
  list to update when models change.
