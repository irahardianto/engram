# Engram — Deployment & Operations Specification (08-deployment-operations)

**Status:** Accepted (v1 baseline) · **Date:** 2026-10-24 · **Owner:** irahardianto  
**Binding Inputs:** [`00-decisions.md`](00-decisions.md) (ADR-01, ADR-02, ADR-03, ADR-04, ADR-14, ADR-15, ADR-16, §3.1, §3.5, §3.7)  
**Research & Verifications:** [`06-rust-stack-deployment.md`](../research/06-rust-stack-deployment.md), [`V06-rust-stack-deployment.md`](../research/verification/V06-rust-stack-deployment.md), [`05-surrealdb.md`](../research/05-surrealdb.md), [`V05-surrealdb.md`](../research/verification/V05-surrealdb.md), [`01-hindsight.md`](../research/01-hindsight.md) §8  
**Companion Artifacts:** [`Dockerfile`](../../Dockerfile), [`docker-compose.yml`](../../docker-compose.yml), [`docker-compose.external.yml`](../../docker-compose.external.yml)

---

## 1. Distribution Matrix

Engram supports three primary deployment topologies. To minimize operational friction for agent developers while maintaining production flexibility for platform teams, the **All-in-One Container Image** is the primary tier-1 distribution format defined by ADR-03.

```mermaid
flowchart TD
    subgraph Topology1["1. All-in-One Container Image (Default / Primary)"]
        Docker1["Single Container (ghcr.io/irahardianto/engram:0.1.0)"]
        Tini1["tini (PID 1)"]
        Engram1["engram serve (PID child)"]
        Surreal1["surreal start (Managed Child Process)"]
        Vol1[("/data (Volume: RocksDB + Secrets)")]
        
        Docker1 --> Tini1
        Tini1 --> Engram1
        Engram1 -->|"supervises & probes (127.0.0.1:8000)"| Surreal1
        Engram1 -->|"reads/writes"| Vol1
        Surreal1 -->|"persists"| Vol1
    end

    subgraph Topology2["2. Bare Metal Binary"]
        HostOS["Host OS (Linux x86_64 / aarch64)"]
        Engram2["engram binary (systemd / CLI)"]
        Surreal2["surreal binary (on system PATH)"]
        DataDir2[("/var/lib/engram or ~/.engram")]
        
        HostOS --> Engram2
        Engram2 -->|"executes & manages"| Surreal2
        Engram2 --> DataDir2
        Surreal2 --> DataDir2
    end

    subgraph Topology3["3. External SurrealDB Topology"]
        ComposeNet["Private Docker Bridge / Kubernetes Pod Network"]
        Engram3["engram container (ENGRAM_SURREAL_MODE=external)"]
        Surreal3["surrealdb/surrealdb:v3.3.4 (Dedicated Container / Cluster)"]
        RemoteDB[("RocksDB / TiKV Storage Engine")]
        
        ComposeNet --> Engram3
        ComposeNet --> Surreal3
        Engram3 -->|"POST /rpc (HTTP Basic Auth)"| Surreal3
        Surreal3 --> RemoteDB
    end
```

### 1.1 Topology Comparison

| Metric / Attribute | 1. All-in-One Container (Primary) | 2. Bare Metal Binary | 3. External SurrealDB Topology |
|---|---|---|---|
| **Target Audience** | Agent users, local developers, single-node VPS | Embedded systems, NixOS/Arch hosts, air-gapped workstations | Enterprise Kubernetes, high-availability clusters, shared DBaaS |
| **Packaging** | OCI Container (`ghcr.io/irahardianto/engram:<version>`) | Standalone ELF binary (`engram`) + system `surreal` | Multi-container Compose / Helm Chart |
| **SurrealDB Supervision** | Managed internally by Engram (`tokio::process`) | Managed internally by Engram via `$PATH` | Managed externally by orchestrator / Docker Compose |
| **SurrealDB Network** | Container loopback (`127.0.0.1:8000`, unpublished) | Host loopback (`127.0.0.1:8000`) | Network bridge (`http://surrealdb:8000`) |
| **Storage Engine** | RocksDB (`rocksdb:///data/surreal`) | RocksDB (`rocksdb:///path/to/data`) | RocksDB / TiKV / SurrealKV |
| **Memory Footprint** | ~350 MiB to 1.5 GiB (depending on HNSW scale) | ~300 MiB to 1.2 GiB | ~80 MiB (Engram) + External DB RAM |
| **Credentials Setup** | Fully automatic; generated and persisted to disk | Fully automatic; generated to local secrets directory | Explicit env (`ENGRAM_SURREAL_USER`, `ENGRAM_SURREAL_PASS`) |
| **Recommended Command** | `docker run -d --name engram -p 127.0.0.1:8080:8080 -v engram-data:/data --add-host=host.docker.internal:host-gateway ghcr.io/irahardianto/engram:latest` | `engram serve` | `ENGRAM_SURREAL_PASS=… docker compose -f docker-compose.external.yml up -d` |

---

## 2. Dockerfile Architecture & Line-by-Line Breakdown

The official container build uses a four-stage, multi-platform Dockerfile optimized for layer caching, minimal supply-chain surface, and strict non-root privilege isolation.

### 2.1 Complete Production Dockerfile

```dockerfile
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
```

### 2.2 Line-by-Line Architectural Rationale

1. **`# syntax=docker/dockerfile:1.7`**: Enables BuildKit caching mounts, cache export, and fine-grained `COPY` semantics.
2. **`FROM rust:1.98-bookworm AS chef` & `cargo install cargo-chef`**: We pin `rust:1.98-bookworm` to guarantee compatibility with `rmcp 3.7.0` (MSRV 1.88) and Tokio 1.54. `cargo-chef` inspects `Cargo.lock` and generates a minimal `recipe.json` to cache all compiled dependencies in an independent Docker layer. Changes to source files (`src/**/*.rs`) do not invalidate compiled dependency caches, reducing incremental build times from >70s to <4s in CI.
3. **`RUN cargo chef cook --release --recipe-path recipe.json --features otlp`**: Pre-compiles the entire dependency graph (including Axum 0.8, Tower 0.5, OpenTelemetry 0.33, rmcp 3.7) with the `otlp` feature flag activated.
4. **`strip /app/target/release/engram`**: Strips debug symbols from the final ELF binary, reducing binary footprint from ~110 MB to ≤ 24 MB.
5. **`FROM surrealdb/surrealdb:v3.3.4 AS surreal`**: Extracts the official statically linked `surreal` engine binary located at `/surreal`. As confirmed by V05 and V06, the official SurrealDB Docker image is built on Chainguard glibc-dynamic and contains no shell or system utilities.
6. **`FROM debian:bookworm-slim AS runtime`**: Provides glibc 2.36 runtime environment matching the builder. Avoids Alpine/musl to prevent allocator performance degradation and RocksDB C++ binding friction.
7. **`RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tini`**:
   - `ca-certificates`: Required for TLS verification when Engram executes outbound HTTPS calls to external LLMs and embedding providers (OpenRouter, OpenAI).
   - `tini`: Acts as PID 1 to reap zombie processes and correctly route OS signals (`SIGTERM`). Under ADR-03 and FIND-06, the `surreal` child process is spawned in its own process group (`process_group(0)`) so group-directed signals from the runtime or terminal reach only `engram`. `engram` then coordinates the ordered 5-phase shutdown sequence: (1) stop accepting incoming HTTP/MCP traffic; (2) finish in-flight requests (≤ 10 s); (3) permit active outbox workers to commit or release leases (≤ 15 s); (4) send SIGTERM to `surreal` via `libc::kill(pid, SIGTERM)` and wait up to 10 s (`child.kill()` SIGKILL fallback on timeout); (5) exit. This ordered sequence requires Docker `stop_grace_period ≥ 40s`.
   - **Absence of `curl` / `wget`**: Removes common attack vectors and reduces runtime image layers. Health checking is offloaded entirely to `engram healthcheck`.
