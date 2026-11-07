---
type: Design Doc
title: Plugins — optional features behind a small contract
description: Why herdr-worktree has plugins, how core and a plugin divide the work, how plugins are enabled, the contract (version 1) core calls through bin/hw-plugin, how plugin skills reach the orchestrator, and what a new plugin needs.
status: current
last_modified: 2026-11-07
tags: [plugins, contract, design]
sources: [scripts/plugins.sh, scripts/lib/plugins.sh]
---

# Plugins

A plugin adds optional features to herdr-worktree without changing core.
Today the one kind of plugin is a **machine provider**: it gives core other
machines (dev containers, remote hosts) to dispatch workers to and list
them from. Core works on this machine alone when no plugin is enabled
(ADR-0018).

The plugin shipped here is [`instances`](../../../plugins/instances/README.md).

## Why plugins

- **Not everyone needs it.** Most users run every worker on one machine.
  Multi-instance support brings Node.js, Docker, Sysbox and SSH; as a
  plugin, a user who never enables it installs none of that.
- **Core must stay small and portable.** Core is bash and also runs inside
  every instance and on remote hosts, where only the README requirements
  can be assumed. A plugin may use any runtime; core does not.
- **The boundary is a contract, not shared code.** Core never imports
  plugin code; it runs one executable with four calls. A plugin can live
  in another repository, be rewritten in another language, or be replaced
  (e.g. for Herdr app) without touching core, as long as it answers the
  same calls.

## Who does what

| Concern | Core | A machine-provider plugin |
|---|---|---|
| Which machines exist | asks `machines` | keeps its own list (the `instances` manifest) |
| Getting a machine ready | asks `ensure` before using it | starts, registers or explains (restart a container, tell the human to start a host) |
| Running work there | asks `exec` to run its own scripts on the machine | the transport (ssh) and the working directory |
| Workers, worktrees, herdr panes | everything | nothing |
| Teaching the orchestrator | lists the plugin's skills | writes them |

