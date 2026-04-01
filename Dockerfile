# syntax=docker/dockerfile:1.7
#
# Hephaestus Dev Container — Clojure + AI Coding Environment
#
# Build: docker build -t hephaestus-dev .
# Run:   docker run --rm -it -v $(pwd):/workspace hephaestus-dev
#
# Based on OpenClaw sandbox-common (Node.js, Python 3, Go, Bun, Homebrew, Rust)
# Layers: JDK 17 + Clojure CLI + AI coding tools + dev configuration
#
# Security Notes:
#   - Runs as non-root user 'node' by default
#   - Docker CLI included (no daemon); mount socket at your own risk
#   - All API keys/tokens must be passed at runtime via -e flags
#   - No secrets are baked into image layers

# =============================================================================
# Stage 1: OpenClaw sandbox (minimal base with core utilities)
# Source: https://github.com/openclaw/openclaw/blob/main/Dockerfile.sandbox
# =============================================================================
FROM debian:bookworm-slim@sha256:98f4b71de414932439ac6ac690d7060df1f27161073c5036a7553723881bffbe AS sandbox

ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,id=openclaw-sandbox-bookworm-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-sandbox-bookworm-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        python3 \
        ripgrep

RUN useradd --create-home --shell /bin/bash node

USER node
WORKDIR /home/node

# =============================================================================
# Stage 2: OpenClaw sandbox-common (adds language runtimes + tools)
# Source: https://github.com/openclaw/openclaw/blob/main/Dockerfile.sandbox-common
# =============================================================================
FROM sandbox AS sandbox-common

USER root

ENV DEBIAN_FRONTEND=noninteractive

ARG PACKAGES="curl wget jq coreutils grep nodejs npm python3 git ca-certificates golang-go rustc cargo unzip pkg-config libasound2-dev build-essential file"
ARG INSTALL_PNPM=1
ARG INSTALL_BUN=1
ARG BUN_INSTALL_DIR=/opt/bun
ARG INSTALL_BREW=1
ARG BREW_INSTALL_DIR=/home/linuxbrew/.linuxbrew
ARG FINAL_USER=node

ENV BUN_INSTALL=${BUN_INSTALL_DIR}
ENV HOMEBREW_PREFIX=${BREW_INSTALL_DIR}
ENV HOMEBREW_CELLAR=${BREW_INSTALL_DIR}/Cellar
ENV HOMEBREW_REPOSITORY=${BREW_INSTALL_DIR}/Homebrew
ENV PATH=${BUN_INSTALL_DIR}/bin:${BREW_INSTALL_DIR}/bin:${BREW_INSTALL_DIR}/sbin:${PATH}

RUN --mount=type=cache,id=openclaw-sandbox-common-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-sandbox-common-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends ${PACKAGES}

RUN if [ "${INSTALL_PNPM}" = "1" ]; then npm install -g pnpm; fi

RUN if [ "${INSTALL_BUN}" = "1" ]; then \
    curl -fsSL https://bun.sh/install | bash; \
    ln -sf "${BUN_INSTALL_DIR}/bin/bun" /usr/local/bin/bun; \
    fi

RUN if [ "${INSTALL_BREW}" = "1" ]; then \
    if ! id -u linuxbrew >/dev/null 2>&1; then useradd -m -s /bin/bash linuxbrew; fi; \
    mkdir -p "${BREW_INSTALL_DIR}"; \
    chown -R linuxbrew:linuxbrew "$(dirname "${BREW_INSTALL_DIR}")"; \
    su - linuxbrew -c "NONINTERACTIVE=1 CI=1 /bin/bash -c '$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)'"; \
    if [ ! -e "${BREW_INSTALL_DIR}/Library" ]; then ln -s "${BREW_INSTALL_DIR}/Homebrew/Library" "${BREW_INSTALL_DIR}/Library"; fi; \
    if [ ! -x "${BREW_INSTALL_DIR}/bin/brew" ]; then echo "brew install failed"; exit 1; fi; \
    ln -sf "${BREW_INSTALL_DIR}/bin/brew" /usr/local/bin/brew; \
    fi

USER ${FINAL_USER}

# =============================================================================
# Stage 2.5: JDK extraction helper
# BuildKit doesn't support ARG interpolation in COPY --from image names,
# so we use a separate FROM stage to pull the JDK image.
# =============================================================================
FROM eclipse-temurin:17-jdk AS jdk-source

# =============================================================================
# Stage 3: Hephaestus (Clojure + AI coding tools + dev configuration)
# This is where we add everything on top of the OpenClaw base.
# =============================================================================

FROM sandbox-common AS hephaestus

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Re-declare ARGs after FROM (Docker requirement)
ARG CLOJURE_VERSION=1.12.0.1530

