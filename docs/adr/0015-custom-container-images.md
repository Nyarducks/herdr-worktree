---
type: ADR
title: Version the default container image; build custom images from git-ignored docker/<image>/ dirs
description: docker/default holds the versioned image; any other docker/<image>/ is a local, git-ignored image a container instance can be built from, named in the instance manifest.
status: accepted
last_modified: 2026-11-06
tags: [container, docker, multi-instance]
---

# ADR-0015: Version the default container image; build custom images from git-ignored docker/<image>/ dirs

## Status

Accepted

## Context

ADR-0013 ships one image. Different projects want different toolchains
in their container (a language runtime, a database client, a GPU
toolkit), and those images are personal or project-specific — they do
not belong in this repository, which other people use too. The
instance manifest (ADR-0014) already names what each container is.

## Decision

- The versioned image lives in `docker/default/` (`Dockerfile`,
  `sshd_config`, `entrypoint.sh`). `.gitignore` ignores every other
  directory under `docker/`.
- A custom image is a directory `docker/<image>/` with a `Dockerfile`.
  `container.sh image new <image> [--from <image>]` copies an existing
  one to start from. The Dockerfile reads its own directory from the build
  arg `HW_IMAGE_DIR`, so a copy works without edits.
- `compose.yml` builds `docker/${HW_IMAGE:-default}/Dockerfile` from the
  repository root. `container.sh up --image <image>` sets it and
  remembers it per environment; the manifest records it as `image`
  (`instance.sh add container --image`).
- A changed image is applied only by an explicit rebuild
  (`instance.sh rebuild`), never by `ensure`, because a rebuild recreates
  the container and stops its agents.

## Consequences

- Custom images stay on the machine that has them; another checkout does
  not see them.
- A custom image must keep the contract the scripts rely on: sshd on
  port 22 through the entrypoint, the user `dev`, `git`, `gh`, `jq`,
  `herdr`, and the checkout at `~/herdr-worktree`. `instance.sh ensure`
  and `container.sh check` report what is missing.
- The build context is the repository root, so a custom Dockerfile can
  copy anything in the checkout, including other `docker/<image>/` files.
