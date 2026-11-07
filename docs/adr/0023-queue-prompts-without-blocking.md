---
type: ADR
title: Send prompts to a working worker at once; never block on its turn
description: A relayed prompt to a working worker is sent without asking and waits in the worker's queue; agent prompt is always called with --until working --until blocked, so the orchestrator returns as soon as the worker is working instead of waiting for its turn to end.
status: accepted
last_modified: 2026-11-08
tags: [orchestrator, herdr, worker]
---

# ADR-0023: Send prompts to a working worker at once; never block on its turn

## Status

Accepted. Replaces ADR-0012's rule that a working worker is prompted only
after the human chooses to queue or interrupt.

## Context

- ADR-0012 had the orchestrator ask the human, for a working worker,
  whether to queue the instruction (wait for idle, then send) or
  interrupt. Queueing that way kept the orchestrator waiting for the
  worker's turn to end.
- `worktree-development` gave the follow-up command as
  `herdr agent prompt <pane> "<task>" --wait --timeout 120000`. With a
  bare `--wait`, herdr matches `idle`, `done` or `blocked`, the end of the
  worker's turn. Sent to a busy worker, the call blocked for the full two
  minutes and then failed with `timeout`, although the prompt had been
  delivered.
- A busy Claude Code worker takes the pasted prompt into its queue and
  reads it at its next step, so it can steer the work in progress.
  Checked on a throwaway worker: a prompt sent while it was working
  returned at once with `--until working --until blocked`, and the
  worker answered it. A long-running worker took a relayed instruction
  between two steps of its current task.

## Decision

- A relayed instruction to a `working` worker is sent at once and waits
  in the worker's queue. The orchestrator interrupts first (`esc`) only
  when the human wants the current work stopped.
- Every `herdr agent prompt` from the skills, and the hint
  `spawn-repo-agent.sh` prints for an idle worker, uses
  `--wait --until working --until blocked`, with a short timeout. It
  returns when an idle worker picks the prompt up, and at once for a
  worker that is already working. A bare `--wait` is not used.
- After sending to a working worker, the orchestrator reads the screen
  once: the command returns at once whether or not the text was
  submitted, and TUI agents (claude, devin) can swallow the trailing
  Enter (ADR-0008). If the text sits in the input and no dialog is
  showing, it presses Enter once. It does the same after
  `agent_prompt_stalled` or `timeout`.
- The report to the human says the instruction was delivered and is
  read at the worker's next step.
- A blocked worker is unchanged: its question is shown to the human and
  never answered by the orchestrator.

## Consequences

- The orchestrator stays responsive while workers are busy; the human
  does not have to choose between queueing and interrupting.
- Queueing relies on the agent CLI taking input while it works; this was
  checked with Claude Code only. Submission to a working worker is not
  confirmed by herdr for any kind, hence the screen check.
- A queued instruction is not held until the current work ends: the
  worker reads it at its next step. The human interrupts only to stop
  the current work.
- Waiting for a worker to finish stays a separate, explicit step
  (`herdr agent wait`), used only when the human asks for the result.