8. **`RUN groupadd -g 10001 engram && useradd -u 10001 -g engram ...`**: Creates a deterministic, non-root user and group (`10001:10001`). Running as root in production containers is strictly prohibited.
9. **`RUN mkdir -p /data/surreal /data/secrets /data/backups && chown -R engram:engram /data /app`**: Pre-creates the three standard subdirectories required by ADR-03 and ADR-14, ensuring write permissions before any volume is mounted.
10. **`COPY --from=surreal /surreal /usr/local/bin/surreal`**: Installs the SurrealDB engine at `/usr/local/bin/surreal` with execute permissions (`0755`).
11. **`HEALTHCHECK ... CMD ["/usr/local/bin/engram", "healthcheck"]`**: Native healthcheck binary probe that checks HTTP status on `http://127.0.0.1:8080/readyz`. Returns exit code 0 if healthy, 1 if unavailable.
12. **`ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/engram"]` & `CMD ["serve"]`**: Enforces that `tini` is always PID 1. Default arguments launch the `serve` subcommand, which initializes logging, boots the managed SurrealDB supervisor, applies forward migrations, and starts the Axum/MCP server.

### 2.3 Empirical Verification Findings (Live Test)

The runtime container architecture was verified on October 24, 2026 (VS4 verification report):
- **Binary Compatibility**: `/surreal` from `surrealdb/surrealdb:v3.3.4` runs without symbol errors or missing shared libraries inside `debian:bookworm-slim`.
- **Non-Root Execution**: Verified that `surreal start --bind 127.0.0.1:8000 --user root --pass x rocksdb:///tmp/s` executes cleanly under UID `10001`. RocksDB SST files and write-ahead logs were created and flushed without permission issues.
- **Graceful Shutdown**: Intercepting `SIGTERM` caused SurrealDB to cancel background compactions and cleanly flush WAL buffers in 2.4s.
- **Image Size Metrics (ADR-16 Compliance)**:
  - Official `surreal` 3.3.4 binary: **352 MB uncompressed** / **105 MB gzipped**
  - Base runtime OS (`debian:bookworm-slim` + `ca-certificates` + `tini`): **~93.2 MB**
  - Stripped `engram` binary (with OTLP enabled): **7.41 MB** (7.41 MB default; 218 normal crates default / 245 with otlp; ceiling ≤ 25 MB)
  - Final image uncompressed size: **584.03 MB** (budget ≤ 650 MB; margin: -65.97 MB) $\to$ **PASS**
  - Final image compressed export / pull size: **140.76 MB** (budget ≤ 160 MB; margin: -19.24 MB) $\to$ **PASS**

### 2.4 Multi-Architecture Build Matrix (AMD64 / ARM64)

Engram official images are built for both `linux/amd64` and `linux/arm64` using Docker Buildx:
```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag ghcr.io/irahardianto/engram:0.1.0 \
  --tag ghcr.io/irahardianto/engram:latest \
  --push .
```
Both `rust:1.98-bookworm` and `surrealdb/surrealdb:v3.3.4` publish native multi-arch manifests. On ARM64 (Apple Silicon, AWS Graviton), Buildx cross-compiles natively without QEMU emulation slowdowns when executed on native builders.

---

## 3. First-Run Experience & Consumer Integration

### 3.1 The First-Run Command

To launch Engram with sensible defaults (RocksDB persistence, Asia/Jakarta local time, Ollama host bridge):

```bash
docker run -d \
  --name engram \
  -p 127.0.0.1:8080:8080 \
  -v engram-data:/data \
  --add-host=host.docker.internal:host-gateway \
  -e ENGRAM_SERVER_TIMEZONE=Asia/Jakarta \
  ghcr.io/irahardianto/engram:0.1.0
```

> [!IMPORTANT]
> Always bind the host port to loopback (`127.0.0.1:8080:8080`) rather than `0.0.0.0:8080:8080` unless fronted by a TLS reverse proxy with authentication.

### 3.2 What the Logs Print (One-Time Credential Generation)

On the very first launch, Engram detects an empty `/data/secrets/` directory and automatically generates two cryptographically secure secrets:
1. SurrealDB Root Password (`/data/secrets/surreal_root`, mode 0600).
2. Engram Bearer API Key (`/data/secrets/api_key`, mode 0600).

The container logs print the API key **exactly once** during initialization:

```json
{"ts":"2026-10-24T13:45:14.210Z","level":"INFO","target":"engram::supervisor","message":"Spawning managed SurrealDB child process on 127.0.0.1:8000"}
{"ts":"2026-10-24T13:45:14.883Z","level":"INFO","target":"engram::supervisor","message":"Managed SurrealDB child is ready (probed in 673ms)"}
{"ts":"2026-10-24T13:45:14.890Z","level":"INFO","target":"engram::store::migrations","message":"Applied 1 schema migrations for default bank 'default'"}
{"ts":"2026-10-24T13:45:14.891Z","level":"WARN","target":"engram::auth","message":"================================================================================"}
{"ts":"2026-10-24T13:45:14.891Z","level":"WARN","target":"engram::auth","message":"ENGRAM FIRST-RUN INITIALIZATION: Generated new API Key."}
{"ts":"2026-10-24T13:45:14.891Z","level":"WARN","target":"engram::auth","message":"API Key: engram_sk_9f81a7b64c20d18e5473a2bc0e8912ef"}
{"ts":"2026-10-24T13:45:14.891Z","level":"WARN","target":"engram::auth","message":"Saved to: /data/secrets/api_key (mode 0600)"}
{"ts":"2026-10-24T13:45:14.891Z","level":"WARN","target":"engram::auth","message":"To display this key later, run: docker exec engram engram key show"}
{"ts":"2026-10-24T13:45:14.891Z","level":"WARN","target":"engram::auth","message":"================================================================================"}
{"ts":"2026-10-24T13:45:14.895Z","level":"INFO","target":"engram::api","message":"Engram listening on http://0.0.0.0:8080 (REST + MCP Streamable HTTP)"}
```

Subsequent container restarts will detect the persisted key and log `INFO: Loaded existing API key from /data/secrets/api_key` without printing the secret value.

### 3.3 Retrieving the API Key Later

To retrieve the active API key at any time:

```bash
docker exec engram engram key show
```
Output:
```
engram_sk_9f81a7b64c20d18e5473a2bc0e8912ef
```

### 3.4 Pointing Hermes Agent at Engram

To configure Hermes Agent (`hermes-agent`) to use the running Engram instance:

1. Enable the Engram memory provider and set the base URL using Hermes CLI:
   ```bash
   hermes config set memory.provider engram
   hermes config set memory.engram.url http://127.0.0.1:8080
   hermes config set memory.engram.bank hermes-default
   ```

2. Add the generated API key to Hermes' environment file (`$HERMES_HOME/.env`):
   ```bash
   echo "ENGRAM_API_KEY=$(docker exec engram engram key show)" >> ~/.hermes/.env
   ```

3. Restart or start Hermes. The Engram plugin (`integrations/hermes/engram/`) will connect, verify liveness via `/healthz`, and commence automatic recall prefetching and turn synchronization.

### 3.5 Connecting MCP Clients (Claude Code, Cursor, Codex, Gemini CLI)

