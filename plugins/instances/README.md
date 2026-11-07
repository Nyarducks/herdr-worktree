---
type: Reference
title: Instances plugin
description: The herdr-worktree plugin that keeps dev containers and remote hosts as instances — the manifest, the instance CLI, the container image, Docker inside, and the contract core calls.
status: current
last_modified: 2026-11-07
tags: [plugin, instances, container, multi-instance]
sources: [plugins/instances/src, plugins/instances/bin, plugins/instances/docker, plugins/instances/compose.yml, plugins/instances/instances.example.yml, plugins/instances/package.json]
---

# Instances plugin

Lets one orchestrator dispatch to and steer workers on other machines: dev
containers it builds and starts itself, and remote hosts reached over ssh
that the user runs. It keeps them in a manifest and brings a stopped
container back when core needs it (ADR-0014, ADR-0018).

Core works without it: with the plugin disabled, `spawn-repo-agent.sh
--machine` and the machine rows of `list-workers.sh` are simply not there,
and herdr shows none of its machines.

## Enable, disable

```bash
scripts/plugins.sh enable instances    # npm ci on first use, then .plugins/instances
scripts/plugins.sh disable instances   # takes its machines out of herdr, then removes the link
```

Disabling removes each instance's herdr machine and names every container
still running, with the command that stops it (`docker compose -p <name>
stop`); the manifest, containers and volumes stay. Enabling again brings
the same machines back: a stopped container is started and each is
registered again. One that cannot come back (a remote host that is down)
is reported with the usual steps and comes back on the next enable or
`instance ensure` (ADR-0022).

Needs Node.js ≥ 24 (it runs the TypeScript sources directly, without a
build step) and npm for the one dependency (`yaml`). Inside the instances
only core runs, which needs no Node.js.

## Use

```bash
plugins/instances/bin/instance add container dev-a                 # build, start, add to herdr
plugins/instances/bin/instance add container dev-c --docker        # Docker inside (Sysbox)
plugins/instances/bin/instance add remote build-box dev@192.0.2.10 # a host you run yourself
plugins/instances/bin/instance ensure                              # bring stopped containers back
plugins/instances/bin/instance ls
plugins/instances/bin/instance rename dev-a client-b               # the name herdr shows
plugins/instances/bin/instance check dev-a                         # smoke checks inside
plugins/instances/bin/instance --help                              # every argument and option
```

`spawn-repo-agent.sh --machine <label>` and `list-workers.sh` call the
plugin through its contract (below), so a stopped container also comes
back when the orchestrator dispatches to it or lists workers. A remote
host is never started: `ensure` prints what to start or install on it.

## Manifest

`plugins/instances/instances.yml` (git-ignored; `HW_INSTANCES_FILE`
overrides). The first write copies `instances.example.yml` — comments only
but for the `instances:` line, explaining every field with examples — and
every rewrite keeps the comments above `instances:`. It is read with a YAML
parser and checked field by field: an unknown field, a wrong type or a
nested value stops every command with `instances.yml:<line>: <reason>`.

| Field | Kind | Required | Default | Meaning | A hand edit applies |
|---|---|---|---|---|---|
| `name` | both | yes | — | Fixed id: ssh Host alias, herdr machine target, compose project. `^[a-z][a-z0-9-]{0,31}$` | never — `rm`, then `add` under the new name |
| `kind` | both | yes | — | `container` (built and started here) or `remote` (run by the user; never started here) | never — `rm`, then `add`; a container must go with `rm --purge` before its name becomes a remote host |
| `label` | both | no | `name` | herdr's sidebar name; used by `--machine` and the `<label>/<pane>` rows. 1–64 characters, no spaces, `/` or `\|`, unique among herdr's machines and the manifest, ignoring case (a manifest using one twice is refused) | edit it, `rename`, or rename the machine in herdr: the next `ensure`/`ls` brings the other side along — the side that changed since they last agreed (`~/.config/herdr-worktree/labels.json`) wins, the manifest when both did or nothing is recorded; a label herdr cannot take is reported and left in the manifest |
| `port` | container | no | `add`: `2222`, or the next port no other container uses | SSH port published on `127.0.0.1`, one per container (`add --port` refuses one in use) | `rebuild` |
| `image` | container | no | `default` | Build directory `docker/<image>/` (ADR-0015) | `rebuild` (recreates the container; `ensure` notes it) |
| `docker` | container | no | `false` | `true`: a Docker daemon inside through Sysbox (ADR-0017) | `rebuild` (recreates the container; `ensure` notes it) |
| `host` | remote | yes | — | IP address or host name | next `ensure`/`ls` (ssh config is regenerated) |
| `port` | remote | no | `22` | SSH port | next `ensure`/`ls` |
| `user` | remote | no | ssh's default | SSH user | next `ensure`/`ls` |
| `identity` | remote | no | ssh's keys and agent | Private key file on this machine, absolute path without spaces, quotes or backslashes (it goes into an ssh config) | next `ensure`/`ls` |
| `dir` | remote | no | `~/herdr-worktree` | herdr-worktree checkout on the host, where core's scripts run (`~` expands there) | at once |

