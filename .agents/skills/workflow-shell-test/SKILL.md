---
name: workflow-shell-test
description: Extract testable shell logic from GitHub Actions workflows and cover it with BATS. Use when adding workflow shell tests, extracting inline run blocks, adding GitHub Actions change detection, or modifying .github/scripts and tests/*.bats.
---

# Workflow Shell Tests

Extract multi-line file mutations, pure calculations, repeated Git operations, and change-detection logic from `run:` blocks. Leave one-command cluster operations and GitHub Actions expressions inline.

## Script conventions

Put workflow-specific scripts in `.github/scripts/<workflow>/` and reusable scripts in `.github/scripts/shared/`. Every script must use:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Pass inputs through environment variables, not positional arguments. For workflow outputs, append to `$GITHUB_OUTPUT` when available and print `KEY=VALUE` otherwise:

```bash
_out() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "${key^^}" "$value"
  fi
}
```

Replace the workflow's inline logic with `bash .github/scripts/<workflow>/<script>.sh` and provide its variables through `env:`.

## BATS coverage

Create tests in `tests/<workflow>/<script>.bats` or `tests/shared/<script>.bats`. Clear `GITHUB_OUTPUT` in `setup()` so tests can assert stdout. Build fixtures that match actual files the script mutates.

For scripts that use Git, make a local bare `origin`, seed a `main` commit, clone it into `$BATS_TEST_TMPDIR/repo`, and run the script there. Do not use a network remote.

For change detection, cover relevant and irrelevant changes, a new branch with an all-zero `before`, `workflow_dispatch`, and a missing force-push base SHA. Fall back to `origin/main` whenever the event base cannot be used.

## CI integration

Add a `changes` job that marks shell work changed for `.github/workflows/*.yaml`, `.github/scripts/**/*.sh`, or `tests/**/*.bats`. Add a `shell-test` job that installs BATS and runs:

```bash
"$RUNNER_TEMP/bats-core/bin/bats" --recursive tests/
```

Run the relevant BATS tests locally before opening the PR.
