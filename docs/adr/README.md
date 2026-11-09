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
| [0012](0012-language-contract-and-worker-steering.md) | Think in English, reply in the human's language; steer workers by natural-language reference (relay rule for working workers replaced by 0023) |
| [0013](0013-ubuntu-dev-container.md) | Ship an Ubuntu development container reachable over SSH |
| [0014](0014-instance-manifest.md) | Keep instances in a git-ignored manifest; restart containers, explain remote hosts; renameable labels |
| [0015](0015-custom-container-images.md) | Version docker/default; build custom images from git-ignored docker/<image>/ dirs |
| [0016](0016-one-state-volume.md) | Keep an instance's logins in one state volume, with a list of persisted paths |
| [0017](0017-docker-inside-with-sysbox.md) | Run Docker inside an instance with Sysbox, never --privileged; mount nothing from the host; cache /nix |
| [0018](0018-plugins-and-typescript-instances.md) | Make multi-instance support a plugin behind a small contract, written in TypeScript |
| [0019](0019-link-plugin-skills.md) | Link an enabled plugin's skills into .agents/skills |
| [0020](0020-two-way-label-sync.md) | Sync instance labels both ways: the side that changed wins |
| [0021](0021-bats-and-sourceable-modules.md) | Test shell with bats; write scripts as sourceable modules |
| [0022](0022-plugin-enable-disable-hooks.md) | Plugins may hook enable and disable; instances takes its machines out of herdr while off |
| [0023](0023-queue-prompts-without-blocking.md) | Send prompts to a working worker at once; never block on its turn |
