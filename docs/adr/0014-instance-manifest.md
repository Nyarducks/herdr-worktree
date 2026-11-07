---
type: ADR
title: Keep herdr-worktree instances in a git-ignored manifest and bring them back when they stop
description: Dev containers and remote hosts are listed in instances.json; a stopped container is restarted automatically, a remote host is only explained; each instance has a fixed name and a herdr label that may be renamed.
status: accepted
last_modified: 2026-11-06
tags: [multi-instance, container, remote, herdr]
---

# ADR-0014: Keep herdr-worktree instances in a git-ignored manifest and bring them back when they stop

## Status

Accepted

## Context

With several instances (ADR-0013 containers, other hosts over SSH) an
orchestrator dispatches to and lists workers on each of them. An instance
that has stopped — a container after a reboot, a herdr server that died —
silently drops out: `list-workers.sh` skips it and `--machine` dispatch
fails. herdr's own machine list says nothing about how to start an
instance, and some instances (remote hosts) are not ours to start.

herdr shows each machine under a label the human may rename in its
sidebar or with `herdr machine rename`; the ssh target stays.

## Decision

- Record each instance in `instances.json` at the checkout root,
  git-ignored (it holds host addresses), managed by `scripts/instance.sh`.
  `instances.example.json` shows the shape.
- An instance has a fixed **name** — the ssh Host alias, the herdr machine
  target and a container's compose project — and a **label**, the herdr
  machine label, free to change. Scripts find a machine by its target;
  `--machine` accepts the label or the name; worker rows use the label.
  A label renamed in herdr is adopted by the manifest.
- `instance.sh ensure` brings instances back: a **container** is started
  (built only if it never was; never rebuilt, since a rebuild recreates a
  running container) and its herdr server started; a **remote host** is
  never started — the script prints what is missing (ssh, tools, the
  checkout, the herdr server) and how to fix it, for the human to act on.
- `spawn-repo-agent.sh --machine` ensures the instance first;
  `list-workers.sh` ensures an instance that does not answer, once,
  before skipping it.

## Consequences

- A container that stopped comes back the next time an orchestrator
  dispatches to it or lists workers, at the cost of a few seconds then.
- A remote host stays the human's to run; the orchestrator relays the
  printed steps.
- Remote hosts' ssh entries are generated (`~/.config/herdr-worktree/remotes`)
  and included from `~/.ssh/config` like the containers'; a new host key
  is pinned on first contact (accept-new).
- Machines added to herdr by hand still work with `--machine` and
  `list-workers.sh`, but are not restarted.
