---
type: Reference
title: Scripts
description: Behavior contract of every script under scripts/ — what it does, what it writes, and what it prints.
status: current
last_modified: 2026-11-07
tags: [scripts, reference]
sources: [scripts]
---

# Scripts

All scripts are bash, `set -euo pipefail`, and safe to re-run.

## scripts/

### `setup-repo.sh <[org/]repo>`

Imports a GitHub repository into the lab. Clones into `repos/<repo>/` on
first run; on later runs fetches and fast-forwards the base branch — `main`, else
`master` (`scripts/lib/repo.sh`).
If the repo ships `scripts/setup-hooks.sh`, runs it once at the base
clone — linked worktrees share the common git dir, so hooks need no
per-worktree install. Prints the absolute repo path. With `<org>/<repo>`,
an existing `repos/<repo>` cloned from another GitHub org (its configured
`origin` URL, case-insensitive) is refused, exit 1: clones are kept by
repo name.

### `create-worktree.sh [--detach] <[org/]repo> <name>`

Creates `worktree/<repo>/<name>` based on `origin/main` (or `origin/master` when origin has no main; neither is refused before anything is created) — on a new branch
named `<name>` by default, or on a detached HEAD when `--detach` is given
(used for dispatched task worktrees; no branch is named before the task
is understood). Calls `setup-repo.sh` internally (clone-or-update), then
symlinks herdr-worktree's `scripts/hooks/` into the managed repo's git
dir — a repo's own hooks (regular files) and foreign symlinks are never
clobbered or fatal to the run. Prints the absolute worktree path — use
it for all edits.

### `spawn-repo-agent.sh [--machine <label>] [--kind <kind>] [--model <model>] [--effort <level>] [--reply-lang <language>] <[org/]repo> [-- <task>]`

Dispatches a dedicated worker agent via herdr. Creates a collision-free
task worktree (`worktree/<repo>/task/<uuid>`, detached HEAD at
`origin/main` or `origin/master`), reuses or creates the repo's herdr workspace + tab, and
launches the agent unconfined via `herdr agent start` (falling back to
`pane run`), then submits a prompt. `--model` / `--effort` map to each
CLI's flags:

| Kind | `--model` | `--effort` |
|---|---|---|
| `claude`, `agy` | `--model` | `--effort` |
| `codex` | `--model` | `-c model_reasoning_effort="<e>"` |
| `pi` | `--model` | `--thinking` |
| `devin` | `--model` | rejected (no CLI flag; the level is part of the model id) |

Each is independent; omitted or `inherit` passes no flag, so the worker
inherits the CLI's own settings. The effort is checked against the
model's levels from `agent-models.sh`, or the kind-wide list when the
model has none; other kinds reject both flags. The prompt is the task plus a
self-naming preamble, or — with no task — a standby instruction that
keeps the naming contract until work arrives via
`herdr agent prompt <pane> "<task>"`. Both carry a language rule: think
in English and reply in the `--reply-lang` language, or — without it —
in the language the human writes in. If the prompt submission stalls
(agent TUI swallowed the trailing Enter under bracketed paste), the
script sends a real `pane send-keys <pane> Enter` and re-waits; if the
agent is still idle (the paste never arrived),
it resends the prompt once before warning. Neither happens while the pane
shows a selection/confirmation dialog (herdr can report such an agent as
idle) — the script warns instead of answering it. While `agent start` waits
for readiness, the pane is polled: an `Error:` line printed after the
launch command (an unavailable model, a bad flag, not logged in) fails
the dispatch at once with that line, without the `pane run` retry. For
claude, `hw_trust_worktree` (`scripts/lib/agent-trust.sh`) writes the trust to
`${CLAUDE_CONFIG_DIR:-~}/.claude.json` (where Claude Code keeps it) and
also pre-answers the
external CLAUDE.md imports dialog with "No", so no `CLAUDE.md` outside
the worktree is imported and the worker never stops at that dialog. For
pi it records the worktree in pi's `trust.json` — pi's trust check walks
up to herdr-worktree's `.agents/skills`, but its skill discovery stops at
the worktree root, so only the repo's own resources load. Agent-settings merges lock with a
`mkdir` lockdir — `flock(1)` is Linux-only and never a documented
requirement. Prints `Dispatched to pane
<pane_id>` — keep the pane id for monitoring. See `orchestration.md`.

