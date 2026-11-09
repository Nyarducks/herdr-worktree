---
type: ADR
title: Test shell with bats; write scripts as sourceable modules
description: Shell tests move from a home-grown runner to bats-core; shared logic moves into scripts/lib modules whose functions return a status, and every script runs main only when executed so tests can source it.
status: accepted
last_modified: 2026-11-07
tags: [testing, bats, shell, structure]
---

# ADR-0021: Test shell with bats; write scripts as sourceable modules

## Status

Accepted.

## Context

The shell tests were one script per tested script, sourcing a home-grown
`lib.sh` that counted passes and failures. Sections ran in sequence and
shared state, so one failure could hide the rest, a single section could
not be run alone, and nothing but the whole script could be tested: every
script called `main` as soon as it was read.

The scripts had grown their own copies of shared logic.
`spawn-repo-agent.sh` (537 lines) held herdr waiting, dialog detection,
locked JSON edits and agent trust next to its argument handling. Two
scripts found the lab differently: `setup-repo.sh` looked upward for
`repos/`, `list-workers.sh` took the checkout's parent, so in the split
layout (`<lab>/repos`, `<lab>/worktree`, checkout at `<lab>/<name>`) it
looked in the wrong place and listed no worker.

## Decision

- Shell tests are bats-core files: `tests/scripts/<name>.bats` per
  script, `tests/scripts/lib/<name>.bats` per module, each `@test`
  self-contained. `tests/scripts/helpers.bash` keeps the stubs and the
  `expect_*` assertions; a failing assertion fails the test. CI installs a
  pinned bats-core; the dev shell, the default container image and
  `instance check` use bats too.
- Shared logic lives in `scripts/lib/<topic>.sh` modules (`common`, `lab`,
  `repo`, `json`, `agent-trust`, `herdr`, `plugins`). Modules only define
  `hw_` functions; a failure prints `Error: …` and returns 1, and the
  calling script decides whether to exit.
- Every script ends with a main guard that sets `set -euo pipefail` and
  runs `main` only when executed, so a test can `source` it and call one
  function.
- `check-test-coverage.sh` requires a bats file for every script and every
  module.
- The lab is found one way, `hw_lab_dir`, which fixes `list-workers.sh` in
  the split layout.

## Consequences

- A failing test names itself and the others still run; `bats --filter`
  runs one.
- `spawn-repo-agent.sh` is down to argument handling and the dispatch
  sequence; the pieces it used are tested on their own.
- Contributors need bats locally (`nix develop`, or a package manager).
- The strict flags are set in the guard rather than on the second line, so
  top-level code before `main` (constants, `source` of modules) must stay
  simple. Hooks, which are never sourced, keep the header form.
