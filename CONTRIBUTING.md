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

Shell tests live in `tests/`. They need the README requirements (bash,
git, gh, jq) — not herdr or the agent CLIs, which they stub.
`nix develop` adds the development-only tools (`shellcheck`, see
`flake.nix`). Run them before pushing:

```bash
for t in tests/scripts/test-*.sh; do bash "$t"; done   # per-script tests
bash scripts/lint.sh                        # shellcheck every shell file
```

`lint.sh` uses `tools/shellcheck` when present (portable install,
gitignored — see its error message for the one-line install), otherwise
shellcheck from PATH (the `nix develop` shell provides it). It lints
tracked files only.

Any change to `scripts/*.sh` must extend the matching `tests/scripts/test-*.sh` —
stubs for `gh`/`herdr` live in
`tests/scripts/lib.sh`. The
`scripts/*.sh` → `tests/scripts/test-*.sh` pairing is enforced by
`scripts/check-test-coverage.sh`.

## Documentation

Docs are part of every change:

- **`docs/design/`** — design docs in Google OKF v0.2 (markdown + YAML
  frontmatter; `type`, `title`, `description`, `status`,
  `last_modified`, `sources`). Design docs capture intent and invariants
  (What/Why/How at the design level), not implementation detail. Update
  the relevant doc in the same commit as any behavior change.
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

### Keeping docs fresh

Docs rot when prose claims drift from code. Three mechanisms prevent it:

- **`sources:` contract** — every design/reference doc *derived from
  code* lists the files it is derived from.
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
