---
type: ADR
title: Workers rename their own agent and tab
description: The dispatcher uses a w-<uuid> placeholder; the worker picks a task-derived name via herdr after reading the prompt.
status: accepted
last_modified: 2026-11-03
tags: [herdr, naming, worker]
---

# ADR-0004: Workers rename their own agent and tab

## Status

Accepted

## Context

The dispatcher cannot derive a meaningful agent name before the task is
understood — generated names like `w-<uuid>` mean nothing to the human
watching herdr. Only the worker knows what the task actually is.

## Decision

Agents spawn under the placeholder `w-<uuid>` (lowercase — herdr agent
names must match `[a-z][a-z0-9_-]{0,31}`). Every spawn sends a prompt
whose preamble tells the worker to run `herdr agent rename <pane> <slug>`
and `herdr tab rename <tab> <title>` once it understands the task, with
the pane and tab ids filled in. Without a task the prompt is a standby
instruction that keeps the same contract for a later
`herdr agent prompt`. A worker that skips the rename is still
addressable by pane id.

## Consequences

- Meaningful tab labels appear without the dispatcher parsing the task.
- Adds one short, self-contained responsibility to the worker prompt.
