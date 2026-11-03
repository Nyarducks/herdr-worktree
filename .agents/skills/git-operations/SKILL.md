---
name: git-operations
description: Git workflow guide for developing the herdr-worktree repository — used only from the development skill. Use when cloning, branching, committing, or creating/editing PRs — enforces gh-based clone for private repos, feature branch from latest main, and PATCH-based PR edits.
---

# Git Operations Guide

> Scope: this skill applies to `development` only — i.e.
> work on the herdr-worktree repository itself. Dispatched workers on
> other repositories follow that repo's own conventions instead.

## Clone a repository

Use `gh repo clone` for private repositories (bare `git clone` fails on auth):

```bash
gh repo clone <owner>/<repo>
```

## Branch policy

### Protected branches

Direct commits to `main` are blocked by the pre-commit hook. Always create a feature branch.

### Creating a feature branch

Always branch from the latest `main`.

```bash
git switch main && git pull --ff-only
git switch -c <branch-name>
```

Branch names must follow: `feat/<feature>`, `fix/<issue>`, `refactor/<scope>`.

## Commit

Use standard `git add` / `git commit` in this checkout, on the feature branch. Never commit in `repos/` (base clones) or in a dispatched worker's `worktree/`.

## Creating a PR

**Always push the branch before running `gh pr create`.**

**PR title, body, and all Decision Log entries must be written in English.**

**Always check for a PR template in the target repo before writing the body.** If `.github/pull_request_template.md` exists, use it as the structure for `--body`:

```bash
gh api repos/<owner>/<repo>/contents/.github/pull_request_template.md \
  -H "Accept: application/vnd.github.raw"
```

```bash
git push -u origin <branch-name>
PR_URL=$(gh pr create \
  --repo <owner>/<repo> \
  --head <branch-name> \
  --title "<title>" \
  --assignee @me \
  --label "<labels>" \
  --body "$(cat <<'EOF'
## Summary

- change 1
- change 2

## Background

Motivation and context

## Test plan

- [ ] item 1
- [ ] item 2

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)")
PR=$(basename "$PR_URL")   # extract PR number from URL
```

Always pass `--assignee @me` and `--label`.

Immediately after PR creation, log the initial commit:

```bash
scripts/append-pr-log.sh <owner>/<repo> "$PR" . <<'EOF'
### What changed
- <describe what this commit implements>

### Why
<rationale for the approach taken>
EOF
```

## Decision Logs

Every commit pushed to a PR branch must be recorded in the PR body under `## Decision Logs`. Use `scripts/append-pr-log.sh` after each commit:

```bash
# After git commit + git push
scripts/append-pr-log.sh <owner>/<repo> <pr-number> . <<'EOF'
### What changed
- <describe changes in this commit>

### Why
<reason: review feedback / bug found / design refinement / etc.>
EOF
```

The script appends a collapsed `<details>` block. The `<summary>` line is `<commit message> (<short SHA>)`. The `## Decision Logs` header is created automatically on first call if absent.

## Labels

Apply labels to every PR on create. Always pass `--label` — never omit it.

### Component labels (apply all that match)

Component labels are repo-specific. Common conventions:

| Label | Scope |
|---|---|
| `backend` | Server-side / API changes |
| `frontend` | Client-side / UI changes |
| `infra` | Infrastructure / Kubernetes / Helm changes |
| `documentation` | Documentation changes (`docs/`, `*.md`) |
| `ci` | CI/CD pipeline changes (`.github/`) |

Check the target repo's existing labels first:

```bash
gh label list --repo <owner>/<repo>
```

### Type labels (always apply exactly one)

| Label | When |
|---|---|
| `bug` | Fixes a bug |
| `enhancement` | New feature or improvement |
| `dependencies` | Dependency version updates |
| `documentation` | Documentation-only changes |
| `ci` | CI/CD pipeline changes |

### Examples

```bash
# Bug fix in backend
gh pr create --label "backend,bug" ...

# New feature spanning frontend + docs
gh pr create --label "frontend,documentation,enhancement" ...

# Add labels after creation
gh pr edit <number> --add-label "backend,bug"
gh issue edit <number> --add-label "frontend,enhancement"
```

## Editing a PR body

`gh pr edit` may fail with a deprecation warning — use the REST API PATCH instead:

```bash
gh api repos/<owner>/<repo>/pulls/<number> -X PATCH \
  -f title="<new title>" \
  -f body="<new body>" \
  --jq '.title'
```

## Replying to PR review comments

```bash
gh api repos/<owner>/<repo>/pulls/<pull_number>/comments/<comment_id>/replies \
  -X POST -f 'body=reply text'
```

Pitfalls:
1. **Missing pull number in path** — `/pulls/{pull_number}/comments/{comment_id}/replies`; omitting it returns 404.
2. **Backticks in double-quoted strings** — always use single quotes for `-f body=` when the body contains backticks.

## Viewing raw file content

```bash
gh api repos/<owner>/<repo>/contents/<path> \
  -H "Accept: application/vnd.github.raw"

# On a specific branch:
gh api "repos/<owner>/<repo>/contents/<path>?ref=<branch>" \
  -H "Accept: application/vnd.github.raw"
```

## Cleaning up after a merged PR

```bash
git switch main && git pull --ff-only
git branch -d <branch>
```