How dispatch, listing and steering use the machines is in
[orchestration.md](../orchestration.md#several-machines).

## Using plugins

```bash
scripts/plugins.sh ls                       # id, enabled, version, path
scripts/plugins.sh enable instances         # plugins/<id> in this checkout
scripts/plugins.sh enable ~/src/my-plugin   # or a plugin directory elsewhere
scripts/plugins.sh machines                 # plugin, label, target of every machine
scripts/plugins.sh disable instances        # unlink; nothing it created is deleted
```

`enable`:

1. installs the plugin's npm dependencies (`npm ci --omit=dev`) when it has
   a `package.json` and no `node_modules`;
2. runs `bin/hw-plugin describe` and refuses an invalid `id` or a
   `contract` other than 1;
3. refuses a described skill without `SKILL.md`, or one whose name another
   skill already uses — before anything is linked;
4. links `.plugins/<id>` to the plugin directory and each skill to
   `.agents/skills/plugin-<id>-<name>` (both git-ignored).

A skill link belongs to the plugin that made it — not to whatever its name
starts with, since ids may contain `-` (`a` and `a-b`). `enable` records
the links it makes in `.plugins/.<id>.skills` — each link's name and
target, so another spelling of the checkout path still matches and a
link counts as the plugin's only while it points where the plugin linked
it — so they are found again
when the plugin was moved or a skill lives outside the plugin directory;
links made before the record existed are found by their target (inside
the plugin's directory, now or where `.plugins/<id>` pointed). Another
plugin's link of the same name, even a dangling one, refuses the enable.
`ls` names a plugin by its `describe` id, so a plugin enabled by
path from a directory named otherwise is still listed and disabled by
its id. `disable` removes those links only. Enabling again picks up whatever the
plugin kept (its containers, manifest, state).

Enabled plugins are the symlinks in `<checkout>/.plugins/`
(`HW_PLUGINS_DIR` overrides it; tests use that).

## Layout

```text
<plugin>/
├── bin/hw-plugin          # required: executable, speaks the contract
├── skills/<name>/SKILL.md # optional: skills for the orchestrator
├── package.json           # optional: npm dependencies, installed on enable
├── README.md              # how to use it; its contract section
└── …                      # anything else the plugin needs
```

`bin/hw-plugin` is reached through the `.plugins/<id>` symlink, so it must
resolve its own directory physically (`cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P`).
It may be written in any language; the shim only has to be executable. A
plugin that needs a runtime checks for it and says what is missing (the
`instances` shim checks Node.js ≥ 24 and its dependencies).

## Contract, version 1

Core calls `bin/hw-plugin <call> [args]` with stdin closed. stdout carries
the answer; anything for a human goes to stderr, which core never
interprets: it shows it (`ensure`), passes it through (`exec` of a
dispatch, merged with stdout so pane ids can be rewritten to
`<label>/<pane>`), or drops it (`exec` of a listing).

| Call | stdout | Exit status | Core calls it |
|---|---|---|---|
| `describe` | JSON object, below | 0 | `plugins.sh enable`, `plugins.sh ls` (version) |
| `machines` | JSON array, below | 0; non-zero = this plugin is skipped with a warning | `list-workers.sh`, `spawn-repo-agent.sh --machine`, `plugins.sh machines` |
| `ensure <machine>` | nothing (messages on stderr) | 0 when the machine is usable now; 1 when it is not, with the reasons or the steps for a human on stderr | before a `--machine` dispatch; when `list-workers.sh` cannot reach a machine |
| `exec <machine> -- <cmd> [args…]` | `<cmd>`'s own output | `<cmd>`'s exit status; non-zero when the machine cannot be reached | to run `scripts/spawn-repo-agent.sh …` and `scripts/list-workers.sh --local` on the machine |

Core resolves the user's `--machine <label-or-target>` against `machines`
— a machine whose target matches first, else the first whose label
matches, the order the `instances` plugin resolves names in — and passes
the **target** to `ensure` and `exec`. A plugin's own CLI may
accept either; the contract only needs the target.

### `describe`

```json
{
  "id": "instances",
  "name": "Instances: dev containers and remote hosts",
  "version": "0.1.0",
  "contract": 1,
  "skills": ["skills/instances", "/abs/path/skills/instance-from-repo"]
}
```

- `id`: `^[a-z][a-z0-9-]*$`; the link name under `.plugins/` and in skill
  link names.
- `contract`: must be `1` for this core.
- `skills`: skill directories, absolute or relative to the plugin
  directory; `[]` when none.

### `machines`

```json
[
  {"label": "dev-a", "target": "dev-a", "dir": "~/herdr-worktree", "registered": true}
]
```

- `label`: what herdr shows; worker rows are written `<label>/<pane>` and
  steered with `herdr --machine <label>`. Labels must be unique among
  herdr's machines.
- `label` and `target` are non-empty and hold no whitespace, control
  character or `/`: they are joined into tab-separated rows and
  `<label>/<pane>` names. Core skips (with a warning) a machine that
  breaks this.
- `target`: a fixed name the plugin resolves (for `instances`, the ssh
  alias and herdr target). Core matches `--machine` against label or
  target.
- `dir`: the herdr-worktree checkout on that machine.
- `registered`: whether herdr already knows the machine (`herdr --machine`
  works).

Listing must be cheap and must not start anything: core calls it on every
`list-workers.sh`.

### `ensure <machine>`

Bring the machine into use if the plugin can (the `instances` plugin
restarts a stopped container) and register it with herdr. When a human
has to act (a remote host is down), print the steps on stderr and exit 1;
the orchestrator relays them. Must be safe to call when the machine is
already up.

### `exec <machine> -- <cmd> [args…]`

Run `<cmd>` in the machine's checkout as if from a pane there:
`HERDR_ENV=1`, the working directory at `dir`, each argument passed
unchanged (quote it for the transport). Pass stdout, stderr and the exit
status through. The machine's own checkout must be herdr-worktree with
the scripts core calls.

What stays on the machine: the clone, the worktree, the Git credentials,
the agent's logins and the worker itself. Nothing is copied between
machines.

## Skills

A plugin's skills are how the orchestrator learns to manage what the
plugin provides (the `instances` skill: list, add, rename, rebuild
instances). Once enabled they are listed next to core's skills and picked
by their `description` like any other (ADR-0019), so write the
description around the user's words ("is hw-a up?", "add a container").
A skill name must not clash with a core skill or another plugin's.

## Testing

- **Contract checks on enable**: `tests/scripts/plugins.bats` covers
  `plugins.sh` (contract version, skill links and clashes, disable).
- **Core against a plugin**: `tests/scripts/helpers.bash` has
  `stub_plugin <id>`, an enabled fake plugin whose answers come from files
  (`machines.json`, `ensure-<target>`, `exec-<target>`); see
  `tests/scripts/list-workers.bats` and `tests/scripts/lib/plugins.bats`.
- **The plugin itself**: its own test suite, run in CI. The `instances`
  plugin replaces every external command with an in-memory world
  (`plugins/instances/test/helpers.ts`).

## Adding a plugin to this repository

1. `plugins/<id>/` with `bin/hw-plugin`, a `README.md` (with a contract
   section and `sources:` frontmatter so `check-docs-stale.sh` watches it)
   and its tests.
2. A CI job for its tests next to `plugin-instances` in
   `.github/workflows/ci.yaml` (the `plugins` change filter already covers
   `plugins/`); `scripts/lint.sh` already shellchecks `plugins/*/bin/*`.
3. A Dependabot entry when it has package dependencies.
4. Its design doc at `docs/design/plugins/<id>/README.md` (how it works
   and why; [instances/](instances/README.md) is the example), next to
   the user-facing `plugins/<id>/README.md`.
5. A row in the components table of [docs/design/README.md](../README.md)
   and, for user-facing features, a line in the top-level README.

A plugin kept in its own repository is enabled by path
(`plugins.sh enable <dir>`); clone it under `plugins/` so relative paths
and the instance images find the core checkout (`HW_CORE_DIR` overrides).

## References

- [ADR-0018](../../adr/0018-plugins-and-typescript-instances.md) — plugins
  behind a small contract; the instances plugin in TypeScript
- [ADR-0019](../../adr/0019-link-plugin-skills.md) — plugin skills linked into
  `.agents/skills`
- [../reference/scripts.md](../../reference/scripts.md) — `plugins.sh` and
  `scripts/lib/plugins.sh`
- [orchestration.md](../orchestration.md#several-machines) — dispatch,
  listing and steering across machines

## A minimal plugin

```bash
#!/usr/bin/env bash
# bin/hw-plugin — one fixed SSH host as a machine
set -euo pipefail
case "${1:-}" in
  describe) echo '{"id":"buildbox","name":"Build box","version":"0.1.0","contract":1,"skills":[]}' ;;
  machines) echo '[{"label":"buildbox","target":"buildbox","dir":"~/herdr-worktree","registered":true}]' ;;
  ensure)   ssh -o BatchMode=yes -o ConnectTimeout=5 buildbox true ||
              { echo "Start buildbox and its herdr server, then try again." >&2; exit 1; } ;;
  exec)     shift 2; shift   # <machine> --
            ssh -o BatchMode=yes buildbox "cd ~/herdr-worktree && HERDR_ENV=1 $(printf '%q ' "$@")" ;;
  *)        echo "usage: hw-plugin describe|machines|ensure <m>|exec <m> -- <cmd>" >&2; exit 2 ;;
esac
```

It assumes `buildbox` is an ssh alias and a herdr machine already saved
with `herdr machine add buildbox --label buildbox`.
