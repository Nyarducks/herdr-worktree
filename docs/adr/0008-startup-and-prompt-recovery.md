---
type: ADR
title: Fail fast on startup errors; recover prompt submission, never into a dialog
description: spawn-repo-agent.sh polls the pane while the agent starts and fails on an Error line; a stalled prompt gets one Enter nudge and then one resend, both skipped when the pane shows a dialog.
status: accepted
last_modified: 2026-11-03
tags: [herdr, dispatch, reliability]
---

# ADR-0008: Fail fast on startup errors; recover prompt submission, never into a dialog

## Status

Accepted

## Context

- An agent CLI that exits at startup (unavailable model, bad flag, not
  logged in) never registers with herdr: `herdr agent start` waits out
  its 30s readiness timeout, and a `pane run` retry fails the same way.
- `herdr agent prompt` pastes and presses Enter, but TUI agents using
  bracketed paste can swallow the Enter, leaving the prompt unsubmitted
  (`agent_prompt_stalled` or a caller timeout).
- While an agent shows a selection or confirmation dialog (trust
  prompts, update prompts), herdr can report it as idle. An Enter nudge
  or a resent prompt then answers the dialog — a pi worker accepted its
  project-trust dialog this way.

## Decision

- While `herdr agent start` waits, the pane is polled every second; an
  `Error:` line printed after the launch command fails the dispatch at
  once with that line, without the `pane run` retry.
- On a stalled or timed-out prompt: send one real Enter
  (`herdr pane send-keys <pane> Enter`) and re-wait; if the agent is
  still plainly idle, resend the prompt once.
- Before either recovery step, the pane is checked for a dialog
  (`enter select/confirm/continue`, `esc skip`, trust and update
  prompts). If one is showing, nothing is sent and the script warns.
- Other errors are never nudged.

## Consequences

- A broken launch is reported in seconds with the CLI's own message.
- Swallowed Enters self-recover; the "submission was not confirmed"
  warning means something real broke.
- Dialogs are left for a human (or prevented up front, ADR-0009); the
  dialog check is a text heuristic and may need new patterns.
- The orchestrator inspects the pane after any `Warning:`, `Error:` or
  `Note:` line (`worktree-development` skill).
