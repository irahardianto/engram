# syntax=docker/dockerfile:1.7

# ==============================================================================
# Stage 1: Cargo Chef Base & Planner
# ==============================================================================
FROM rust:1.98-bookworm AS chef
RUN cargo install cargo-chef --version 0.1.71 --locked
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ==============================================================================
# Stage 2: Dependency Caching & Release Compilation
# ==============================================================================
FROM chef AS builder
WORKDIR /app

# Build dependencies only (cached layer)
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json --features otlp

# Build Engram application binary with OTLP telemetry feature (ADR-16: stripped binary <= 25 MB)
COPY . .
RUN cargo build --release --features otlp --bin engram && \
    strip /app/target/release/engram

# ==============================================================================
# Stage 3: Official SurrealDB Engine Extraction
# ==============================================================================
FROM surrealdb/surrealdb:v3.3.4 AS surreal

# ==============================================================================
# Stage 4: Production Runtime Image (ADR-16 budget: <= 650 MB uncompressed / <= 160 MB compressed pull)
# ==============================================================================
FROM debian:bookworm-slim AS runtime

# Install CA certificates and process supervisor init (tini) only.
# No curl, wget, or python in production runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Dedicated unprivileged user & group (UID/GID 10001)
RUN groupadd -g 10001 engram && \
    useradd -u 10001 -g engram -m -d /app -s /bin/bash engram

# Create persistent storage layout and set ownership
RUN mkdir -p /data/surreal /data/secrets /data/backups && \
    chown -R engram:engram /data /app

# Copy official SurrealDB engine binary (verified glibc-compatible)
COPY --from=surreal /surreal /usr/local/bin/surreal
RUN chmod 755 /usr/local/bin/surreal

# Copy compiled Engram service binary
COPY --from=builder --chown=engram:engram /app/target/release/engram /usr/local/bin/engram
RUN chmod 755 /usr/local/bin/engram

# Drop privileges to non-root user
USER engram:engram
WORKDIR /app

# Service environment defaults
ENV ENGRAM_BIND=0.0.0.0:8080 \
    ENGRAM_DATA_DIR=/data \
    ENGRAM_SURREAL_MODE=managed \
    ENGRAM_SURREAL_ENGINE=rocksdb \
    ENGRAM_SURREAL_BINARY=/usr/local/bin/surreal \
    ENGRAM_TELEMETRY_LOG_FORMAT=json \
    RUST_LOG=info,engram=info,surreal=warn

# Expose unified HTTP and MCP Streamable port
EXPOSE 8080

# Persistent storage mount point for RocksDB data and secrets
VOLUME ["/data"]

# Native healthcheck using Engram's built-in probe (zero external dependencies)
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/engram", "healthcheck"]

# Orderly shutdown signal propagation
STOPSIGNAL SIGTERM

# OCI standard container metadata
LABEL org.opencontainers.image.title="Engram" \
      org.opencontainers.image.description="Unified long-term memory engine for AI agents on SurrealDB" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.vendor="irahardianto" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/irahardianto/engram"

# Tini runs as PID 1, reaping zombies and passing signals to engram supervisor
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/engram"]
CMD ["serve"]