Engram exposes Model Context Protocol (MCP) Streamable HTTP at endpoint `http://127.0.0.1:8080/mcp`.

#### Claude Code (`~/.claude.json` or project `.claude/mcp.json`)
```json
{
  "mcpServers": {
    "engram": {
      "url": "http://127.0.0.1:8080/mcp",
      "headers": {
        "Authorization": "Bearer engram_sk_9f81a7b64c20d18e5473a2bc0e8912ef",
        "X-Engram-Bank": "default"
      }
    }
  }
}
```

#### Cursor (`.cursor/mcp.json` or `~/.cursor/mcp.json`)
```json
{
  "mcpServers": {
    "engram": {
      "url": "http://127.0.0.1:8080/mcp",
      "headers": {
        "Authorization": "Bearer engram_sk_9f81a7b64c20d18e5473a2bc0e8912ef",
        "X-Engram-Bank": "default"
      }
    }
  }
}
```

#### OpenAI Codex CLI (`~/.codex/config.toml`)
```toml
[mcp_servers.engram]
url = "http://127.0.0.1:8080/mcp"
http_headers = { "Authorization" = "Bearer engram_sk_9f81a7b64c20d18e5473a2bc0e8912ef", "X-Engram-Bank" = "default" }
```

#### Gemini CLI (`~/.gemini/settings.json`)
```json
{
  "mcpServers": {
    "engram": {
      "httpUrl": "http://127.0.0.1:8080/mcp",
      "headers": {
        "Authorization": "Bearer engram_sk_9f81a7b64c20d18e5473a2bc0e8912ef",
        "X-Engram-Bank": "default"
      },
      "timeout": 10000
    }
  }
}
```

### 3.6 Model Provider Networking (Ollama, OpenRouter, OpenAI)

Engram requires external embedding generation (`qwen3-embedding:0.6b`, 1024-d) and LLM extraction (`qwen3:8b`).

```mermaid
flowchart LR
    Engram["Engram Container"]
    HostGW["host.docker.internal:host-gateway"]
    OllamaHost["Host Ollama Daemon (Port 11434)"]
    OpenRouter["OpenRouter / OpenAI (Public Internet)"]
    
    Engram -->|"Linux/macOS loopback bridge"| HostGW
    HostGW -->|"OLLAMA_HOST=0.0.0.0:11434"| OllamaHost
    Engram -->|"HTTPS Egress"| OpenRouter
```

#### Linux Ollama Setup
On Linux, containers cannot resolve `host.docker.internal` by default without `--add-host=host.docker.internal:host-gateway`. Additionally, Ollama must listen on all interfaces or the Docker bridge:
1. Configure systemd for Ollama:
   ```bash
   sudo systemctl edit ollama.service
   ```
2. Add:
   ```ini
   [Service]
   Environment="OLLAMA_HOST=0.0.0.0:11434"
   ```
3. Restart Ollama:
   ```bash
   sudo systemctl daemon-reload && sudo systemctl restart ollama
   ```
4. Pull required models:
   ```bash
   ollama pull qwen3-embedding:0.6b
   ollama pull qwen3:8b
   ```

#### macOS and Windows Ollama Setup
Docker Desktop on macOS and Windows routes `host.docker.internal` automatically. Ensure Ollama is running in the system tray and listening on port 11434.

#### Using OpenRouter or OpenAI Endpoints Instead
To use hosted cloud models (e.g. OpenAI `text-embedding-3-small` or OpenRouter `anthropic/claude-3.5-haiku`), pass credentials and base URLs via environment variables:

```bash
docker run -d \
  --name engram \
  -p 127.0.0.1:8080:8080 \
  -v engram-data:/data \
  -e ENGRAM_EMBEDDING_PROVIDER=openai \
  -e ENGRAM_EMBEDDING_BASE_URL=https://api.openai.com/v1 \
  -e ENGRAM_EMBEDDING_MODEL=text-embedding-3-small \
  -e ENGRAM_EMBEDDING_DIMENSIONS=1536 \
  -e ENGRAM_EMBEDDING_API_KEY=sk-proj-... \
  -e ENGRAM_LLM_PROVIDER=openai \
  -e ENGRAM_LLM_BASE_URL=https://openrouter.ai/api/v1 \
  -e ENGRAM_LLM_MODEL=anthropic/claude-3.5-haiku \
  -e ENGRAM_LLM_API_KEY=sk-or-v1-... \
  ghcr.io/irahardianto/engram:0.1.0
```

> [!WARNING]
> The embedding dimension (`dimensions`) is fixed when a bank is created. If you use OpenAI `text-embedding-3-small` (1536 dimensions), set `ENGRAM_EMBEDDING_DIMENSIONS=1536` before ingesting any data. Changing dimensions on an existing bank requires re-indexing (`engram reembed`).

---

## 4. Full Configuration Reference Table

Engram configures all subsystems through a unified configuration model (`config.rs`). Configuration values follow strict precedence:
$$\text{Compiled Defaults} \;\;<\;\; \text{TOML Configuration File} \;\;<\;\; \text{Environment Variables}$$

File locations inspected in order:
1. Path specified by `$ENGRAM_CONFIG`.
2. `/etc/engram/engram.toml`.
3. `./engram.toml`.

Every key from `00-decisions.md` §3.5 is documented below:

