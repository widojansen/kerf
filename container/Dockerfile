# ExClaw Sandbox Container
# Minimal Debian image with common development tools.
# Runs as non-root user 1000 with read-only filesystem.
#
# Build: docker build -t exclaw-sandbox:latest container/
# Usage: Managed by ExClaw.Container.Manager — not run directly.

FROM debian:bookworm-slim

# Install commonly needed tools for agent tasks
RUN apt-get update && apt-get install -y --no-install-recommends \
    coreutils \
    bash \
    curl \
    jq \
    python3 \
    python3-pip \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -g 1000 sandbox && \
    useradd -u 1000 -g sandbox -m -s /bin/bash sandbox

# Create workspace directory owned by sandbox user
RUN mkdir -p /workspace && chown sandbox:sandbox /workspace

WORKDIR /workspace
USER sandbox

# Default command: keep alive for docker exec
CMD ["sleep", "infinity"]
