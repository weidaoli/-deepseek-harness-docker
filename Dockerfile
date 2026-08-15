# syntax=docker/dockerfile:1

# ============================================================================
# DeepSeek Harness (dsh) — https://github.com/deepseek-ai/deepseek-harness
#
# Two-stage build:
#   builder — clones the repo, installs deps, compiles the monorepo
#   runtime — minimal image that runs the Web UI (or any dsh profile)
#
# The Web UI listens on 127.0.0.1:3080 *by design*: the project deliberately
# rejects `--host 0.0.0.0` because it would expose remote code execution to
# the network. To reach the UI from the host, use `--network host` (Linux),
# see README.md for details and alternatives.
# ============================================================================

ARG NODE_IMAGE=node:24-bookworm-slim

# --------------------------------------------------------------------------
# Stage 1: builder
# --------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS builder

# git >= 2.26 is required by the repo's postinstall (lefthook) hook.
# python3/make/g++ are insurance for native modules without prebuilt binaries.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git python3 make g++ \
 && rm -rf /var/lib/apt/lists/*

# Pin pnpm to the version the repo declares (`packageManager: pnpm@11.7.0`).
# Installing via npm is deterministic and independent of the corepack version
# bundled with the base image.
RUN npm install -g pnpm@11.7.0

ARG REPO_URL=https://github.com/deepseek-ai/deepseek-harness.git
ARG BRANCH=master

RUN git clone --depth 1 --branch "$BRANCH" "$REPO_URL" /src

WORKDIR /src

# CI sets this so builds never report to the production telemetry endpoint.
ENV DSH_TELEMETRY_DISABLED=1

# Node >= 24 is required at build time: tsdown falls back to an uninstalled
# `unrun` loader on Node 22 (native TypeScript support is Node 24+).
RUN pnpm install --frozen-lockfile
RUN pnpm run build

# Quick sanity check that the compiled launcher works.
RUN node apps/cli/lib/bin.js --version

# --------------------------------------------------------------------------
# Stage 2: runtime
# --------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

# curl: healthcheck + convenience; git/python3/procps: handy for agent tasks.
# socat: optional loopback relay so `-p` port publishing works with the
# loopback-bound server on Docker Desktop/WSL2 (see README).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 procps socat \
 && rm -rf /var/lib/apt/lists/* \
 # UID 1000 is taken by the base image's `node` user, so dsh gets 1001.
 && useradd --create-home --uid 1001 dsh

# The fully built checkout (source + node_modules + build artifacts).
# `apps/cli/lib/bin.js` is the compiled launcher and needs no tsx/pnpm.
COPY --from=builder /src /opt/deepseek-harness

# Shared working directory. Mount a host directory here, e.g.
#   -v "$PWD:/workspace"
# dsh uses its invoking directory as the default filesystem location, and the
# entrypoint starts from $DSH_WORKSPACE so the mounted volume is the default.
RUN mkdir -p /workspace && chown dsh:dsh /workspace \
 # Pre-create the dsh home so a fresh volume mounted over it inherits dsh
 # ownership via Docker's copy-up (otherwise the volume root is root-owned
 # and the dsh user cannot create profiles/node_modules inside it).
 && mkdir -p /home/dsh/.dsh && chown -R dsh:dsh /home/dsh

USER dsh

ENV DSH_TELEMETRY_DISABLED=1 \
    DSH_HOME=/home/dsh/.dsh \
    DSH_WORKSPACE=/workspace

COPY --chown=dsh:dsh entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

# Informational only — the server binds 127.0.0.1:3080 inside the container.
# Use `docker run --network host` (or a loopback relay, see README) to access it.
EXPOSE 3080

# Meaningful for `web` mode (the default CMD); other profiles will report
# unhealthy, which is expected.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3080/ >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["web"]