# ---------------------------------------------------------------------------
# JDK 17 (Eclipse Temurin)
# Extracted from the official Temurin image via the jdk-source stage.
# This avoids GPG key management and ensures version pinning.
# ---------------------------------------------------------------------------
COPY --from=jdk-source /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# ---------------------------------------------------------------------------
# Clojure CLI (deps.edn)
# Installs the official Clojure command-line tool for dependency management.
# Significantly lighter than Leiningen — just a bash script + launcher jar.
# ---------------------------------------------------------------------------
ARG CLOJURE_VERSION
RUN curl -L -O "https://github.com/clojure/brew-install/releases/download/${CLOJURE_VERSION}/linux-install.sh" \
    && chmod +x linux-install.sh \
    && ./linux-install.sh \
    && rm linux-install.sh

# ---------------------------------------------------------------------------
# Missing utilities (not in sandbox-common)
# ---------------------------------------------------------------------------
RUN --mount=type=cache,id=hephaestus-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=hephaestus-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        tmux \
        nano \
        htop \
        openssh-client \
        zip \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Neovim (via Homebrew — must run as linuxbrew user, not root)
# ---------------------------------------------------------------------------
USER linuxbrew
RUN /home/linuxbrew/.linuxbrew/bin/brew install neovim
USER root
RUN ln -sf /home/linuxbrew/.linuxbrew/bin/nvim /usr/local/bin/nvim

# ---------------------------------------------------------------------------
# TypeScript
# ---------------------------------------------------------------------------
RUN npm install -g typescript ts-node

# ---------------------------------------------------------------------------
# OpenCode CLI (AI coding assistant)
# ---------------------------------------------------------------------------
ENV CI=1
ENV TERM=dumb
RUN curl -fsSL https://opencode.ai/install | bash

# ---------------------------------------------------------------------------
# Oh My OpenAgent (OmO) — Plugin for OpenCode CLI
# Multi-model agent harness for AI-assisted coding.
# ---------------------------------------------------------------------------
RUN npm install -g oh-my-opencode \
    && mkdir -p /home/node/.config/opencode

# ---------------------------------------------------------------------------
# Docker CLI (extracted from official docker:cli image, no daemon)
# Mount host socket at runtime: -v /var/run/docker.sock:/var/run/docker.sock
#
# WARNING: Mounting the Docker socket grants the container root-level access
# to the host system. Only use in trusted development environments.
COPY --from=docker:29-cli /usr/local/bin/docker /usr/local/bin/docker

# ---------------------------------------------------------------------------
# Workspace and SSH setup
# ---------------------------------------------------------------------------
RUN mkdir -p /workspace \
    && chown node:node /workspace

RUN mkdir -p /home/node/.ssh \
    && chmod 700 /home/node/.ssh \
    && chown node:node /home/node/.ssh

# ---------------------------------------------------------------------------
# Docker group for socket access
# ---------------------------------------------------------------------------
RUN groupadd -r docker 2>/dev/null || true \
    && usermod -aG docker node

# ---------------------------------------------------------------------------
# Git global configuration (overridable at runtime via env vars)
# ---------------------------------------------------------------------------
USER node
RUN git config --global user.name "Developer" \
    && git config --global user.email "developer@example.com" \
    && git config --global init.defaultBranch main

# ---------------------------------------------------------------------------
# Environment variable placeholders for API credentials
# All values are empty by default — pass real values at runtime via -e flags.
# ---------------------------------------------------------------------------
ENV GITEA_USERNAME="" \
    GITEA_TOKEN="" \
    GITEA_URL="http://gitea:3000" \
    ZAI_API_KEY="" \
    ZAI_BASE_URL="https://api.z.ai" \
    DASHSCOPE_API_KEY="" \
    DASHSCOPE_BASE_URL="https://coding-intl.dashscope.aliyuncs.com/v1" \
    OPENAI_API_KEY="" \
    ANTHROPIC_API_KEY="" \
    GIT_USER_NAME="" \
    GIT_USER_EMAIL=""

# ---------------------------------------------------------------------------
# Entrypoint script — configures credentials at runtime
# ---------------------------------------------------------------------------
COPY --chmod=755 <<'ENTRYPOINT' /usr/local/bin/entrypoint.sh
#!/bin/bash
set -e

# Configure Gitea credentials at runtime if env vars are set
if [ -n "$GITEA_URL" ] && [ -n "$GITEA_TOKEN" ]; then
    git config --global credential.helper store
    echo "https://${GITEA_USERNAME}:${GITEA_TOKEN}@${GITEA_URL}" > /home/node/.git-credentials
    chmod 600 /home/node/.git-credentials
fi

# Override git user config if env vars are set
[ -n "$GIT_USER_NAME" ] && git config --global user.name "$GIT_USER_NAME"
[ -n "$GIT_USER_EMAIL" ] && git config --global user.email "$GIT_USER_EMAIL"

exec "$@"
ENTRYPOINT

# ---------------------------------------------------------------------------
# Final configuration
# ---------------------------------------------------------------------------
VOLUME ["/workspace"]
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
