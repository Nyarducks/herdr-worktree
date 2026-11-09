# Contributing

Development rules for herdr-worktree. The non-negotiables live in the
`development` skill (`.agents/skills/development/SKILL.md`); this file
covers how to work. There is deliberately no root `AGENTS.md`/`CLAUDE.md`
— see ADR-0005.

## Where to work

Changes to herdr-worktree happen directly in this checkout, on a feature
branch (ADR-0006).
Base clones under `repos/` and dispatched task worktrees under
`worktree/` are never edited. See `docs/design/README.md` for the layout.

## Git workflow

- Feature branch + PR; never commit to `main`
- Branch naming: `feat/<feature>`, `fix/<issue>`, `refactor/<scope>`
- The pre-commit hook blocks `main` and already-merged/closed PR branches
- Humans approve and merge PRs — agents never do

## Shell script style

Everything under `scripts/` and `tests/` follows
`docs/reference/shell-style.md`.

## Tests

Shell tests are [bats](https://github.com/bats-core/bats-core) files in
`tests/`. They need the README requirements (bash, git, gh, jq) and bats —
not herdr or the agent CLIs, which they stub. `nix develop` adds the
development-only tools (bats, `shellcheck`, and Node.js for the plugin
checks; see `flake.nix`). Run them before pushing:

```bash
bats --recursive tests/                     # every shell test
bash scripts/lint.sh                        # shellcheck every shell file
(cd plugins/instances && npm ci && npm run check)       # the instances plugin
```

`lint.sh` uses `tools/shellcheck` when present (portable install,
gitignored — see its error message for the one-line install), otherwise
shellcheck from PATH (the `nix develop` shell provides it). It lints
tracked files only.

Any change to `scripts/*.sh` must extend the matching
`tests/scripts/<name>.bats`. Each file starts with `load helpers`:
`tests/scripts/helpers.bash` has the per-test scratch dir (`common_setup`,
`common_teardown`), the `expect_*` assertions (a failing one fails the
test) and the stubs for `gh`, `herdr`, the agent CLIs and a plugin. Each
`@test` stands alone; a command expected to fail goes through `run`.
Shellcheck does not follow `load`, so each file disables SC2154 right
before it. Shared logic goes into a `scripts/lib/<topic>.sh` module with
its own `tests/scripts/lib/<topic>.bats`; scripts run `main` only when
executed, so a test can `source` one and call a function (see
`docs/reference/shell-style.md` §7). Both pairings are enforced by
`scripts/check-test-coverage.sh`.

## Documentation

Docs are part of every change:

- **`docs/design/`** — design docs in Google OKF v0.2 (markdown + YAML
  frontmatter; `type`, `title`, `description`, `status`,
  `last_modified`, `sources`). Design docs capture intent and invariants
  (What/Why/How at the design level), not implementation detail. Update
  the relevant doc in the same commit as any behavior change. The plugin
  system is described in `docs/design/plugins/README.md`, and each
  plugin's design in `docs/design/plugins/<id>/README.md`.
- **`docs/reference/`** — fact inventories (config tables, script/skill
  lists). Same frontmatter convention with `type: Reference`.
- **`docs/adr/`** — record significant decisions as
  `docs/adr/NNNN-<slug>.md` (Context / Decision / Consequences, OKF
  frontmatter `type: ADR`). Numbers are sequential. ADRs are immutable
  point-in-time records — never edit one to track code drift; write a
  new ADR when a decision is revisited.
- **`README.md`** — quick start only; keep it slim.
- **`development` skill** — must-follow rules for changing herdr-worktree; do
  not document structure or usage there. Do not add a root
  `AGENTS.md`/`CLAUDE.md` (ADR-0005).
- **File names** — never name a file after an agent context file, in any
  letter case and in any directory: `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`
  and the like. Agent CLIs load such files as instructions, and on a
  case-insensitive filesystem (macOS) `agents.md` *is* `AGENTS.md`.

### Keeping docs fresh

Docs rot when prose claims drift from code. Three mechanisms prevent it:

- **`sources:` contract** — every design/reference doc *derived from
  code*, and each plugin's `README.md`, lists the files it is derived from.
  `scripts/check-docs-stale.sh` fails a PR that changes a source without
  touching its doc, or that leaves a `sources` entry pointing at a
  deleted/renamed path. Keep `sources` as narrow as the doc's actual
  dependencies. Prescriptive docs (conventions like `shell-style.md`)
  leave `sources: []` — the check skips them.
- **Write checkable claims** — avoid universal quantifiers over
  code-derived facts ("every agent implements …") and embedded counts
  ("28 checks") unless a test asserts them; enumerate the matrix or name
  the exception instead.
- **Don't restate files** — if reading a config answers it (CI job
  layout, action versions, runner images, dependabot cadence), prose
  about it rots. Point at the file or state only the rule behind it.
- **Root docs carry no `sources:`** — `README.md`/`CONTRIBUTING.md` and
  the skills are reviewed by hand: re-check the quick start and
  the rule list whenever workflow routing or skill behavior changes.