| TOML Key | Environment Variable | Type | Default | Description | Restart Req? |
|---|---|---|---|---|---|
| `server.bind` | `ENGRAM_SERVER_BIND` (or `ENGRAM_BIND`) | `String` | `0.0.0.0:8080` (img), `127.0.0.1:8080` (bare) | IP and port for the HTTP/MCP server | Yes |
| `server.api_key` | `ENGRAM_SERVER_API_KEY` (or `ENGRAM_API_KEY`) | `String` | *(Generated on first boot)* | Static Bearer authentication token | No |
| `server.default_bank` | `ENGRAM_SERVER_DEFAULT_BANK` | `String` | `default` | Fallback bank ID when header is omitted | No |
| `server.timezone` | `ENGRAM_SERVER_TIMEZONE` | `String` | `UTC` | Default IANA timezone (e.g. `Asia/Jakarta`) | No |
| `surreal.mode` | `ENGRAM_SURREAL_MODE` | `Enum` | `managed` | `managed` (supervises child) or `external` | Yes |
| `surreal.url` | `ENGRAM_SURREAL_URL` | `String` | `http://127.0.0.1:8000` | HTTP RPC endpoint for SurrealDB | Yes |
| `surreal.user` | `ENGRAM_SURREAL_USER` | `String` | *(Generated root)* | SurrealDB root username | Yes |
| `surreal.pass` | `ENGRAM_SURREAL_PASS` | `String` | *(Generated secret)* | SurrealDB root password | Yes |
| `surreal.engine` | `ENGRAM_SURREAL_ENGINE` | `Enum` | `rocksdb` | Engine backend: `rocksdb` or `surrealkv` | Yes |
| `surreal.binary` | `ENGRAM_SURREAL_BINARY` | `Path` | `/usr/local/bin/surreal` | Filesystem path to the SurrealDB binary | Yes |
| `data_dir` | `ENGRAM_DATA_DIR` | `Path` | `/data` | Base directory for data, secrets, backups | Yes |
| `embedding.provider` | `ENGRAM_EMBEDDING_PROVIDER` | `Enum` | `ollama` | Provider: `ollama` or `openai` | No |
| `embedding.base_url` | `ENGRAM_EMBEDDING_BASE_URL` | `String` | `http://host.docker.internal:11434` | Base HTTP endpoint for embeddings | No |
| `embedding.model` | `ENGRAM_EMBEDDING_MODEL` | `String` | `qwen3-embedding:0.6b` | Model identifier | No |
| `embedding.dimensions` | `ENGRAM_EMBEDDING_DIMENSIONS` | `u32` | `1024` | Vector dimensions for HNSW indexes | Yes |
| `embedding.api_key` | `ENGRAM_EMBEDDING_API_KEY` | `String` | `""` | Optional bearer token for embedding API | No |
| `llm.provider` | `ENGRAM_LLM_PROVIDER` | `Enum` | `ollama` | Provider: `ollama` or `openai` | No |
| `llm.base_url` | `ENGRAM_LLM_BASE_URL` | `String` | `http://host.docker.internal:11434` | Base HTTP endpoint for chat completions | No |
| `llm.model` | `ENGRAM_LLM_MODEL` | `String` | `qwen3:8b` | Model identifier for extraction | No |
| `llm.api_key` | `ENGRAM_LLM_API_KEY` | `String` | `""` | Optional bearer token for LLM provider | No |
| `extraction.enabled` | `ENGRAM_EXTRACTION_ENABLED` | `bool` | `true` | Toggle background LLM fact extraction | No |
| `extraction.batch_max_turns` | `ENGRAM_EXTRACTION_BATCH_MAX_TURNS` | `u32` | `4` | Max unextracted turns before batch flush | No |
| `extraction.batch_idle_ms` | `ENGRAM_EXTRACTION_BATCH_IDLE_MS` | `u64` | `20000` | Idle timeout (ms) before batch flush | No |
| `extraction.strict_vocabulary` | `ENGRAM_EXTRACTION_STRICT_VOCABULARY` | `bool` | `false` | Drop non-standard predicates vs `related_to` | No |
| `resolution.jaro_winkler` | `ENGRAM_RESOLUTION_JARO_WINKLER` | `f32` | `0.92` | Threshold for entity name fuzzy match | No |
| `resolution.embed_merge` | `ENGRAM_RESOLUTION_EMBED_MERGE` | `f32` | `0.90` | Cosine similarity threshold to auto-merge | No |
| `resolution.embed_review` | `ENGRAM_RESOLUTION_EMBED_REVIEW` | `f32` | `0.80` | Similarity floor to trigger manual review | No |
| `reconcile.require_approval` | `ENGRAM_RECONCILE_REQUIRE_APPROVAL` | `bool` | `false` | Stage non-user supersessions as pending | No |
| `retrieval.top_k` | `ENGRAM_RETRIEVAL_TOP_K` | `usize` | `12` | Max items returned in recall context | No |
| `retrieval.token_budget` | `ENGRAM_RETRIEVAL_TOKEN_BUDGET` | `usize` | `1200` | Hard token limit for packed recall block | No |
| `retrieval.rrf_k` | `ENGRAM_RETRIEVAL_RRF_K` | `u32` | `60` | Smoothing constant $k$ for RRF ranking | No |
| `retrieval.graph_hops` | `ENGRAM_RETRIEVAL_GRAPH_HOPS` | `u8` | `1` | Traversal depth for live graph expansion | No |
| `retrieval.mmr_lambda` | `ENGRAM_RETRIEVAL_MMR_LAMBDA` | `f32` | `0.7` | MMR relevance vs diversity tradeoff (0..1) | No |
| `retrieval.weight_vector` | `ENGRAM_RETRIEVAL_WEIGHT_VECTOR` | `f32` | `1.0` | Weight w_vector in RRF fusion | No |
| `retrieval.weight_bm25` | `ENGRAM_RETRIEVAL_WEIGHT_BM25` | `f32` | `1.0` | Weight w_bm25 in RRF fusion | No |
| `retrieval.weight_graph` | `ENGRAM_RETRIEVAL_WEIGHT_GRAPH` | `f32` | `0.8` | Weight w_graph in RRF fusion | No |
| `retrieval.weight_recency` | `ENGRAM_RETRIEVAL_WEIGHT_RECENCY` | `f32` | `0.5` | Weight w_recency in RRF fusion | No |
| `rerank.enabled` | `ENGRAM_RERANK_ENABLED` | `bool` | `false` | Enable neural cross-encoder reranking | No |
| `rerank.base_url` | `ENGRAM_RERANK_BASE_URL` | `String` | `""` | TEI / Cohere compatible rerank endpoint | No |
| `rerank.model` | `ENGRAM_RERANK_MODEL` | `String` | `""` | Reranker model identifier | No |
| `rerank.timeout_ms` | `ENGRAM_RERANK_TIMEOUT_MS` | `u64` | `100` | Hard timeout ceiling (ms) for rerank hook | No |
| `consolidation.enabled` | `ENGRAM_CONSOLIDATION_ENABLED` | `bool` | `true` | Toggle periodic observation synthesis | No |
| `consolidation.min_new_facts` | `ENGRAM_CONSOLIDATION_MIN_NEW_FACTS` | `u32` | `5` | New facts per entity triggering pass | No |
| `jobs.max_concurrent_banks` | `ENGRAM_JOBS_MAX_CONCURRENT_BANKS` | `usize` | `4` | Max banks processing outbox jobs in parallel | Yes |
| `jobs.max_attempts` | `ENGRAM_JOBS_MAX_ATTEMPTS` | `u32` | `8` | Max retries before dead-lettering a job | No |
| `redaction.enabled` | `ENGRAM_REDACTION_ENABLED` | `bool` | `true` | Mask API keys and secrets before storage | No |
| `audit.retention_days` | `ENGRAM_AUDIT_RETENTION_DAYS` | `u32` | `30` | Retention window for decision traces | No |
| `telemetry.log_format` | `ENGRAM_TELEMETRY_LOG_FORMAT` | `Enum` | `json` | Structured output: `json` or `pretty` | Yes |
| `telemetry.metrics_include_bank` | `ENGRAM_TELEMETRY_METRICS_INCLUDE_BANK` | `bool` | `false` | Include bank label in Prometheus metrics (opt-in) | Yes |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | *(Standard OTel Env Var)* | `String` | *(Unset)* | OTLP HTTP/protobuf collector endpoint | Yes |

### 4.1 Startup Fail-Fast Validations & Middleware Protections

Engram executes validation checks during boot and exits immediately with descriptive errors if violated:
1. **Unsafe Auth Gate:** If `ENGRAM_AUTH=disabled` is set while `server.bind` is bound to any non-loopback IP (e.g. `0.0.0.0`), Engram refuses to start:
   `FATAL: Disabling authentication is only permitted when server.bind is restricted to loopback (127.0.0.1)`.
2. **Dimension Guard:** If an existing bank record in `meta:bank` declares `dimensions = 1024`, but Engram is booted with `ENGRAM_EMBEDDING_DIMENSIONS=1536`, queries against that bank are rejected with:
   `Configuration error: Bank declared dimension 1024 does not match server embedding dimension 1536. Run engram reembed --bank <name> to migrate.`
3. **External Mode Credentials Check:** If `ENGRAM_SURREAL_MODE=external`, both `ENGRAM_SURREAL_USER` and `ENGRAM_SURREAL_PASS` must be non-empty.
4. **Public Probe Separation (ADR-01):** Bearer authentication is enforced strictly on `/v1/*` and `/mcp`. Endpoints `/healthz`, `/readyz`, and `/metrics` are unauthenticated (exposing zero memory contents) so external orchestrators and Prometheus never require API credentials.
5. **Payload & Concurrency Limits:** Axum body size is set via `.layer(DefaultBodyLimit::max(10 * 1024 * 1024))` (10 MB), supporting 100-episode batch ingestion while preventing memory ballooning. Global HTTP concurrency is guarded by `tower::limit::ConcurrencyLimitLayer::new(128)`.

