---
type: Reference
title: Scripts
description: Behavior contract of every script under scripts/ — what it does, what it writes, and what it prints.
status: current
last_modified: 2026-11-04
tags: [scripts, reference]
sources: [scripts]
---

# Scripts

All scripts are bash, `set -euo pipefail`, and safe to re-run.

## scripts/

### `setup-repo.sh <[org/]repo>`

Imports a GitHub repository into the lab. Clones into `repos/<repo>/` on
first run; on later runs fetches and fast-forwards the default branch.
If the repo ships `scripts/setup-hooks.sh`, runs it once at the base
clone — linked worktrees share the common git dir, so hooks need no
per-worktree install. Prints the absolute repo path.

### `create-worktree.sh [--detach] <[org/]repo> <name>`

Creates `worktree/<repo>/<name>` based on `origin/main` — on a new branch
named `<name>` by default, or on a detached HEAD when `--detach` is given
(used for dispatched task worktrees; no branch is named before the task
is understood). Calls `setup-repo.sh` internally (clone-or-update), then
symlinks herdr-worktree's `scripts/hooks/` into the managed repo's git
dir — a repo's own hooks (regular files) and foreign symlinks are never
clobbered or fatal to the run. Prints the absolute worktree path — use
it for all edits.

### `spawn-repo-agent.sh [--kind <kind>] [--model <model>] [--effort <level>] [--reply-lang <language>] <[org/]repo> [-- <task>]`

Dispatches a dedicated worker agent via herdr. Creates a collision-free
task worktree (`worktree/<repo>/task/<uuid>`, detached HEAD at
`origin/main`), reuses or creates the repo's herdr workspace + tab, and
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
claude, `ensure_trusted_workspace` also pre-answers the
external CLAUDE.md imports dialog with "No", so no `CLAUDE.md` outside
the worktree is imported and the worker never stops at that dialog. For
pi it records the worktree in pi's `trust.json` — pi's trust check walks
up to herdr-worktree's `.agents/skills`, but its skill discovery stops at
the worktree root, so only the repo's own resources load. Agent-settings merges lock with a
`mkdir` lockdir — `flock(1)` is Linux-only and never a documented
requirement. Prints `Dispatched to pane
<pane_id>` — keep the pane id for monitoring. See `orchestration.md`.

### `list-workers.sh [query...]`

Lists the dispatched workers in the running herdr session — agents whose
cwd is under `<lab>/worktree/` (lab: `WORKTREE_LAB_DIR`, else the
script's parent dir) — one tab-separated line each:
`pane_id name repo status tab_label title` (`-` for no name or label).
Query words keep only lines containing every word, case-insensitively;
no match prints `No worker matches: …` and exits 1. Read-only. Used by
the `herdr-control` skill to resolve the human's description of a worker
to a pane id.

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

Runs shellcheck over every tracked shell file (`*.sh` plus the
extension-less git hooks). Prefers the portable, gitignored
`tools/shellcheck` install; falls back to shellcheck on PATH.

### `check-docs-stale.sh [base-ref]`

Enforces the docs freshness contract: every `docs/design`/`docs/reference`
doc declares the files it is derived from in its `sources:` frontmatter.
Fails when a declared source path no longer exists (`MISSING`), or when a
source changed in `base...HEAD` (default `origin/main`) without the doc
changing in the same diff (`STALE`). `docs/adr/` is exempt — ADRs are
point-in-time records.

### `check-test-coverage.sh`

Fails when any `scripts/*.sh` lacks a matching `tests/scripts/test-<name>.sh`.
Run by the `pre-push` git hook and as the last step of the CI
`shell-test` job.

## scripts/hooks/

| Hook | Behavior |
|---|---|
| `pre-commit` | Blocks commits to `main` and to branches whose PR is already merged/closed |
| `pre-push` | PR-workflow reminders; runs the repo's `scripts/check-docs-stale.sh` and `scripts/check-test-coverage.sh` when present, blocking the push on failure |
