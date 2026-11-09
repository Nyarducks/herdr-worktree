# Environment sources and what the instance needs for them

Read files with `gh api repos/<owner>/<repo>/contents/<path> --jq .content | base64 -d`;
list them with `gh api 'repos/<owner>/<repo>/git/trees/HEAD?recursive=1' --jq '.tree[].path'`.

| Source | Read | The instance |
|---|---|---|
| `flake.nix` + `flake.lock` (any directory) | `devShells`, `nixpkgs` revision | nothing: the default image has Nix with flakes; `/nix`, `~/.local/state/nix` and `~/.cache/nix` persist, so `nix develop` fetches once per instance |
| unfree or source-built flake packages (e.g. `terraform` with `allowUnfreePredicate`) | the flake's `config` | nothing; mention that the first `nix develop` of that shell compiles |
| `devbox.json` | packages | a custom image that installs devbox (it uses the same Nix store) |
| `mise.toml`, `.tool-versions` | tools | a custom image that installs mise; add `.local/share/mise` to `persist` so installed runtimes survive |
| version files without an environment (`.python-version`, `.nvmrc`, `engines`, `go.mod`, `rust-toolchain.toml`) | version | a custom image with that version (the default image's Node.js tarball step is the pattern: checksum-verified official download) |
| `packageManager` (`pnpm@x`, `yarn@x`) | version | nothing: `corepack` ships with Node.js |
| `.devcontainer/devcontainer.json` | `image`, `features` | the same tools in a custom image; do not base the image on it (the herdr-worktree contract must hold); a `docker-in-docker` feature means `--docker` |
| `compose*.y*ml`, CI `services:`, CI steps running `docker` | images, ports, env | `--docker`; the worker runs the repository's compose file |
| Playwright (`@playwright/test`) | its version | only when asked: browsers in a custom image (`npx playwright@<v> install --with-deps chromium`, hundreds of MB) |

## Custom image block

`plugins/instances/bin/instance image new <image>` copies `docker/default`. Add one
block between the Claude Code step and `COPY … herdr-worktree` (so a
checkout change does not rebuild it), fenced by `# --- Repository
toolchain` / `# --- end of repository toolchain`, saying where each
version came from and what was left out. Keep the default image's
contract: sshd via the entrypoint, user `dev`, `git`, `gh`, `jq`,
`herdr`, Docker Engine, `~/herdr-worktree`, `persist` copied to
`/etc/herdr-worktree/persist`, and `~/.persist`.

Do not `nix profile install` a repository's flake packages into the
image: they go stale when the repository updates its lock file and
shadow the dev shell on `PATH`.

## Checking `--docker`

```bash
ssh <name> 'docker info --format "{{.ServerVersion}}"
  docker run -d --name svc -p 127.0.0.1:<port>:<port> <image from compose/CI> …
  # wait for the service: its own readiness command, or curl until it answers
  docker rm -f svc'
```

Some services take a few seconds after the container starts (an HTTP
emulator answers `000` at first); wait in a loop rather than checking
once.
