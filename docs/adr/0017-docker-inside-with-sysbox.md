---
type: ADR
title: Run Docker inside an instance with Sysbox, never --privileged, and mount nothing from the host
description: Instances that need Docker run with the sysbox-runc runtime and their own dockerd; the Docker VM mounts no host directory, the ssh key goes in through exec stdin, and the Nix store and caches persist per instance.
status: accepted
last_modified: 2026-11-06
tags: [container, docker, security, multi-instance]
---

# ADR-0017: Run Docker inside an instance with Sysbox, never --privileged, and mount nothing from the host

## Status

Accepted

## Context

Repositories run their databases, emulators and integration tests with
their own `docker compose`; a worker in an instance should do the same
instead of an image re-creating them. The usual ways to get Docker in a
container either hand over the host daemon (mounting `docker.sock`) or
need `--privileged` (the devcontainers `docker-in-docker` feature sets
it). Both reach the Docker VM's root, and the VM (colima) mounted the
user's home directory writable — so one unconfined worker (ADR-0007)
could reach the Mac's credentials and every other instance's volumes.

Instances also re-downloaded everything `nix develop` needed whenever a
container was recreated, because `/nix` lived in the image.

## Decision

- An instance asks for Docker with `--docker` (manifest `docker: true`).
  It then runs with the `sysbox-runc` runtime (user-namespaced, no
  `--privileged`), the entrypoint starts `dockerd`, and the inner images
  live in the instance's `docker` volume. Without Sysbox on the Docker
  host, `--docker` fails; there is no privileged fallback.
- The Docker VM mounts no host directory (colima: an empty read-only
  mount replaces the default home mount). The instance's public key goes
  in through `docker compose exec` stdin after every start (`docker cp`
  fails on sysbox-runc containers).
- `/nix` is a per-instance volume, and `~/.local/state/nix` (profiles) and
  `~/.cache/nix` (fetched flake sources) are persisted paths (ADR-0016):
  the store survives rebuilds and stays consistent with the profiles.
- Images do not pre-install a repository's toolchain when the repository
  defines it (flake, devbox, mise): workers use the repository's own
  environment, now cached in `/nix`.

## Consequences

- Sysbox must be installed in the Docker VM once (colima `provision`, so a
  recreated VM gets it again) and the runtime registered (colima `docker.runtimes`).
- A Docker instance's inner containers cannot reach the Mac or other
  instances through the VM.
- Nothing on the Mac can be bind-mounted into instances; the scripts do
  not need it.
- The Nix version inside an instance is the one its `nix` volume was
  created with; `--purge` resets it.
