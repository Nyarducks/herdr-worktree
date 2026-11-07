---
name: instance-from-repo
description: Build the best-fitting herdr-worktree instance for a repository — read how the repository defines its environment (Nix flakes, devbox, mise, version files, devcontainer, CI setup steps and service containers), then pick the lightest instance that lets a worker use that environment as the repository intends: the default image, Docker inside when the repository runs containers, and a custom image under the git-ignored plugins/instances/docker/<image>/ only for what neither covers. Builds it and verifies inside before reporting. Use when the user asks for an instance, container or environment suited to a repository ("make an instance for owner/repo", "build a container that can run X's tests").
---

# Instance from a repository

Give a worker dispatched with `--machine` an instance where the
repository's own way of working runs: its dev shell, its `docker
compose`, its checks. Prefer the repository's definitions over copies of
them in an image — a copied version goes stale the day the repository
updates its lock file (ADR-0017). Report only after the instance is up
and the checks below pass inside it.

## 1. Settle the inputs

Ask (ask-question tool) for what the request leaves out; never guess:

- **Repository** — `owner/name`.
- **Instance name** (fixed: ssh alias, compose project; `^[a-z][a-z0-9-]*$`)
  and **label** (what herdr shows; default the name). Offer a name derived
  from the repository.
- **Port** — the next free one after the instances in `plugins/instances/bin/instance ls`.

## 2. Read the repository, don't clone it

Read through `gh api` (tree, then single files) on the host; the
repository may be private and the instance must not need its content to
be built. Note:

1. **Its dev environment** — `flake.nix`/`flake.lock`, `devbox.json`,
   `mise.toml`/`.tool-versions`, `.devcontainer/`, version files
   (`.python-version`, `.nvmrc`, `go.mod`, `rust-toolchain.toml`,
   `package.json` `engines`/`packageManager`).
2. **Its containers** — `compose*.y*ml`, Dockerfiles, CI `services:` and
   CI steps that call `docker`.
3. **Its checks** — the task-runner entries CI calls (`Taskfile.yml`,
   `Makefile`, `justfile`, `package.json` scripts) and what each needs.

[reference/sources.md](reference/sources.md) maps each source to what
the instance needs for it.

## 3. Choose the instance

Take the first rule that applies to each need:

| The repository… | The instance |
|---|---|
| defines its environment (flake, devbox, mise) | nothing to add — the worker enters it (`nix develop`, `devbox shell`, `mise install`); `/nix` and its caches persist per instance, so it downloads once |
| runs databases, emulators or tests with `docker`/`docker compose` (locally or as CI `services:`) | `--docker`: Docker inside through Sysbox, no `--privileged`; the worker uses the repository's compose files |
| needs a tool none of the above provides (system libraries, a CLI outside its environment, a runtime only pinned in CI) | a custom image: `plugins/instances/bin/instance image new <image>`, one fenced block in `docker/<image>/Dockerfile` (see the reference) |
| uses a CLI whose login lives outside the persisted paths | add its directory to `docker/<image>/persist` (ADR-0016), never a volume; a path under one already listed (`.config/…`) is kept already, and a parent added later is merged in |

Leave out by default and say so: browser e2e (Playwright browsers),
deployment-only tools (Terraform), anything the repository builds only
in CI. Never put credentials, tokens, private repository content or
customer data into an image; logins (`gh auth login`, the agent CLIs) stay
the user's, inside the instance.

## 4. Build and verify

```bash
plugins/instances/bin/instance add container <name> [--docker] [--image <image>] --label <label>
plugins/instances/bin/instance check <name>
```

`add` picks an SSH port no other container uses; pass `--port` only when
the user names one.

Run the build in the background (minutes on first use). Then, over
`ssh <name>`:

- with `--docker`: `docker info` answers, and the repository's service
  images (from its compose file or CI `services:`) run and answer on
  their ports — e.g. `docker run` the database image and wait for its
  readiness check; remove them afterwards;
- with a custom image: every tool of the block reports the expected
  version;
- with a Nix environment: `nix shell --offline …` of a fetched package
  still works after `docker rm -f <name>-dev-1` +
  `plugins/instances/bin/instance ensure <name>` (ensure recreates the
  container; the cache survives).

Fix and `plugins/instances/bin/instance rebuild <name>` until all pass.

## 5. Report

Say what the instance has and why (which rule above), what was left out,
and what the user does once inside it: log in to `gh` and the agent CLI —
only then can the private repository be cloned and its environment
entered. Offer to dispatch a worker there (`worktree-development`,
`--machine <label>`).
