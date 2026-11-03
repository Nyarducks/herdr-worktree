# herdr-worktree

herdr-worktree drives multi-repository development through worktrees. All code changes flow through isolated `git worktree` checkouts — the base repository is never edited directly. This is a convention; nothing is sandboxed.

## Supports

| OS | Status |
|---|:---:|
| Linux | ✔ |
| macOS | ✔ |
| Windows | ✖ |

At least one agent CLI is needed to dispatch workers (`--kind`):

| Agent | Status |
|---|:---:|
| [Claude Code](https://claude.ai/code) | ✔ |
| [Devin CLI](https://docs.devin.ai/cli) | ✔ |
| [Codex CLI](https://github.com/openai/codex) | - |
| [Antigravity](https://antigravity.google) | ✔ |
| [pi](https://github.com/earendil-works/pi) | ✔ |

## Requirements

| Tool | Purpose | Install |
|---|---|---|
| `git` ≥ 2.5 | Worktree support | Linux: [below](#installing-git-and-gh-on-linux) / `brew install git` |
| `gh` (GitHub CLI) | Clone, PR creation, repo auth | Linux: [below](#installing-git-and-gh-on-linux) / `brew install gh` |
| `jq` | Agent settings JSON edits in `spawn-repo-agent.sh` | `sudo apt install jq` / `brew install jq` |
| `bash` ≥ 4.3 | Script runtime | Pre-installed on Linux; macOS ships bash 3 — `brew install bash` |
| `herdr` | Orchestration for dispatched workers | `curl -fsSL https://herdr.dev/install.sh \| sh` / `brew install herdr` |

### Installing git and gh on Linux

Do not install `git` or `gh` from the distribution's default apt
repositories — they can ship outdated versions. Use the upstream
repositories instead.

`git` (git-core PPA):

```bash
sudo add-apt-repository ppa:git-core/ppa
sudo apt update
sudo apt install git
```

`gh` (GitHub CLI apt repository):

```bash
(type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
    && sudo mkdir -p -m 755 /etc/apt/keyrings \
    && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && sudo apt update \
    && sudo apt install gh -y
```

## Quick start

Open your agent CLI in this repo and ask:

> Implement user auth in `myorg/myapp` — add a login endpoint with tests

The orchestrator dispatches a worker to do it — it never edits
other repos in-process, and asks which agent kind/repo if you haven't
said. To work on herdr-worktree itself, ask the same way ("fix X in
this repo") — the orchestrator follows the `development` skill and
works directly in this checkout on a feature branch.

## Documentation

| Doc | Contents |
|---|---|
| [`docs/adr/`](docs/adr/) | Architecture decision records |
| [`docs/design/`](docs/design/) | Design docs — start at the directory README |
| [`docs/reference/`](docs/reference/) | Fact inventories — agent configs, skills, scripts |
| [`development` skill](.agents/skills/development/SKILL.md) | Always-follow rules for changing herdr-worktree |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Development rules |