State outside the manifest: containers in
`~/.config/herdr-worktree/containers/<name>/` (key, ssh config, the port,
image and docker it was built with; `HW_CONTAINER_DIR`), remote hosts'
ssh entries in `~/.config/herdr-worktree/remotes/` (`HW_REMOTES_STATE_DIR`).
Both are included from the top of `~/.ssh/config`, so `ssh <name>` and
herdr reach every instance.

## The container

`compose.yml` builds `docker/<image>/Dockerfile` with the herdr-worktree
checkout as the build context (it is copied to `/home/dev/herdr-worktree`)
and `docker/<image>/` as a second context named `image`, from which the
Dockerfile copies `sshd_config`, `persist` and `entrypoint.sh`
(`COPY --from=image`). One service, `dev`, reachable over SSH so that the
herdr here can add it as a machine (ADR-0013).

### Installed

| Tool | Source | Pinned by |
|---|---|---|
| Ubuntu | `ubuntu:<UBUNTU_VERSION>` | build arg, default `26.04` |
| `git` | git-core PPA | latest at build time |
| `gh` | GitHub CLI apt repository | latest at build time |
| Docker Engine, compose and buildx plugins | Docker's apt repository | latest at build time |
| `jq`, `bats` (the checkout's shell tests), `openssh-server`, `sudo`, `curl`, `xz-utils`, `libatomic1` (Node.js needs it) | Ubuntu archive | latest at build time |
| Node.js (with npm) | nodejs.org tarball, checked against `SHASUMS256.txt` | build arg `NODE_VERSION`, default 26 LTS |
| `herdr` | `https://herdr.dev/install.sh` into `/usr/local/bin` | none — the installer takes the current stable release |
| Nix | single-user install, no daemon, no channel (`--no-channel-add`: flakes pin their own nixpkgs, and the channel alone is about 490 MB; `nix-shell -p` and `<nixpkgs>` do not resolve); flakes enabled in `/etc/nix/nix.conf` | build arg `NIX_VERSION` |
| Claude Code | `https://claude.ai/install.sh` into `~/.local` | none — the installer takes the current release |

The working user is `dev` (build args `USERNAME`, `USER_UID`,
`USER_GID`) with passwordless `sudo`, in the `docker` group. The top of
`~/.bashrc` puts Nix and `~/.local/bin` on `PATH` and exports
`CLAUDE_CONFIG_DIR=~/.claude`, so non-interactive SSH commands and herdr's
panes see them too. Log in inside the instance yourself (`gh auth login`,
`claude` then `/login`); logins are never copied in.

### SSH

`docker/default/sshd_config` allows only public-key login for the working
user; root and passwords are refused. The plugin writes the instance's
public key to `/etc/ssh/authorized_keys/dev` through `docker compose exec`
stdin after every start — nothing is bind-mounted from the host, and
`docker cp` fails on sysbox-runc containers. Host keys are generated by the
entrypoint on first start into the `ssh-host-keys` volume, so a rebuilt
container keeps its identity; the plugin pins it before `herdr machine add`
(herdr runs ssh with `StrictHostKeyChecking=yes`). The port is published on
`127.0.0.1` only.

### What persists

| Volume | Mounted at | Holds |
|---|---|---|
| `repos` | `/home/dev/herdr-worktree/repos` | base clones |
| `worktree` | `/home/dev/herdr-worktree/worktree` | task worktrees |
| `state` | `/home/dev/.persist` | logins and settings: every path in `docker/<image>/persist` (default `.config` — `gh`, herdr —, `.claude`, `.codex`, `.gemini`, `.pi`, and Nix's `.local/state/nix` and `.cache/nix`) is a symlink into it |
| `nix` | `/nix` | the Nix store: what `nix develop` downloaded stays across rebuilds |
| `docker` | `/var/lib/docker` | the inner Docker's images and containers (`docker: true`) |
| `ssh-host-keys` | `/etc/ssh/host_keys` | sshd host keys |

Everything else, including the herdr-worktree checkout, comes from the
image: `rebuild` to pick up a newer checkout. At every container start the
entrypoint links each path of `/etc/herdr-worktree/persist` and of
`~/.persist/persist.list` (the instance's own additions) into the `state`
volume (ADR-0016): to keep a new CLI's login, add its directory there —
never a volume, and never a single file: a file, or a path that is a link
elsewhere, is refused. A path under one already listed (`.config/gh` under
`.config`) is kept already and is skipped with a note. Adding a parent of
a listed path later (`.local`, above `.local/state/nix`) is safe: on its
first use what the image put there is merged in. `rm --purge` deletes the volumes, and with them every login
of that instance; it also takes the name of a container already removed
without it (refused while that name is another instance's label).

### Custom images

`docker/default/` is versioned; every other directory under `docker/` is
git-ignored and holds a local image (ADR-0015):

```bash
plugins/instances/bin/instance image new mytools     # copy docker/default to docker/mytools/
$EDITOR plugins/instances/docker/mytools/Dockerfile
plugins/instances/bin/instance add container dev-b --image mytools
```

A copy needs no path edits (`COPY --from=image`). Keep what the plugin
relies on: sshd on port 22 through the entrypoint, `persist` copied to
`/etc/herdr-worktree/persist`, `~/.persist`, the user `dev`, `git`, `gh`,
`jq`, `herdr`, Docker Engine (for `docker: true`) and the checkout at
`~/herdr-worktree`; `ensure` and `check` report what is missing. Prefer the
repository's own environment (its flake, devbox or mise) over baking its
toolchain into an image (the `instance-from-repo` skill).

### Docker inside

`docker: true` (`add container --docker`) runs the container with the
`sysbox-runc` runtime — no `--privileged`, its root is not the VM's root —
and the entrypoint starts `dockerd` (ADR-0017). Without Sysbox on the
Docker host it fails rather than falling back to `--privileged`. With
colima, in `~/.colima/<profile>/colima.yaml`:

```yaml
docker:
  runtimes:
    sysbox-runc:
      path: /usr/bin/sysbox-runc
provision:
  - mode: system
    script: |
      set -eu
      command -v sysbox-runc >/dev/null 2>&1 && exit 0
      v=0.7.1; a="$(dpkg --print-architecture)"
      curl -fsSLo /tmp/sysbox-ce.deb "https://github.com/nestybox/sysbox/releases/download/v${v}/sysbox-ce_${v}.linux_${a}.deb"
      DEBIAN_FRONTEND=noninteractive apt-get update -q
      DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq /tmp/sysbox-ce.deb
mounts:              # replaces colima's default writable home mount
  - location: ~/.colima/no-host-mounts   # an empty directory
    writable: false
```

then `colima stop && colima start`. The plugin bind-mounts nothing from the
host, so the VM needs no access to the home directory; keep it that way,
since a container that escaped would otherwise reach it.

## Contract (core ↔ plugin)

Core finds the plugin through `.plugins/instances` and calls
`bin/hw-plugin` (contract version 1, `scripts/lib/plugins.sh`):

| Call | Answer |
|---|---|
| `describe` | JSON `{id, name, version, contract, skills[], hooks}`; `hooks` is `["enable", "disable"]` |
| `machines` | JSON `[{label, target, dir, registered}]` — every manifest instance, with herdr's current label |
| `ensure <name-or-label>` | exit 0 when usable; messages on stderr |
| `exec <name-or-label> -- <cmd> [args...]` | `ssh <name> "cd <dir> && HERDR_ENV=1 <cmd …>"` (each argument quoted); output and exit status pass through; stdin closed |
| `disable` | removes each instance's herdr machine (its label synced first), records them in `~/.config/herdr-worktree/unregistered.json`, names the containers still running; exit 1 when a machine could not be removed |
| `enable` | ensures the recorded instances and forgets the ones back; exit 1 when one could not come back (it stays recorded) |

## Development

```bash
cd plugins/instances
npm ci
npm run check      # tsc --noEmit (strict, erasable syntax only) and node --test
```

The sources are TypeScript run by Node.js's type stripping, so they use
only erasable syntax (no enums, namespaces or parameter properties). Every
external command goes through one `Runner` (`src/proc.ts`); the tests
replace it with an in-memory world of herdr machines, ssh answers and
compose projects (`test/helpers.ts`) — no stub executables on `PATH`.
