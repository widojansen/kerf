# ExClaw — Multi-stage Dockerfile for Elixir release
#
# Build:   docker build -t exclaw:latest .
# Run:     docker compose up -d
#
# The final image contains only the compiled release (BEAM bytecode + ERTS).
# No source code, Mix, or Hex in the runtime image.

ARG ELIXIR_VERSION=1.19.4
ARG OTP_VERSION=28.0
ARG DEBIAN_VERSION=bookworm-20250428-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# =============================================================================
# Stage 1: Build
# =============================================================================
FROM --platform=$TARGETPLATFORM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install dependencies (cached layer — only rebuilds when lock changes)
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# Application source
COPY priv priv
COPY lib lib
RUN mix compile

# Runtime config (doesn't require recompilation)
COPY config/runtime.exs config/

# Release overlays
COPY rel rel

# Build the release
RUN mix release

# =============================================================================
# Stage 2: Runtime
# =============================================================================
FROM --platform=$TARGETPLATFORM ${RUNNER_IMAGE} AS runtime

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libstdc++6 \
    openssl \
    libncurses6 \
    locales \
    ca-certificates \
    curl \
    docker.io \
    tini \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod

WORKDIR /app

# Non-root user with docker group access for Container.Manager
RUN groupadd -r exclaw && useradd -r -g exclaw -d /app exclaw \
  && chown exclaw:exclaw /app \
  && usermod -aG docker exclaw 2>/dev/null || true

# Persistent data directories
RUN mkdir -p /app/data /app/workspaces /app/telemetry_fallback /app/whatsapp_auth \
  && chown -R exclaw:exclaw /app

# Copy release from builder (no source code — only compiled BEAM + ERTS)
COPY --from=builder --chown=exclaw:exclaw /app/_build/prod/rel/exclaw ./

# Entrypoint script
COPY --chown=exclaw:exclaw docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

USER exclaw

# Docker-appropriate defaults (overridable via compose/env)
ENV DASHBOARD_IP=0.0.0.0
ENV DASHBOARD_PORT=4000
ENV EXCLAW_DATA_DIR=/app/data
ENV EXCLAW_WORKSPACES_DIR=/app/workspaces
ENV EXCLAW_TELEMETRY_DIR=/app/telemetry_fallback

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:4000/ || exit 1

ENTRYPOINT ["tini", "--", "/app/docker-entrypoint.sh"]
CMD ["start"]