`--machine <label>` (a machine an enabled plugin provides — `plugins.sh
machines` — by label or target) runs that machine's own
`spawn-repo-agent.sh` through the plugin instead: `hw-plugin ensure
<target>` first (exit 1 after its explanation when it stays unavailable),
then `hw-plugin exec <target> -- scripts/spawn-repo-agent.sh <other args>`
(`scripts/lib/plugins.sh`). With no plugin enabled, `--machine` exits 1
saying so. The clone,
worktree, Git credentials and worker stay on that machine. Its output is
passed through with the pane written `<label>/<pane>` and herdr hints
rewritten to `herdr --machine <label>`, using the current label. An
unknown machine exits 1.

### `list-workers.sh [--local] [query...]`

Lists the dispatched workers in the running herdr session — agents whose
cwd is under `<lab>/worktree/` (lab: `hw_lab_dir`, below — the same lab
`setup-repo.sh` uses, in the nested and the split layout) — one
tab-separated line each:
`pane_id name repo status tab_label title` (`-` for no name or label).
Query words keep only lines containing every word, case-insensitively;
no match prints `No worker matches: …` and exits 1. Used by
the `herdr-control` skill to resolve the human's description of a worker
to a pane id. Unless `--local` is given, the rows of every machine the
enabled plugins provide follow — that machine's `list-workers.sh --local`
through `hw-plugin exec`, with `pane_id` written `<label>/<pane>`; a
machine that does not answer is ensured once through its plugin (which may
restart a stopped container) and retried, else skipped with a warning on
stderr. With no plugin enabled, only this herdr is listed. Queries also match those rows.

### `plugins.sh ls|enable|disable|machines`

Adds and removes plugins (ADR-0018; design and the full contract:
[../design/plugins/](../design/plugins/README.md)). A plugin is a directory with an
executable `bin/hw-plugin` speaking the contract in
`scripts/lib/plugins.sh` (version 1): `describe` (JSON `{id, name,
version, contract, skills[]}`; `skills` are skill directories, absolute or
relative to the plugin), `machines` (JSON `[{label, target, dir,
registered}]`), `ensure <machine>` (exit 1 with reasons on stderr when it
cannot be used) and `exec <machine> -- <cmd…>` (runs `<cmd>` in that
machine's checkout as from a pane there; output and exit status pass
through). Enabled plugins are symlinks `<checkout>/.plugins/<id>`
(git-ignored; `HW_PLUGINS_DIR` overrides).

- `ls` — every plugin under `plugins/` and every enabled one: `id enabled
  version path`, tab-separated.
- `enable <id-or-path>` — `<id>` is `plugins/<id>`; a path enables one
  elsewhere (a separate repository). Runs `npm ci --omit=dev` first when
  it has a `package.json` and no `node_modules`, requires `describe` to
  answer contract 1, then links it. Each skill it describes is linked as
  `.agents/skills/plugin-<id>-<name>` (`<name>` from its `SKILL.md`
  frontmatter; git-ignored; `HW_SKILLS_DIR` overrides), so agents list it
  next to core's skills (ADR-0019). A skill without `SKILL.md`, or whose
  name a skill not from this plugin already uses, refuses the enable before
  anything is linked. A skill link is attributed to a plugin by the record
  of the links it made (`.plugins/.<id>.skills`) or by its target (inside
  the plugin's directory), never by its name; another plugin's link of the
  same name refuses the enable.
- `disable <id>` — removes the plugin link and its skill links only; what
  the plugin created stays.
- `machines` — `plugin label target` of every machine enabled plugins
  provide; a machine whose label or target holds whitespace, a control
  character or `/` is skipped with a warning.

The plugins shipped here document themselves: `plugins/instances/README.md`
(dev containers and remote hosts; TypeScript on Node.js ≥ 24).

### `agent-models.sh [--refresh] <kind> [models|efforts]`

Lists what `--model` / `--effort` accept for `claude`, `agy`, `codex`,
`pi` or `devin`. `models` prints `id<TAB>label<TAB>efforts` (per-model
levels, empty when the CLI reports none); `efforts` prints the kind-wide
levels, one per line (empty for `devin`). Answers are cached under
`${AGENT_MODELS_CACHE_DIR:-~/.cache/herdr-worktree/agent-models}` and
re-queried after `AGENT_MODELS_TTL_DAYS` (default 7) or with
`--refresh`. Sources: a built-in list + `claude --help` (no list
command); `agy models` + `agy --help`; `codex debug models`;
`pi --list-models` + `pi --help` + custom models' `thinkingLevelMap` in
pi's `models.json`; `devin models list --format json` (every variant's
`model_uid`, then each family's slug and aliases; needs login,
otherwise the documented aliases, uncached). A CLI that is not installed
yields the built-in list (claude, devin) or nothing, uncached.

