---
type: ADR
title: Ship an Ubuntu development container reachable over SSH
description: The repository builds its own Ubuntu image (git, gh, jq, herdr, sshd, Nix, Node.js LTS) with compose, so each container is a separate herdr-worktree environment that herdr adds as an SSH machine.
status: accepted
last_modified: 2026-11-06
tags: [container, docker, multi-instance]
---

# ADR-0013: Ship an Ubuntu development container reachable over SSH

## Status

Accepted

## Context

Workers for different projects or Git accounts should run in separate
environments, so that credentials, runtimes and clones do not mix. The
parts of herdr-worktree that touch the environment — cloning
(`setup-repo.sh`), creating worktrees and linking hooks
(`create-worktree.sh`), pre-trusting worktrees for agent CLIs, reading
agent model catalogs — must run where the worker runs. A herdr TUI reaches
another environment only as a saved SSH machine (`herdr machine add`), and
that environment needs its own herdr server.

## Decision

- Provide `docker/Dockerfile` and `compose.yml` in this repository. The
  image is Ubuntu (LTS by default) with `git` and `gh` from their upstream
  apt repositories, `jq`, `herdr`, `openssh-server`, single-user Nix with
  flakes, and Node.js LTS from the official tarball.
- Copy this checkout into the image, so a container carries the same
  herdr-worktree as the host it was built from.
- Reach the container over SSH with public keys only; the port is
  published on loopback. Keep host keys, base clones, worktrees and
  `~/.config` in named volumes.
- One compose project is one environment. Several environments run side
  by side with different project names and ports.

## Consequences

- An environment can be built from a checkout alone; the README's
  per-tool install steps stay for running herdr-worktree on a host.
- A rebuilt image picks up the checkout it was built from; the volumes
  keep clones and worktrees across rebuilds.
- `herdr` is not pinned: the installer always takes the current stable
  release, so two builds can differ. herdr's machine forwarding needs
  API-compatible servers on both sides.
- Agent CLIs and their logins are not in the image; they are installed per
  environment.