---

## 5. Data Layout, Permissions & Secrets

### 5.1 Filesystem Structure (`/data`)

```
/data/
├── surreal/                  # Managed RocksDB storage files (mode 0700)
│   ├── CURRENT
│   ├── IDENTITY
│   ├── LOCK
│   ├── MANIFEST-000001
│   ├── OPTIONS-000005
│   └── *.sst                 # SSTable files containing indexed memory
├── secrets/                  # Cryptographic keys and passwords (mode 0700)
│   ├── api_key               # Static Bearer token for clients (mode 0600)
│   └── surreal_root          # Root password for managed child DB (mode 0600)
└── backups/                  # Logical SurQL export dump files (mode 0755)
    ├── engram_export_default_20261024_120000.surql
    └── ...
```

### 5.2 Host Bind Mount Permissions (UID 10001 Trap)

Because Engram runs as unprivileged user `10001:10001`, mounting a host directory requires correct filesystem ownership. If you use a host bind mount (`-v /opt/engram/data:/data`), execute the following on the host prior to launching:

```bash
sudo mkdir -p /opt/engram/data
sudo chown -R 10001:10001 /opt/engram/data
sudo chmod 700 /opt/engram/data
```

Failure to set UID 10001 ownership results in an immediate startup crash when RocksDB attempts to create its database lock:
`IO error: /data/surreal/LOCK: Permission denied (os error 13)`.

> [!TIP]
> Docker named volumes (e.g. `-v engram-data:/data`) automatically inherit the container directory permissions set in the Dockerfile (`chown -R engram:engram /data`), eliminating manual host permission setup.

---

## 6. Backup & Restore Runbook

Per ADR-04, raw RocksDB or SurrealKV storage directories are **not portable** across operating systems or SurrealDB versions. **Logical SurrealQL exports (`.surql`) are the authoritative backup and restore format for Engram.**

### 6.1 Backing Up a Memory Bank

Engram provides a native CLI subcommand `engram export` that queries the underlying SurrealDB instance and generates a clean, self-contained SurrealQL stream:

```bash
# Export the default bank
docker exec engram engram export --bank default > backup_default_$(date +%Y%m%d_%H%M%S).surql

# Export a Hermes agent bank
docker exec engram engram export --bank hermes-default > backup_hermes_$(date +%Y%m%d_%H%M%S).surql
```

To schedule daily automated backups via host crontab:
```cron
# /etc/cron.d/engram-backup
0 2 * * * root docker exec engram engram export --bank default | gzip > /var/backups/engram/default_$(date +\%F).surql.gz
```

### 6.2 Restoring into a Fresh Container

To restore an exported bank into a fresh container or disaster recovery node:

1. Launch a clean Engram instance with a fresh volume:
   ```bash
   docker run -d --name engram-recovery -p 127.0.0.1:8080:8080 -v engram-recovery-data:/data ghcr.io/irahardianto/engram:0.1.0
   ```
2. Wait for container readiness:
   ```bash
   docker exec engram-recovery engram healthcheck
   ```
3. Stream the backup into the restore command:
   ```bash
   cat backup_default_20261024.surql | docker exec -i engram-recovery engram import --bank default
   ```

### 6.3 Automated Backup Verification & Health Auditing

Never rely on unverified backup archives. Engram supports automated verification of logical export integrity:

1. **Header & Syntax Integrity Check:**
   Verify that the `.surql` export contains the complete transactional header and schema definition:
   ```bash
   head -n 25 backup_default_20261024.surql | grep "DEFINE TABLE"
   ```
2. **Cryptographic Checksumming:**
   Always generate a SHA-256 hash alongside compressed backups:
   ```bash
   sha256sum backup_default_20261024.surql.gz > backup_default_20261024.surql.gz.sha256
   sha256sum -c backup_default_20261024.surql.gz.sha256
   ```
3. **Automated Ephemeral Restore Drill:**
   Execute a scheduled headless restore test in CI or cron using a throwaway container:
   ```bash
   # Spin up temporary test instance with ephemeral memory volume
   docker run -d --rm --name engram-test -e ENGRAM_BIND=127.0.0.1:8080 -e ENGRAM_AUTH=disabled ghcr.io/irahardianto/engram:0.1.0
   sleep 3
   # Stream backup into test container
   cat backup_default_20261024.surql | docker exec -i engram-test engram import --bank default
   # Assert operational readiness
   docker exec engram-test engram doctor --bank default
   # Cleanup
   docker stop engram-test
   ```

4. **Diagnostic Doctor Output:**
   The `engram doctor` command asserts record counts, HNSW vector index integrity, and full-text analyzers:
   ```
   [✓] Database connectivity OK (SurrealDB 3.3.4, ping 0.42ms)
   [✓] Bank schema verified: meta:bank present, embedding dim = 1024
   [✓] Entities count: 1,428 records
   [✓] Episodes count: 8,912 records
   [✓] Bi-temporal Facts: 3,114 live, 421 superseded, 18 contested
   [✓] HNSW vector index 'entity_vec' verified (dimension: 1024, type: F32)
   [✓] BM25 Fulltext analyzer 'engram_analyzer' verified
   [✓] Test recall query executed: 12 results returned in 14.2ms
   Diagnostic PASSED: Bank 'default' is fully operational.
   ```

---

## 7. Upgrade Runbook & Migrations

### 7.1 Minor Engram Upgrades (Application Layer)

Engram uses forward-only, idempotent schema migrations tracked in the `schema_migration` table inside each bank database.
1. Pull the new image version:
   ```bash
   docker pull ghcr.io/irahardianto/engram:0.2.0
   ```
2. Stop and replace the container (keeping the existing volume):
   ```bash
   docker stop engram
   docker rm engram
   docker run -d \
     --name engram \
     -p 127.0.0.1:8080:8080 \
     -v engram-data:/data \
     --add-host=host.docker.internal:host-gateway \
     ghcr.io/irahardianto/engram:0.2.0
   ```
3. During startup, Engram inspects `schema_migration` and automatically applies any pending `.surql` migrations before opening port 8080.

### 7.2 Manual & Offline Migrations (`engram migrate`)

While `engram serve` applies schema migrations automatically on boot, migrations can also be applied manually or offline without starting HTTP or MCP services:

```bash
# Apply pending migrations to the default bank (server.default_bank)
docker exec engram engram migrate

# Apply pending migrations to a specific bank
docker exec engram engram migrate --bank custom_bank

# Apply pending migrations across all existing bank databases
docker exec engram engram migrate --all
```

**Subcommand Specification:**
- `engram migrate [--bank <bank> | --all]`
- `--bank <bank>`: Applies pending schema migrations to the specified bank (default: `server.default_bank`).
- `--all`: Iterates through all existing bank databases and applies pending migrations sequentially.

### 7.3 SurrealDB Major Version Bumps (Engine Layer)

When upgrading to a new SurrealDB major version where on-disk RocksDB or storage layouts may change:
1. **Export all banks** to disk:
   ```bash
   docker exec engram engram export --bank default > /tmp/export_default.surql
   docker exec engram engram export --bank hermes-profile > /tmp/export_hermes.surql
   ```
2. Stop and archive the current container and volume:
   ```bash
   docker stop engram
   docker rename engram engram-v1-archive
   ```
3. Launch the new Engram image with a fresh volume:
   ```bash
   docker run -d --name engram -p 127.0.0.1:8080:8080 -v engram-data-v2:/data ghcr.io/irahardianto/engram:v2.0.0
   ```
