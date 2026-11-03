# Architecture decision records

ADRs record significant decisions in Context / Decision / Consequences
form, numbered sequentially as `NNNN-<slug>.md`, with OKF v0.2 frontmatter
(`type: ADR`, `status`, `last_modified`). Write one in the same commit as
the change that introduces the decision; see `CONTRIBUTING.md`.

| ADR | Decision |
|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions — this convention itself |
| [0002](0002-one-worktree-per-task.md) | One detached worktree per dispatched task; base clones never edited |
| [0003](0003-herdr-native-dispatch.md) | Dispatch through herdr-native workspaces/tabs/panes; other repos always dispatched |
| [0004](0004-worker-self-naming.md) | Workers rename their own agent and tab |
| [0005](0005-skills-instead-of-root-context-files.md) | Canonical `.agents/skills`; no root `AGENTS.md`/`CLAUDE.md` |
| [0006](0006-develop-in-checkout.md) | Develop herdr-worktree in its own checkout on a feature branch |
| [0007](0007-no-confinement.md) | No sandbox and no guard hooks |
| [0008](0008-startup-and-prompt-recovery.md) | Fail fast on startup errors; recover prompt submission, never into a dialog |
| [0009](0009-pre-answer-first-run-dialogs.md) | Pre-answer agent first-run dialogs for new worktrees |
| [0010](0010-model-and-effort-pass-through.md) | Pass model and effort to workers; cache each CLI's model catalog |
| [0011](0011-macos-portability.md) | Support macOS with portable locking and BSD-safe tooling |
