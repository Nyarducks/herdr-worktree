---
name: development
description: Rules and workflow for changing herdr-worktree itself (scripts, skills, docs, tests in this checkout). Load it before editing anything in this repository. Work happens directly in this checkout on a feature branch. For any other repository, use worktree-development (herdr dispatch) instead — never edit other repos in-process.
---

# herdr-worktree development

Rules and workflow for changing **this repository**, herdr-worktree.
Read this before touching any file here. Tasks that target any
*other* repository go through `worktree-development` (a dispatched
worker); the orchestrator never edits other repos in-process. If the
request does not say which agent kind or which repository, ask before
dispatching.

These rules live in a skill, not in a root `AGENTS.md`/`CLAUDE.md`:
agents such as pi load context files from every parent directory, so a
root file would leak these rules into workers whose worktrees sit
under this checkout (ADR-0005).

## Rules — always follow

1. **Never commit to `main`** — feature branch + PR. Never approve or
   merge a PR; the human does.
2. **Never edit `repos/`** — base clones are read-only; dispatched
   work happens in `worktree/` via `worktree-development`.
3. **Never edit a delegated worktree** — a worktree assigned to a
   dispatched worker belongs to that worker; send follow-ups to it via
   herdr instead.
4. **No reserved file names** — never create a file named like an agent
   context file in any case or directory (`AGENTS.md`, `CLAUDE.md`,
   `GEMINI.md`, …): agents load them as instructions, and macOS treats
   `agents.md` as `AGENTS.md`.
5. **Keep docs current** — update `docs/design/` in the same commit as any
   behavior change; record significant decisions as ADRs in `docs/adr/`.
   CI enforces the doc↔code link via each doc's `sources:` frontmatter.

Use `git-operations` for branch/commit/PR discipline. How to work here
(tests, style, docs conventions): `CONTRIBUTING.md`. Architecture:
`docs/design/`. Decisions: `docs/adr/`.

## Workflow

Work directly in this checkout (`git rev-parse --show-toplevel`). No
worktree is created for herdr-worktree development (ADR-0006).

1. **Branch from the latest `main`**

   ```bash
   git switch main && git pull --ff-only
   git switch -c feat/<topic>        # or fix/<issue>, refactor/<scope>
   ```

2. **Investigate, then plan** — read the files that will change and
   their contracts (`docs/reference/scripts.md`, the tests under
   `tests/scripts/`) before editing.

3. **Implement** — every `scripts/*.sh` change extends its
   `tests/scripts/<name>.bats`; docs change in the same commit (rule 5).
   Run the suites before pushing:

   ```bash
   bats --recursive tests/
   bash scripts/lint.sh
   bash scripts/check-test-coverage.sh
   ```

4. **Commit, push, open the PR** — follow `git-operations` (English PR
   title/body, `--assignee @me`, `--label`, Decision Log entry per pushed
   commit via `scripts/append-pr-log.sh <owner>/herdr-worktree <pr> .`).

5. **After merge** — switch back and delete the branch:

   ```bash
   git switch main && git pull --ff-only
   git branch -d feat/<topic>
   ```

## Notes

- Uncommitted work blocks `git switch`; finish or stash it before
  starting another topic. One topic per branch.
- `repos/` and `worktree/` are gitignored lab directories that may sit
  inside this checkout; never stage them.