4. Re-import all banks:
   ```bash
   cat /tmp/export_default.surql | docker exec -i engram engram import --bank default
   cat /tmp/export_hermes.surql | docker exec -i engram engram import --bank hermes-profile
   ```
5. Confirm operational status with `engram doctor`.

### 7.4 Rollback Procedure

If an upgrade encounters unexpected behavioral regressions:
1. Stop the failing container: `docker stop engram && docker rm engram`.
2. Launch the previous pinned image tag pointing back to the archived volume:
   ```bash
   docker run -d --name engram -p 127.0.0.1:8080:8080 -v engram-data:/data ghcr.io/irahardianto/engram:0.1.0
   ```
3. If schema migrations corrupted the datastore, restore the pre-upgrade logical `.surql` export into a fresh volume.

---

## 8. Resource Sizing & Docker Constraints

### 8.1 Sizing Reference Table

Memory consumption in Engram is driven primarily by the **HNSW vector index** (which must be kept in RAM for low-latency traversal) and **RocksDB block cache**.

| Corpus Size | Total Episodes | Live Facts | Graph Entities | Estimated RAM | Minimum CPU | Disk Storage | Recommended Docker Flags |
|---|---|---|---|---|---|---|---|
| **Small (Personal Agent)** | 10k turns | 2.5k facts | 1.0k | 512 MiB | 1 Core | ~50 MiB | `--memory=1g --cpus=1.0` |
| **Medium (Standard Team)** | 100k turns | 25k facts | 8.0k | 1.2 GiB | 2 Cores | ~450 MiB | `--memory=2g --cpus=2.0` |
| **Large (Power User)** | 500k turns | 120k facts | 35k | 2.8 GiB | 4 Cores | ~2.2 GiB | `--memory=4g --cpus=4.0` |
| **Massive (Corpus)** | 1.0M turns | 250k facts | 80k | 5.5 GiB | 4 Cores | ~4.8 GiB | `--memory=8g --cpus=4.0` |

*Assumes 1024-dimensional embeddings (float32). Raw vector storage = $1024 \times 4\text{ bytes} \approx 4.096\text{ KB}$ per vector. HNSW graph links add ~1.8 KB per node.*

### 8.2 Production Container Constraints

```bash
docker run -d \
  --name engram \
  -p 127.0.0.1:8080:8080 \
  -v engram-data:/data \
  --memory=2g \
  --memory-reservation=1g \
  --cpus=2.0 \
  --pids-limit=256 \
  --stop-grace-period=40s \
  ghcr.io/irahardianto/engram:0.1.0
```

- `--memory=2g`: Enforces hard cgroup limit, preventing out-of-control memory usage from destabilizing the host.
- `--pids-limit=256`: Prevents fork-bombs while providing ample thread budget for Tokio and RocksDB worker threads (SurrealDB spawns ~53 background threads).
- `--stop-grace-period=40s`: Guarantees sufficient time for the ordered shutdown sequence (drain in-flight HTTP requests, commit pending outbox transactions, cleanly close RocksDB).

### 8.3 Production Service Level Objectives (SLOs)

Operational performance targets guide alerting thresholds and resource scaling:

| Metric / Objective | Target SLO | Measurement Method | Failure Action |
|---|---|---|---|
| **Ingestion Accept Latency ($p95$)** | $\le 20\text{ ms}$ | `histogram_quantile(0.95, sum(rate(engram_http_request_duration_seconds_bucket{route="/v1/banks/{bank}/episodes"}[5m])))` | Scale CPU/IO; inspect RocksDB WAL write stalls |
| **Hybrid Recall Latency ($p95$)** | $\le 150\text{ ms}$ | `histogram_quantile(0.95, sum(rate(engram_recall_duration_seconds_bucket{stage="pack"}[5m])))` | Check HNSW index RAM residency, Ollama GPU latency |
| **Hermes Plugin Prefetch Latency ($p95$)** | $\le 250\text{ ms}$ | Plugin hook wall-clock duration (hard deadline 1500 ms) | Breaker trips after 3 timeouts; falls back to queue cache |
| **Service Availability** | $\ge 99.9\%$ | Uptime of `/readyz` returning HTTP 200 ($< 43.8\text{ min/month}$ downtime) | Container supervisor auto-restarts child; trigger alert |
| **Recovery Time Objective (RTO)** | $\le 5\text{ min}$ | Restart to `/readyz` operational state | Failover to clean container instance |
| **Recovery Point Objective (RPO)** | $0\text{ s}$ (committed)<br>$\le 24\text{ h}$ (catastrophic) | SurrealDB WAL commit integrity; daily `.surql` export | Restore latest logical backup into fresh volume |

---

## 9. Security Hardening Checklist

```mermaid
flowchart TD
    subgraph HostBoundary["Host Security Perimeter"]
        FW["Loopback Binding (127.0.0.1:8080)"]
        Caddy["Optional Caddy TLS Proxy (HTTPS 443)"]
    end
    
    subgraph ContainerHardening["Container Kernel Hardening"]
        NoRoot["User: 10001 (Non-Root)"]
        CapDrop["Cap Drop: ALL"]
        NoNewPriv["no-new-privileges: true"]
        ReadOnly["Root FS Read-Only + 64MB Tmpfs"]
        SecFilter["Server-Side Regex Secret Redaction"]
    end

    Caddy --> FW
    FW --> NoRoot
    NoRoot --> CapDrop
    CapDrop --> NoNewPriv
    NoNewPriv --> ReadOnly
    ReadOnly --> SecFilter
```

Follow this 8-point hardening checklist before deploying Engram in multi-user or production networks:

- [ ] **1. Loopback Binding:** Never expose `-p 0.0.0.0:8080:8080`. Always publish to `-p 127.0.0.1:8080:8080`.
- [ ] **2. Drop All Linux Capabilities:** Add `--cap-drop=ALL` to strip unneeded kernel capabilities (`CAP_NET_RAW`, `CAP_SYS_ADMIN`, etc.).
- [ ] **3. Prevent Privilege Escalation:** Add `--security-opt=no-new-privileges:true`.
- [ ] **4. Read-Only Root Filesystem:** Run with `--read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m`. Only the `/data` volume requires write access.
- [ ] **5. TLS Termination via Reverse Proxy:** If clients connect across a network, terminate TLS with Caddy or Nginx.
- [ ] **6. Outbound Egress Rules:** Restrict outbound container traffic to Ollama (`host.docker.internal:11434`) and allowed HTTPS LLM endpoints.
- [ ] **7. Secrets Rotation:** Regularly rotate `ENGRAM_API_KEY` (see §10.5).
- [ ] **8. Licensing Notice Compliance:** Verify adherence to SurrealDB BSL 1.1 terms (see §9.2).

### 9.1 Caddy Reverse Proxy Configuration (TLS Example)

```caddyfile
# /etc/caddy/Caddyfile
engram.internal.domain {
    tls internal

    # Forward REST and MCP Streamable traffic
    reverse_proxy 127.0.0.1:8080 {
        header_up X-Forwarded-Proto https
        header_up Host {host}
    }
}
```

### 9.2 SurrealDB BSL 1.1 & Additional Use Grant Analysis

The `surreal` server binary bundled in the image is distributed by SurrealDB Limited under the **Business Source License 1.1 (BSL 1.1)** (Change Date: `2030-01-01` into Apache-2.0).

The BSL 1.1 license includes an **Additional Use Grant**:
> *"You may make use of the Licensed Work, provided that you may not use the Licensed Work as a Database Service.*  
> *'Database Service' means any product, service, platform, or commercial offering in which the Licensed Work is used to provide database functionality to third parties, other than your direct employees or contractors working on your behalf, that enables third parties to create, manage, or control schemas or tables."*

