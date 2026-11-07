---
type: ADR
title: Make multi-instance support a plugin, behind a small contract, written in TypeScript
description: herdr-worktree gets a plugin foundation (.plugins/<id> links, a 4-call contract); multi-instance support moves into plugins/instances, written in TypeScript run by Node.js, while core stays shell.
status: accepted
last_modified: 2026-11-06
tags: [plugin, multi-instance, typescript]
---

# ADR-0018: Make multi-instance support a plugin, behind a small contract, written in TypeScript

## Status

Accepted

## Context

Multi-instance support (ADR-0013 to ADR-0017) grew inside core: a
manifest, container and remote-host management, an awk YAML parser, and
`--machine` paths through `spawn-repo-agent.sh` and `list-workers.sh`. Not
every user needs it, and the user wants to add or remove it. In shell it
was hard to keep correct: a hand-written YAML subset, jq for every JSON
answer, ssh reading a loop's stdin (machines silently skipped), tests that
relied on stub executables on `PATH`.

herdr's own plugins (`herdr-plugin.toml`) are a herdr TUI feature; the
planned move to Herdr app (hc) changes how machines and spaces work, and
the contract of this feature belongs to herdr-worktree, which consumes it.

## Decision

- Core gets a plugin foundation: a plugin is a directory with an
  executable `bin/hw-plugin`, enabled by a git-ignored symlink
  `.plugins/<id>` (`scripts/plugins.sh enable|disable|ls|machines`).
  Contract version 1 has four calls: `describe`, `machines`, `ensure
  <machine>`, `exec <machine> -- <cmd…>` (`scripts/lib/plugins.sh`). With
  no plugin enabled core works on this machine only.
- Multi-instance support moves to `plugins/instances/` in this repository
  for now (to be split into its own repository once the contract settles):
  its CLI `bin/instance`, the manifest, `docker/`, `compose.yml`, and the
  skills `instances` and `instance-from-repo`. Core's skills only point to
  the skills a plugin describes.
- The plugin is TypeScript, run by Node.js ≥ 24 through type stripping (no
  build step; erasable syntax only), with one dependency (`yaml`). External
  commands go through one `Runner`, so tests use an in-memory world.
  Core — which also runs inside the instances — stays shell.
- No `herdr-plugin.toml` for now; it can be added to the same directory for
  TUI-only conveniences (startup ensure, a popup) if wanted.

## Consequences

- A user without other machines never installs Node.js dependencies or
  sees instance commands; `scripts/plugins.sh disable instances` removes
  the feature without touching containers, volumes or the manifest.
- The manifest is checked field by field with line numbers, the ssh-stdin
  class of bug is closed by the runner (stdin closed unless input is
  given), and one instance failing in `ensure` no longer stops the rest.
- The images are built with the checkout as the context and the image
  directory as a named context (`COPY --from=image`), so the plugin can
  later live outside the checkout.
- Hosts that run the plugin need Node.js ≥ 24 and npm.
