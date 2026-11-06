---
type: ADR
title: Think in English, reply in the human's language; steer workers by natural-language reference
description: The orchestrator and workers reason in English and answer the human in the human's language (passed to workers with --reply-lang); the herdr-control skill resolves "the X worker" to a pane via list-workers.sh before focusing, prompting or reading it.
status: accepted
last_modified: 2026-11-04
tags: [orchestrator, worker, herdr, language]
---

# ADR-0012: Think in English, reply in the human's language; steer workers by natural-language reference

## Status

Accepted

## Context

The human talks to the orchestrator in their own language (often not
English) and may read or type into a worker's pane directly. Nothing set
a language: workers answered in whatever language the English dispatch
prompt suggested, so the human read English output while the
orchestrator answered in another language.

The orchestrator could already dispatch, wait, read and prompt, but only
by pane id. The human refers to workers by what they do ("the DB role
worker", "the billing task") and asks for herdr actions such as moving
to a worker's pane. Workers rename themselves (ADR-0004), so names alone
are not stable keys, and no procedure covered resolving a description
to a pane or handling a worker that is busy or blocked.

## Decision

- **Language contract**: the orchestrator and workers think in English
  and reply to the human in the human's natural language. Prompts to
  workers are written in English, with quoted text and identifiers kept
  verbatim.
- `spawn-repo-agent.sh --reply-lang <language>` puts the reply language
  into the worker's prompt preamble (task and standby). Without it, the
  preamble tells the worker to reply in the language the human writes
  in. The orchestrator always passes it.
- A new `herdr-control` skill covers steering running workers: focus,
  relay, status, interrupt. New dispatches stay in
  `worktree-development`.
- `list-workers.sh [query...]` lists agents running in task worktrees
  (pane, name, repo, state, tab label, terminal title) and filters them
  by query words. One match is acted on; several are put to the human;
  the pane id is re-resolved each time rather than cached.
- A working worker is prompted only after the human chooses to queue or
  interrupt; a blocked worker's dialog is shown to the human, never
  answered by the orchestrator.

## Consequences

- The human sees one language across orchestrator replies and worker
  panes; reasoning and prompts stay in English.
- Language is a prompt instruction, not enforced; an agent may drift,
  and a human who switches languages mid-task needs a relayed
  "reply in <language> from now on".
- The orchestrator's rules still live in on-demand skills (ADR-0005), so
  the language contract applies once `worktree-development` or
  `herdr-control` is loaded.
- Worker resolution depends on herdr's `agent list` fields (`cwd`,
  `name`, `terminal_title`) and `tab list` labels.