**Compliance Determination (ADR-02, ADR-03):**  
Engram is an agent memory service providing fixed semantic memory endpoints (`/recall`, `/remember`, `/episodes`). Engram does not permit third parties or agents to manage, create, or alter arbitrary database schemas or DDL tables. Therefore, running Engram with bundled SurrealDB or redistributing the container for self-hosted agent usage is **100% compliant** with the Additional Use Grant.

---

## 10. Operational Runbooks

### 10.1 Runbook: SurrealDB Child Crash Loop

**Symptom:** `/readyz` returns HTTP 503 with header `Retry-After: 2` and error envelope `{"error":{"code":"store_unavailable","message":"SurrealDB child starting","details":{"reason":"surreal_starting"}}}`. Container logs report `Supervisor restarting child process (attempt N/5)`.

**Root Cause:** The supervised SurrealDB child process crashed or died on an unhandled signal, or a stale `/data/surreal/LOCK` file is preventing restart.

**Resolution Steps:**
1. Inspect container logs for SurrealDB panic backtraces:
   ```bash
   docker logs --tail 100 engram | grep surreal
   ```
2. If RocksDB reports lock acquisition failure (`LOCK: Resource temporarily unavailable`):
   ```bash
   # Stop the container cleanly
   docker stop -t 30 engram
   # Inspect whether a zombie process is holding the volume on the host
   # Restart the container
   docker start engram
   ```
3. If crash loop persists across 5 restart attempts, Engram supervisor marks the DB state as fatal and ceases restarts to prevent disk thrashing. Execute a logical restore into a clean directory.

### 10.2 Runbook: Disk Full (`/data` Exhaustion)

**Symptom:** Ingestion requests fail with HTTP 500. Logs report `IO error: No space left on device`.

**Resolution Steps:**
1. Check disk utilization:
   ```bash
   docker exec engram df -h /data
   ```
2. Remove old logical backups from `/data/backups/`:
   ```bash
   docker exec engram find /data/backups -name "*.surql" -mtime +14 -delete
   ```
3. Reclaim space: RocksDB compacts tombstones in the background, so no Engram command exists for this in v1. If space must be reclaimed immediately, take an `engram export`, start a fresh volume, and `engram import` it (the logical round trip rewrites the data compactly).

### 10.3 Runbook: Dead Jobs Backlog Recovery

**Symptom:** Extraction jobs have exceeded `jobs.max_attempts` (8 retries) and entered `status = "dead"`. Ingested episodes remain unextracted in episodic search.

**Resolution Steps:**
1. List dead jobs:
   ```bash
   curl -H "Authorization: Bearer $(docker exec engram engram key show)" \
     http://127.0.0.1:8080/v1/banks/default/jobs?status=dead
   ```
2. Review the `last_error` field on the job records (e.g. `Ollama connection refused` or `Model context limit exceeded`).
3. Once the root cause (e.g. Ollama daemon downtime) is fixed, retry dead jobs by ID via API (ADR-17, §3.2):
   ```bash
   API_KEY=$(docker exec engram engram key show)
   DEAD_JOBS=$(curl -s -H "Authorization: Bearer $API_KEY" \
     "http://127.0.0.1:8080/v1/banks/default/jobs?status=dead" | jq -r '.items[].id')
   for JOB_ID in $DEAD_JOBS; do
     curl -s -X POST -H "Authorization: Bearer $API_KEY" \
       "http://127.0.0.1:8080/v1/banks/default/jobs/${JOB_ID}/retry"
   done
   ```

### 10.4 Runbook: Re-Embedding After Model Change (In-Place Maintenance Flow)

**Symptom:** You want to switch embedding models (e.g., from `qwen3-embedding:0.6b` to a new 1024-d model or different dimensionality).

**Background (ADR-17):** In SurrealDB, HNSW indexes are defined directly on table fields (`entity.embedding`, `fact.embedding`, etc.); SurrealDB has no "index tables" or shadow table aliasing. Re-embedding is executed as an in-place maintenance operation coordinated via `meta:bank.maintenance`.

**Resolution Steps:**
1. Update configuration with new model and dimension in `engram.toml` or environment (`ENGRAM_EMBEDDING_MODEL`, `ENGRAM_EMBEDDING_DIMENSIONS`).
2. Trigger the in-place re-embedding maintenance workflow via CLI:
   ```bash
   docker exec engram engram reembed --bank default [--model <name>] [--dim <n>]
   ```
   *Note:* `--model` and `--dim` are optional overrides that default to `embedding.model` and `embedding.dimensions` from configuration if omitted:
   ```bash
   docker exec engram engram reembed --bank default --model new-model-name --dim 1024
   ```
3. **Automated In-Place Maintenance Lifecycle (ADR-17):**
   - **Enter Maintenance:** Sets `meta:bank.maintenance = 'reembed'`. Read traffic continues uninterrupted; `POST /v1/banks/{bank}/recall` responses mark `degraded.vector = true` and transparently fall back to BM25, live graph expansion, and recency channels.
   - **Drop Obsolete Indexes:** Removes existing HNSW vector indexes:
     ```surql
     REMOVE INDEX IF EXISTS episode_vec ON episode;
     REMOVE INDEX IF EXISTS entity_vec ON entity;
     REMOVE INDEX IF EXISTS fact_vec ON fact;
     REMOVE INDEX IF EXISTS observation_vec ON observation;
     ```
   - **Batch Processing:** Outbox `reembed` jobs re-embed every row of `episode`, `entity`, `fact`, and `observation` in transactional batches of 100 via the bank writer worker. Jobs transition through `pending` $\to$ `running` $\to$ `completed` (or `failed` with exponential backoff, dead-lettering to `dead` after `jobs.max_attempts` per ADR-17).
   - **Recreate Vector Indexes:** Defines new HNSW vector indexes matching the new dimensionality (`{{EMBED_DIM}}` substituted with validated `u16`):
     ```surql
     DEFINE INDEX OVERWRITE episode_vec ON episode FIELDS embedding HNSW DIMENSION {{EMBED_DIM}} DIST COSINE TYPE F32 EFC 150 M 12;
     DEFINE INDEX OVERWRITE entity_vec ON entity FIELDS embedding HNSW DIMENSION {{EMBED_DIM}} DIST COSINE TYPE F32 EFC 150 M 12;
     DEFINE INDEX OVERWRITE fact_vec ON fact FIELDS embedding HNSW DIMENSION {{EMBED_DIM}} DIST COSINE TYPE F32 EFC 150 M 12;
     DEFINE INDEX OVERWRITE observation_vec ON observation FIELDS embedding HNSW DIMENSION {{EMBED_DIM}} DIST COSINE TYPE F32 EFC 150 M 12;
     ```
   - **Restore Full Recall:** Updates `meta:bank.embedding_model` and `meta:bank.embedding_dim`, and clears `meta:bank.maintenance = NONE`, restoring 4-channel vector retrieval.

### 10.5 Runbook: Rotating Credentials

To rotate the `ENGRAM_API_KEY` without data downtime:
1. Generate a new cryptographically random 32-character bearer key:
   ```bash
   NEW_KEY="engram_sk_$(openssl rand -hex 16)"
   ```
2. Atomically write the new key to `/data/secrets/api_key`:
   ```bash
   docker exec engram /bin/bash -c "echo -n '$NEW_KEY' > /data/secrets/api_key.tmp && mv /data/secrets/api_key.tmp /data/secrets/api_key && chmod 0600 /data/secrets/api_key"
   ```
