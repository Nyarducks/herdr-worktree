# syntax=docker/dockerfile:1
#
# herdr-worktree development environment: Ubuntu with git, gh, jq, bats, herdr,
# sshd, Nix and Node.js preinstalled, and this checkout at
# /home/<user>/herdr-worktree. Built by the instances plugin (compose.yml)
# with the checkout as the build context and this directory as the `image`
# context (COPY --from=image). This is the default image (docker/default,
# versioned); custom images live in other, git-ignored docker/<name>/ dirs.
# See plugins/instances/README.md.

ARG UBUNTU_VERSION=26.04
FROM ubuntu:${UBUNTU_VERSION}


ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
# Node.js 26 LTS (Lithium) and Nix — bump together with plugins/instances/README.md
ARG NODE_VERSION=26.13.0
ARG NIX_VERSION=2.35.4

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# Base packages. git and gh come from their upstream apt repositories, not
# Ubuntu's (see README: the distribution's versions can lag).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils sudo openssh-server jq bats less vim-tiny \
      libatomic1 \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF911AB184317630C59970973E363C90F8F1B6217" \
      -o /etc/apt/keyrings/git-core-ppa.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/git-core-ppa.asc] https://ppa.launchpadcontent.net/git-core/ppa/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") main" \
      > /etc/apt/sources.list.d/git-core-ppa.list \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends git gh \
 && rm -rf /var/lib/apt/lists/*

# Docker Engine from Docker's apt repository, for instances with Docker inside
# (an instance with docker: true: sysbox-runc runtime, no --privileged; the
# entrypoint starts dockerd only when HW_DOCKER=1). Lets a worker run the
# repository's own `docker compose` (databases, emulators, integration tests).
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin iptables \
 && rm -rf /var/lib/apt/lists/* \
 && docker --version && docker compose version

# Node.js from the official tarball, checked against SHASUMS256.txt.
RUN case "$(dpkg --print-architecture)" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac \
 && tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
 && cd /tmp \
 && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${tarball}" \
 && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep " ${tarball}\$" | sha256sum -c - \
 && tar -xJf "${tarball}" -C /usr/local --strip-components=1 --no-same-owner \
 && rm "${tarball}" \
 && node --version && npm --version

# herdr (the TUI CLI). The installer verifies the binary's sha256 against
# the release manifest; it always installs the current stable release.
RUN curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh \
 && herdr --version

# The working user. Ubuntu images ship an `ubuntu` user at UID 1000; drop it
# so the configured UID is free.
RUN if id ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \
 && groupadd --gid "${USER_GID}" "${USERNAME}" \
 && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}" \
 && usermod -aG docker "${USERNAME}" \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
 && chmod 0440 "/etc/sudoers.d/${USERNAME}"

# sshd: public-key login for the working user only. The plugin writes
# /etc/ssh/authorized_keys/<user> through `docker compose exec` stdin after
# each start (nothing is mounted from the host); host keys live in a volume
# so they survive rebuilds.
COPY --from=image sshd_config /etc/ssh/sshd_config.d/herdr-worktree.conf
RUN sed -i "s/@USERNAME@/${USERNAME}/" /etc/ssh/sshd_config.d/herdr-worktree.conf \
 && install -d -m 0755 /etc/ssh/authorized_keys /etc/ssh/host_keys /run/sshd

# Nix, single-user (no daemon in a container). Flakes are on so
# `nix develop` works in this checkout. No channel: flakes pin their own
# nixpkgs, and the nixpkgs-unstable channel alone is about 490 MB.
RUN install -d -m 0755 -o "${USERNAME}" -g "${USERNAME}" /nix \
 && install -d -m 0755 /etc/nix \
 && printf '%s\n' 'experimental-features = nix-command flakes' 'sandbox = false' > /etc/nix/nix.conf
USER ${USERNAME}
ENV USER=${USERNAME}
RUN curl -fsSL "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" | sh -s -- --no-daemon --no-channel-add \
 && sed -i "1i [ -e \"\${HOME}/.nix-profile/etc/profile.d/nix.sh\" ] \&\& . \"\${HOME}/.nix-profile/etc/profile.d/nix.sh\"" "${HOME}/.bashrc" \
 && "${HOME}/.nix-profile/bin/nix" --version

# Claude Code (native installer, into ~/.local). Its whole configuration —
# login, settings and ~/.claude.json — lives in CLAUDE_CONFIG_DIR (~/.claude,
# kept in the state volume via persist), so a recreated container stays
# logged in. Both exports go at
# the top of ~/.bashrc so non-interactive ssh commands see them too.
ENV CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude
RUN mkdir -p "${CLAUDE_CONFIG_DIR}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && sed -i -e "1i export CLAUDE_CONFIG_DIR=\"\${HOME}/.claude\"" \
      -e "1i export PATH=\"\${HOME}/.local/bin:\${PATH}\"" "${HOME}/.bashrc" \
 && "${HOME}/.local/bin/claude" --version

# This checkout. repos/ and worktree/ are mount points for volumes.
COPY --chown=${USERNAME}:${USERNAME} . /home/${USERNAME}/herdr-worktree
# ~/.persist is the mount point of the state volume (logins and settings,
# see persist).
RUN mkdir -p "${HOME}/herdr-worktree/repos" "${HOME}/herdr-worktree/worktree" "${HOME}/.config" "${HOME}/.persist"

USER root
# The paths the entrypoint keeps in the state volume.
COPY --from=image persist /etc/herdr-worktree/persist
ENV HW_USER=${USERNAME}
COPY --from=image entrypoint.sh /usr/local/bin/herdr-worktree-entrypoint
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/herdr-worktree-entrypoint"]