### `append-pr-log.sh <owner>/<repo> <pr-number> <worktree-path>`

Appends the worktree's latest commit as a collapsed `<details>` entry under
`## Decision Logs` in the PR body. Used to keep an audit trail on stacked
PRs.

### `setup-hooks.sh`

Installs every hook in `scripts/hooks/` as a symlink into the common git
dir. Links resolve to the base clone's `scripts/hooks/`, so they keep
working when a worktree is removed; `setup-repo.sh` invokes this
automatically for repos that ship it.

### `lint.sh`

Runs shellcheck over every tracked shell file: `*.sh`, the bats tests
and helpers (`*.bats`, `*.bash`), the extension-less git hooks and the
plugins' `bin/` shims. Prefers the portable, gitignored
`tools/shellcheck` install; falls back to shellcheck on PATH.

### `check-docs-stale.sh [base-ref]`

Enforces the docs freshness contract: every `docs/design`/`docs/reference`
doc, and each plugin's `plugins/<id>/README.md`, declares the files it is
derived from in its `sources:` frontmatter.
Fails when a declared source path no longer exists (`MISSING`), or when a
source changed in `base...HEAD` (default `origin/main`) without the doc
changing in the same diff (`STALE`). `docs/adr/` is exempt — ADRs are
point-in-time records.

### `check-test-coverage.sh`

Fails when any `scripts/*.sh` lacks a matching `tests/scripts/<name>.bats`,
or any `scripts/lib/*.sh` a `tests/scripts/lib/<name>.bats`.
Run by the `pre-push` git hook and as the last step of the CI
`shell-test` job.

## scripts/lib/

Shared modules, sourced (never run) by the scripts above and by tests.
Functions are prefixed `hw_`; a failure prints `Error: …` to stderr and
returns 1 (only `hw_die` exits), so callers decide whether to stop.

| Module | Functions |
|---|---|
| `common.sh` | `hw_die <msg>` — `Error: <msg>`, exit 1; `hw_short_id` — 12 lowercase hex characters |
| `lab.sh` | `hw_lab_dir <checkout>` — `WORKTREE_LAB_DIR`, else the nearest directory at or above the checkout holding `repos/`, else the checkout |
| `repo.sh` | `hw_base_branch <clone>` — `main`, else `master` |
| `json.sh` | `hw_json_merge <file> <path> <jq-filter>` — in-place edit under a directory lock; a corrupt file is backed up and replaced by `{}` first |
| `agent-trust.sh` | `hw_trust_worktree <wt>` — marks the worktree trusted for claude (`${CLAUDE_CONFIG_DIR:-~}/.claude.json`), agy and pi, when installed |
| `herdr.sh` | `hw_require_herdr`, `hw_launch_error <pane> <kind>`, `hw_pane_has_dialog <pane>`, `hw_workspace_pane_for <repo> <wt> <tab>`, `hw_wait_for_agent <pane> <kind>` |
| `plugins.sh` | the plugin contract: `hw_plugins_root`, `hw_plugin_bins`, `hw_plugin_machines`, `hw_plugin_find`, `hw_plugin_exec`, `hw_plugin_ensure` |

Every script under `scripts/` runs `main` only when executed (`[[
"${BASH_SOURCE[0]}" == "$0" ]]`, which also sets `set -euo pipefail`), so a
test can `source` it and call one function.

## scripts/hooks/

| Hook | Behavior |
|---|---|
| `pre-commit` | Blocks commits to `main` or `master` and to branches whose PR is already merged/closed |
| `pre-push` | PR-workflow reminders; runs the repo's `scripts/check-docs-stale.sh` and `scripts/check-test-coverage.sh` when present, blocking the push on failure |