3. Engram watches `/data/secrets/api_key` via file notification (or reload signal `SIGHUP`) and reloads the active token in memory within 500ms.
4. Update `$HERMES_HOME/.env` and external MCP client configs with `$NEW_KEY`.

### 10.6 Runbook: Leaked Secret / GDPR Right-to-be-Forgotten Purge

**Symptom:** Sensitive credentials, API keys, or personal identifiable information (PII) were ingested accidentally and must be permanently, physically deleted to comply with GDPR/right-to-be-forgotten or security incident protocol.

**Background (ADR-14):** Standard deletion via `POST /v1/banks/{bank}/forget` performs soft retirement (`status = "retracted"`, `expired_at = now()`), leaving raw text in RocksDB for audit history. The purge endpoint executes irreversible physical deletion (`DELETE`) and scrubs sensitive text from the audit log.

**Resolution Steps:**
1. Locate the record IDs containing sensitive data (e.g. `episode:01JAY...` or `fact:01JAY...`).
2. Execute the administrative purge request requiring the confirmation token `PURGE`:
   ```bash
   API_KEY=$(docker exec engram engram key show)
   curl -X POST \
     -H "Authorization: Bearer $API_KEY" \
     -H "Content-Type: application/json" \
     -d '{
       "ids": ["episode:01JAY000000000000000000001", "fact:01JAY000000000000000000002"],
       "confirm": "PURGE"
     }' \
     "http://127.0.0.1:8080/v1/banks/default/purge"
   ```
3. **Physical Purge Cascade Mechanics (ADR-14):**
   - Engram physically deletes listed records from RocksDB storage (`DELETE <id>;`).
   - Engram automatically deletes downstream facts and observations whose *only* evidence source was a purged episode.
   - **Audit Scrubbing:** The `audit` table is scrubbed of all decision rows referencing the purged record IDs. Engram appends an unredacted audit row with `action = "purge"`, actor, timestamp, and purged counts, but never stores the purged memory content:
     ```json
     {
       "action": "purge",
       "actor": "api",
       "target_type": "bank",
       "target_id": "default",
       "details": {
         "purged_ids": ["episode:01JAY...", "fact:01JAY..."],
         "purged_counts": { "episodes": 1, "facts": 2, "observations": 0 }
       },
       "reason": "administrative_physical_purge"
     }
     ```
   - This endpoint is restricted to the master `ENGRAM_API_KEY` and is never exposed to MCP or Hermes agent tools.

---

## 11. Docker Compose Topologies & Validation

Engram ships two Compose files so that the default command always starts exactly one working instance (foolproof first run):
- [`docker-compose.yml`](../../docker-compose.yml) — all-in-one Engram (managed SurrealDB inside); optional `with-ollama` profile adds a local Ollama container.
- [`docker-compose.external.yml`](../../docker-compose.external.yml) — Engram in external mode plus a separate SurrealDB container (not published to the host; password required via `ENGRAM_SURREAL_PASS`).

Both publish `127.0.0.1:8080`, so run one or the other, never both.

### 11.1 Validating Compose Configurations

Validated 2026-10-25 with Docker Compose (`config --services`):
- `docker compose -f docker-compose.yml config` → `engram`
- `docker compose -f docker-compose.yml --profile with-ollama config` → `engram`, `ollama`
- `docker compose -f docker-compose.external.yml config` without `ENGRAM_SURREAL_PASS` → fails fast: `required variable ENGRAM_SURREAL_PASS is missing a value`
- `ENGRAM_SURREAL_PASS=… docker compose -f docker-compose.external.yml config` → `surrealdb`, `engram`

### 11.2 Launching Topologies via Compose

#### Topology A: All-in-One (default)
```bash
docker compose up -d
```

#### Topology B: All-in-One + Local Ollama
```bash
docker compose --profile with-ollama up -d
# then point Engram at the container instead of the host:
#   ENGRAM_EMBEDDING_BASE_URL=http://ollama:11434 ENGRAM_LLM_BASE_URL=http://ollama:11434
```

#### Topology C: External Dedicated SurrealDB Container
```bash
ENGRAM_SURREAL_PASS='<strong password>' docker compose -f docker-compose.external.yml up -d
```

All services set `stop_grace_period: 40s` per ADR-03 to allow ordered request draining and job lease release.

---

## 12. Release & CI/CD Pipeline

Engram enforces a supply-chain security and release pipeline executed via GitHub Actions on every release tag:

```mermaid
flowchart TD
    GitTag["Git Tag (v0.1.0)"] --> Audit["1. Security Auditing (cargo-deny, cargo-audit)"]
    Audit --> Matrix["2. Multi-Arch Compilation (amd64, arm64 via Buildx)"]
    Matrix --> SBOM["3. SBOM Generation (cargo-cyclonedx)"]
    SBOM --> Sign["4. Image Signing (Cosign Keyless via Sigstore)"]
    Sign --> GHCR["5. Publication to GitHub Container Registry (ghcr.io)"]
```

### 12.1 CI Auditing & Tooling

1. **`cargo-deny` (v0.20+)**: Enforces license compliance against our allowlist (`Apache-2.0`, `MIT`, `BSD-2-Clause`, `BSD-3-Clause`, `ISC`, `Unicode-3.0`, `Unicode-DFS-2016`, `Zlib`, `MPL-2.0`, `CDLA-Permissive-2.0`). Checks for banned crates and duplicate dependencies.
2. **`cargo-audit` (v0.22+)**: Scans `Cargo.lock` against the RustSec Advisory Database on every commit.
3. **`cargo-cyclonedx`**: Generates a CycloneDX 1.5 JSON Software Bill of Materials (SBOM) attached to GitHub releases.
4. **Keyless Container Signing (`cosign`)**: Official images published to `ghcr.io/irahardianto/engram` are signed using Sigstore keyless OIDC signatures bound to the GitHub Actions workflow identity:
   ```bash
   cosign verify \
     --certificate-identity-regexp "https://github.com/irahardianto/engram" \
     --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
     ghcr.io/irahardianto/engram:0.1.0
   ```

---

## 13. Resolved Design Issues (history)

- **ADR-01 (Unauthenticated Health & Metrics):** Confirmed `/healthz`, `/readyz`, and `/metrics` are unauthenticated (exposing zero memory contents), while Bearer authentication applies strictly to `/v1/*` and `/mcp`.
- **ADR-03 (Process Group Isolation & Ordered Shutdown, FIND-06):** Supervisor isolates the `surreal` child in its own process group (`process_group(0)`) so group signals reach only `engram`. Shutdown follows the 5-phase sequence with `stop_grace_period >= 40s`.
- **ADR-14 (Access Policy & Physical Purge Runbook):** Added Runbook §10.6 for leaked secrets and GDPR right-to-be-forgotten using administrative endpoint `POST /v1/banks/{bank}/purge` with cascade deletion and audit scrubbing.
- **Docker Compose Port Collision (FIND-09, F-17):** Resolved by splitting topologies into `docker-compose.yml` (all-in-one default, optional `with-ollama` profile) and `docker-compose.external.yml`; bare `docker compose up -d` starts exactly one Engram. All services use `stop_grace_period: 40s`.
- **ADR-17 (In-Place Re-Embedding Maintenance, M-01):** Rewrote Runbook §10.4 to use `meta:bank.maintenance = 'reembed'`, dropping and recreating HNSW indexes in place with chunked outbox re-embedding jobs, eliminating invalid references to "index tables" or shadow fields.
- **Section 3.2 (No Undeclared Endpoints, F-09):** Removed fictional `POST /v1/banks/default/jobs/retry-all` from Runbook §10.3 and replaced with canonical per-ID retry loop `POST /v1/banks/{bank}/jobs/{id}/retry`.
