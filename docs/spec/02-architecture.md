# Engram — System Architecture Specification (02-architecture)

**Status:** Accepted (v1 baseline) · **Date:** 2026-10-24 · **Owner:** irahardianto  
**Binding Inputs:** [`00-decisions.md`](00-decisions.md), [`DISCOVERY_HANDOFF.md`](../../DISCOVERY_HANDOFF.md)  
**Research & Verifications:** `docs/research/01..07-*.md`, `docs/research/verification/V01..V07-*.md`

---

## 1. System Context & Boundaries

Engram is a unified, single-engine long-term memory service for autonomous AI agents. It operates as a sovereign Rust daemon on SurrealDB, exposing an integrated HTTP/JSON interface for both lifecycle-integrated agents (Hermes) and standard Model Context Protocol (MCP) clients.

```mermaid
flowchart TD
    subgraph Clients["Agent Consumers"]
        Hermes["Hermes Agent (v0.22+)"]
        HPlugin["Engram MemoryProvider (Thin Python HTTP Client)"]
        McpClients["External MCP Clients\n(Claude Code, Cursor, Codex, Gemini CLI)"]
        Hermes -->|"calls hooks"| HPlugin
    end

    subgraph HostImage["Engram All-in-One Container / Host Environment"]
        subgraph EngramService["Engram Daemon (Rust, Port 8080)"]
            RestApi["REST Router (/v1/*)"]
            McpServer["MCP Streamable HTTP (/mcp)"]
            HealthMetrics["Health & Metrics (/readyz, /healthz, /metrics)"]
            CoreEngine["Core Memory Engine\n(Ingest, Retrieve, Consolidate, Outbox)"]
            Supervisor["SurrealDB Process Supervisor"]
            StoreRpc["Store Client (reqwest HTTP RPC)"]
            
            RestApi --> CoreEngine
            McpServer --> CoreEngine
            CoreEngine --> StoreRpc
            Supervisor -.->|"supervises & probes"| SurrealChild
        end

        subgraph SurrealChild["Managed SurrealDB (v3.3.4, Loopback 127.0.0.1:8000)"]
            Engine["Storage Engine (RocksDB)"]
            Indices["HNSW Vector + BM25 Fulltext + Graph"]
        end

        StoreRpc -->|"POST /rpc (CBOR RPC)"| SurrealChild
    end

    subgraph ExternalAI["External AI Model Providers"]
        Ollama["Ollama / Local Engine\n(qwen3-embedding:0.6b, qwen3:8b)"]
        OpenAI["OpenAI-Compatible Endpoints\n(OpenRouter, vLLM, TEI)"]
    end

    subgraph Observability["Telemetry Collectors"]
        Prom["Prometheus Server\n(pulls /metrics)"]
        Otel["OTLP Collector\n(protobuf HTTP traces)"]
    end

    HPlugin -->|"POST /v1/banks/{bank}/*\n(Bearer Auth)"| RestApi
    McpClients -->|"POST /mcp\n(Streamable HTTP, SEP-2243)"| McpServer
    CoreEngine -->|"POST /api/embed or /v1/embeddings"| ExternalAI
    CoreEngine -->|"POST /api/chat or /v1/chat/completions"| ExternalAI
    Prom -->|"GET /metrics"| HealthMetrics
    CoreEngine -.->|"OTLP HTTP Export (optional)"| Otel
```

### System Boundaries & Communication Protocols

1. **Hermes Integration Boundary:** Hermes communicates with Engram exclusively through a thin directory provider plugin located at `$HERMES_HOME/plugins/engram/`. The plugin contains zero heavyweight dependencies, utilizing Hermes's bundled `httpx` to execute synchronous REST calls against `http://127.0.0.1:8080/v1/`.
2. **MCP Client Boundary:** Third-party agents connect via the Model Context Protocol over Streamable HTTP at `http://127.0.0.1:8080/mcp`. The transport adheres to protocol revisions `2025-06-18` through `2026-07-28` (via `rmcp 3.7.0`) and supports stateless execution via SEP-2567 (`_meta` headers).
3. **Database Boundary:** Engram communicates with the local SurrealDB daemon strictly over HTTP RPC (`POST http://127.0.0.1:8000/rpc`) using **CBOR wire format** (`Content-Type: application/cbor`, `Accept: application/cbor` via `ciborium`) per ADR-02. The `surrealdb` Rust SDK crate is **not linked** into the Engram binary (ADR-02), eliminating BSL-1.1 client contagion and isolating the database communication to standard HTTP keep-alive connections.
4. **AI Model Boundary:** Embedding calculations and structured LLM fact extractions are delegated over HTTP to external Ollama native endpoints (`/api/embed`, `/api/chat`) or OpenAI-compatible endpoints (`/v1/embeddings`, `/v1/chat/completions`).

---

## 2. Container & Process View (All-in-One Image)

The canonical deployment artifact is an all-in-one container image (`ghcr.io/irahardianto/engram:<version>`).

```
PID 1: /usr/bin/tini -- /usr/local/bin/engram serve
  └── PID 7: /usr/local/bin/engram serve (Rust process, UID 10001)
        └── PID 14: /usr/local/bin/surreal start --bind 127.0.0.1:8000 ... (Child process)
```

### Process Topology & Supervision
- **PID 1 (`tini`):** Acts as the subreaper, handling OS signal routing and reaping zombie processes resulting from subprocess restarts.
- **Service Process (`engram serve`):** Runs as unprivileged user `engram` (UID 10001, GID 10001). It binds `0.0.0.0:8080` internally and spawns the `surreal` server child binary.
- **Supervised Child (`surreal start`):** Extracted from `surrealdb/surrealdb:v3.3.4` to `/usr/local/bin/surreal`. Binds strictly to `127.0.0.1:8000`. Spawned with `process_group(0)` (own process group) so terminal and runtime group signals reach only Engram, ensuring orderly shutdown coordination (ADR-03, VS4 FIND-06).

### Network Ports & Loopback Isolation
| Port | Interface | Scope | Purpose |
|---|---|---|---|
| `8080/tcp` | `0.0.0.0` | Container External (publish `-p 127.0.0.1:8080:8080`) | Engram REST API, MCP Streamable HTTP, health and Prometheus metrics. |
| `8000/tcp` | `127.0.0.1` | Container Internal Only (never published) | SurrealDB HTTP RPC endpoint. Inaccessible outside the container. |

### Data Layout (`/data`, `ENGRAM_DATA_DIR`)
```
/data/
├── surreal/                  # SurrealDB persistent storage engine files (RocksDB)
│   ├── CURRENT
│   ├── MANIFEST-*
│   └── *.sst
├── secrets/                  # Generated cryptographic credentials (mode 0700)
│   ├── api_key               # Engram bearer token (mode 0600)
│   └── surreal_root          # Generated SurrealDB root password (mode 0600)
└── backups/                  # Logical backup archives (.surql / .tar.gz)
```
Bind mounts on host must grant write permissions to container user UID 10001: `chown -R 10001:10001 /data`.

---

## 3. Component View & Module Architecture

Engram follows a layered hexagonal architecture mapped directly to the directory layout in `00-decisions.md` §3.8. Strict dependency boundaries are enforced at compile time.

```mermaid
flowchart TD
    subgraph Presentation["Presentation Layer (I/O, Networking)"]
        API["api (Axum 0.8 Routers & Handlers)"]
        MCP["mcp (rmcp 3.7 ServerHandler & Tools)"]
    end

    subgraph Application["Application Orchestration Layer"]
        INGEST["ingest (Redaction, Batching, Resolution)"]
        RETRIEVE["retrieve (Query Parsing, Fusion, MMR, Packing)"]
        CONSOLIDATE["consolidate (Observation Extraction & Summary)"]
        JOBS["jobs (Outbox Worker, Leases, Backoff)"]
    end

    subgraph Infrastructure["Infrastructure & Driver Layer"]
        STORE["store (SurrealDB RPC Client, Repositories, Migrations)"]
        AI["ai (Embedding & LLM Clients)"]
        SUPERVISOR["supervisor (Child Process Manager)"]
        TELEMETRY["telemetry (Tracing, Metrics, OTLP)"]
    end

    subgraph Core["Domain Core (Pure Logic)"]
        DOMAIN["domain (Predicates, Truth, Confidence, Invariants)"]
    end

    API --> INGEST
    API --> RETRIEVE
    API --> CONSOLIDATE
    API --> JOBS
    MCP --> RETRIEVE
    MCP --> INGEST

    INGEST --> STORE
    INGEST --> AI
    INGEST --> DOMAIN

    RETRIEVE --> STORE
    RETRIEVE --> AI
    RETRIEVE --> DOMAIN

    CONSOLIDATE --> STORE
    CONSOLIDATE --> AI
    CONSOLIDATE --> DOMAIN

    JOBS --> STORE
    JOBS --> INGEST
    JOBS --> CONSOLIDATE

    STORE --> DOMAIN
    AI --> DOMAIN

    API -.-> TELEMETRY
    STORE -.-> TELEMETRY
    SUPERVISOR -.-> TELEMETRY
```

### Module Responsibilities & Public Interfaces

#### 1. `domain`
Pure domain models and deterministic business rules. **Zero I/O, zero network, zero database dependencies.**
```rust
pub enum Predicate { IsA, WorksAt, HasRole, ReportsTo, LocatedIn, MemberOf, PartOf, Owns, Uses, WrittenIn, DependsOn, Prefers, ScheduledFor, CredentialsFor, RelatedTo(String) }
pub enum Cardinality { Functional, Multi }
pub enum TrustLevel { UserStated, UserImplied, AssistantStated, ToolOutput, Inferred }

impl TrustLevel {
    pub fn base_confidence(&self) -> f32 { ... }
    pub fn compute_confidence(&self, support_count: u32) -> f32 { ... }
}

pub struct ReconcileDecision {
    pub action: ReconcileAction,
    pub superseded_id: Option<RecordId>,
    pub contested: bool,
    pub conflicts_with: Option<RecordId>,
}

pub fn evaluate_fact_reconciliation(existing: &[Fact], proposed: &FactProposal) -> ReconcileDecision;
```

#### 2. `store`
The **only** module that constructs SurrealQL queries and communicates with SurrealDB over HTTP RPC.
```rust
#[derive(Clone)]
pub struct SurrealRpcClient {
    client: reqwest::Client,
    base_url: reqwest::Url,
    auth_header: HeaderValue,
}

impl SurrealRpcClient {
    pub async fn query<T: DeserializeOwned>(&self, bank: &str, surql: &str, vars: Value) -> Result<Vec<StatementResult<T>>, StoreError>;
    pub async fn transaction<T: DeserializeOwned>(&self, bank: &str, statements: &[(&str, Value)]) -> Result<Vec<StatementResult<T>>, StoreError>;
}

pub trait EpisodeRepository: Send + Sync {
    async fn insert_episode_and_jobs(&self, bank: &str, episode: &Episode, jobs: &[JobProposal]) -> Result<RecordId, StoreError>;
}
```

#### 3. `ai`
The **only** module that calls external LLM and embedding inference endpoints.
```rust
#[async_trait::async_trait]
pub trait EmbeddingClient: Send + Sync {
    async fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, AiError>;
    fn dimension(&self) -> usize;
}

#[async_trait::async_trait]
pub trait LlmClient: Send + Sync {
    async fn extract_structured<T: DeserializeOwned>(&self, prompt: &str, schema: Value) -> Result<T, AiError>;
}
```

#### 4. `ingest`
Coordinates turn ingestion, secret redaction, entity priming, and entity resolution.
```rust
pub struct IngestPipeline { store: Arc<dyn Store>, ai: Arc<dyn EmbeddingClient>, llm: Arc<dyn LlmClient> }
impl IngestPipeline {
    pub async fn accept_episode(&self, bank: &str, proposal: EpisodeProposal) -> Result<RecordId, IngestError>;
    pub async fn process_extraction_batch(&self, bank: &str, batch: ExtractionBatch) -> Result<ExtractionResult, IngestError>;
    pub async fn resolve_entity(&self, bank: &str, mention: &EntityMention) -> Result<ResolvedEntity, IngestError>;
}
```

#### 5. `retrieve`
Executes hybrid retrieval: query temporal extraction, parallel dense/sparse/graph scans, weighted RRF fusion, MMR diversification, and token-budget packing.
```rust
pub struct RetrievalEngine { store: Arc<dyn Store>, embed: Arc<dyn EmbeddingClient>, config: RetrievalConfig }
impl RetrievalEngine {
    pub async fn recall(&self, bank: &str, query: RecallQuery) -> Result<RecallResponse, RetrieveError>;
}
```

#### 6. `jobs`
Transactional outbox runner implementing leased background jobs with jittered exponential backoff.
```rust
pub struct OutboxWorker { store: Arc<dyn Store>, bank: String, concurrency: usize }
impl OutboxWorker {
    pub async fn poll_and_execute_lease(&self) -> Result<bool, JobError>;
}
```

#### 7. `supervisor`
Manages the `surreal` server child process lifecycle, readiness polling, credential generation, and log forwarding.
```rust
pub struct SurrealSupervisor { binary_path: PathBuf, data_dir: PathBuf, state: Arc<RwLock<SupervisorState>> }
impl SurrealSupervisor {
    pub async fn start(&self) -> Result<(), SupervisorError>;
    pub async fn shutdown(&self, timeout: Duration) -> Result<(), SupervisorError>;
    pub fn is_ready(&self) -> bool;
}
```

---

## 4. Runtime Concurrency Model, Backpressure & Timeouts

Engram runs on a multi-threaded Tokio runtime (`worker_threads = num_cpus`). It decouples low-latency synchronous request handling from background asynchronous knowledge graph processing.

```
Incoming Request (Axum Handler)
       │
       ├── Reads (Recall / Entities / Facts) ──> Directly queries SurrealDB RPC & Embedding Endpoint
       │
       └── Writes (Episodes / Remember) ──────> Transactionally writes Episode + Job to SurrealDB Outbox
                                                    │
                                                    ▼
                                            Per-Bank Outbox Worker
                                                    │
                                        ┌───────────┴───────────┐
                                        ▼                       ▼
                              Embed Jobs (Concurrent)   Writer Worker (Serialized per Bank)
                                                                │
                                                                ├── Entity Resolution
                                                                ├── Fact Reconciliation
                                                                └── Observation Updates
```

### Concurrency Rules
1. **Stateless HTTP Concurrency:** Axum handlers are completely non-blocking. Read operations (`/recall`, `/entities`, `/facts`) execute concurrently against SurrealDB HTTP RPC up to connection pool limits.
2. **Per-Bank Writer Worker:** To eliminate database write-skew, graph deadlock cycles, and HNSW write races, all mutating entity-resolution and fact-reconciliation operations are serialized **per bank** via a dedicated background task.
3. **Multi-Bank Concurrency Ceiling:** Independent banks process concurrently up to `jobs.max_concurrent_banks = 4`.
4. **Embedding Task Pool:** Embedding calculations for episodes execute concurrently across worker threads; the resulting vectors are written back transactionally.
5. **Bank Auto-Create Single-Flight Lock (ADR-17, VS5 M-02):** Concurrent requests targeting a non-existent bank synchronize on an in-process per-bank lock (`std::sync::Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>`). Only the first request executes `DEFINE DATABASE` and runs `0001_init.surql` migrations; concurrent requests await the lock and proceed once initialized, preventing duplicate migration race errors.
6. **Flush Session Concurrency Contract (ADR-17, VS5 M-05):** `POST .../sessions/{session_id}/flush` sets the session extract job `run_after = time::now()`, signals the per-bank worker, and awaits an in-process completion notification (via `tokio::sync::watch`) up to `wait_ms` (max 10 000 ms). It **never** executes extraction inline within the HTTP handler, preserving the serialized single-writer invariant per bank.
7. **Optimistic Concurrency Guard (ADR-08, VS2 FIND-07):** Every fact supersession or closure issues `UPDATE ... WHERE status = 'active'` inside the commit transaction and verifies affected row count: `IF count($updated) == 0 { THROW "OptimisticConcurrencyConflict: Fact already superseded"; };`. If a concurrent update won the race, the transaction aborts and the worker re-evaluates against latest truth.
8. **Current-Truth Predicate (ADR-08):** Active belief state is evaluated strictly as: `status = 'active' AND (valid_to IS NONE OR valid_to > time::now())`.

### Outbox Job Leasing & Durable Batching (ADR-17)
Async background operations (`embed`, `extract`, `consolidate`, `reembed`) use a transactional outbox pattern in the `job` table.
- **Durable Session Batching Timers (B-05):** Extraction batching is tracked via a single durable job per session with deterministic ID `job:['extract', <session_id>]`, upserted in the ingest transaction. The first turn creates the job with `run_after = time::now() + 20s`. Turns 2 and 3 push `run_after = time::now() + 20s`. The 4th turn (`batch_max_turns`), explicit `remember`, or `flush` sets `run_after = time::now()`. Outbox workers claim `(status IN ['pending', 'failed'] AND run_after <= time::now()) OR (status = 'running' AND lease_until < time::now())`. No in-memory timers exist; pending batches survive daemon restarts.
- **Lease Acquisition:** A worker acquires a job atomically by ID (since `UPDATE ... LIMIT` is invalid in SurrealQL):
  ```surql
  UPDATE ONLY $job_id SET status = 'running', claimed_by = $worker_id, lease_until = time::now() + 60s, attempts += 1, updated_at = time::now() 
  WHERE (status IN ['pending', 'failed'] AND run_after <= time::now()) OR (status = 'running' AND lease_until < time::now()) 
  RETURN AFTER;
  ```
- **Retry & Dead-Letter (ADR-17):** On failure, the job transitions to `status = 'failed'` with `last_error` and exponential backoff is scheduled: `run_after = time::now() + delay` where $\text{delay} = \min(300\text{s}, 1\text{s} \times 2^{\text{attempts}}) \pm \text{jitter}$ (claimable again once `run_after` elapses). After `jobs.max_attempts = 8`, the job transitions to `status = 'dead'`. `POST .../jobs/{id}/retry` resets a `dead` or `failed` job to `pending`, `attempts = 0`, and `run_after = time::now()`.
- **In-Place Re-Embedding Maintenance:** `engram reembed` sets `meta.maintenance = 'reembed'`. Recall requests detect maintenance and mark `degraded.vector = true` (falling back to BM25 and graph channels). HNSW indexes are removed, records are re-embedded in batches of 100 via `reembed` jobs, new HNSW indexes are created, `meta.embedding_model/embedding_dim` updated, and maintenance cleared.
- **Backpressure & 429/503 Contracts:**
  - When the ingest queue or active bank buffer exceeds capacity (100 unbatched episodes), Engram responds with `HTTP 429 Too Many Requests` and `Retry-After: 1`.
  - When SurrealDB is restarting or unreachable, Engram responds with `HTTP 503 Service Unavailable` and `Retry-After: 2`.

### Timeout & Cancellation Matrix
| Operation | Target p95 | Hard Timeout | Cancellation Behaviour | Client Fallback |
|---|---|---|---|---|
| `POST .../recall` | 150 ms | 2 500 ms | Aborts HTTP RPC queries and embedding task | Fall back to `queue_prefetch` cache, then empty string |
| `POST .../episodes` | 20 ms | 3 000 ms | Cancels HTTP request; outbox transaction rolls back | Spool to `$HERMES_HOME/engram/spool.jsonl` |
| `POST .../remember` | 80 ms | 5 000 ms | Cancels transaction; no orphaned entity created | Return error to client tool |
| `POST .../sessions/{session_id}/flush`| 1 500 ms | 10 000 ms | Waits for in-flight extraction batch to commit | Returns partial digest or timeout error |
| `GET /readyz` | 2 ms | 1 000 ms | Returns 503 immediately | Orchestrator marks container unready |
| Outbox `embed` job | 100 ms | 15 000 ms | Lease expires; job retried by next polling tick | Transparent background retry |
| Outbox `extract` job | 2 500 ms | 45 000 ms | Lease expires; backoff applied | Transparent background retry |

---

## 5. System Sequence Workflows

### 5.1 Hermes Turn End-to-End Execution
Hermes integrates prefetch on turn start and sync on turn finish.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Hermes as Hermes Core (Run Loop)
    participant Plugin as Hermes Plugin (engram)
    participant Engram as Engram Service (:8080)
    participant Surreal as SurrealDB (:8000)
    participant LLM as External AI (Ollama/API)

    User->>Hermes: Submits prompt
    Hermes->>Plugin: prefetch(query, session_id)
    activate Plugin
    Plugin->>Engram: POST /v1/banks/{bank}/recall (timeout 1500ms)
    activate Engram
    Engram->>LLM: Embed query (qwen3-embedding)
    LLM-->>Engram: Vector (1024-d)
    Engram->>Surreal: Multi-statement query (Vector + BM25 + Recency)
    Surreal-->>Engram: Raw candidates
    Engram->>Surreal: Seed entity graph expansion (1-hop)
    Surreal-->>Engram: Graph edges
    Engram->>Engram: RRF Fusion + MMR + Token Budget Pack
    Engram-->>Plugin: 200 OK (Recalled Context Markdown)
    deactivate Engram
    Plugin-->>Hermes: Injected memory prompt block
    deactivate Plugin

    Hermes->>LLM: Agent LLM inference with memory context
    LLM-->>Hermes: Assistant response + tool actions
    Hermes->>User: Renders assistant response

    Hermes->>Plugin: sync_turn(user_msg, assistant_msg) [on mem-sync thread]
    activate Plugin
    Plugin->>Engram: POST /v1/banks/{bank}/episodes (timeout 3000ms)
    activate Engram
    Engram->>Engram: Server-side regex secret redaction
    Engram->>Surreal: Transaction: CREATE episode + UPSERT job:['extract', session_id] (run_after = now + 20s) + CREATE job (kind="embed")
    Surreal-->>Engram: Committed
    Engram-->>Plugin: 202 Accepted
    deactivate Engram
    Plugin-->>Hermes: Success
    deactivate Plugin

    Note over Engram,Surreal: Background Asynchronous Processing
    Engram->>Surreal: Poll outbox: claim embed & extract jobs
    Engram->>LLM: Compute episode embedding
    Engram->>Surreal: UPDATE episode SET embedding = $vec
    Note over Engram: Batching buffer checks: turns >= 4 or run_after <= now
    Engram->>Surreal: Fetch candidate entity handles (E1..En)
    Engram->>LLM: POST /api/chat (JSON-schema extraction prompt)
    LLM-->>Engram: Structured entities & facts JSON
    Engram->>Engram: Deterministic entity resolution & reconciliation
    Engram->>Surreal: Transaction: RELATE facts, UPDATE superseded edges, record audit
```

### 5.2 MCP Recall Execution
External MCP clients execute memory retrieval via standard tools.

```mermaid
sequenceDiagram
    autonumber
    participant Client as MCP Client (e.g. Claude Code)
    participant Engram as Engram Service (/mcp)
    participant AI as Embedding Provider
    participant Surreal as SurrealDB (:8000)

    Client->>Engram: POST /mcp (JSON-RPC tools/call engram_recall, X-Engram-Bank)
    activate Engram
    Engram->>AI: Embed query text
    AI-->>Engram: Embedding vector
    Engram->>Surreal: POST /rpc (CBOR: Hybrid Vector + BM25 + Graph search)
    Surreal-->>Engram: Query results
    Engram->>Engram: RRF rank fusion, MMR filter, markdown format
    Engram-->>Client: JSON-RPC Result (text: "## Recalled context (Engram)...")
    deactivate Engram
```

### 5.3 Explicit `remember` with Priority Extraction
Explicit memories bypass standard turn batching buffers for immediate visibility.

```mermaid
sequenceDiagram
    autonumber
    participant Caller as Caller (Plugin / MCP)
    participant Engram as Engram Service (:8080)
    participant LLM as LLM Provider
    participant Surreal as SurrealDB (:8000)

    Caller->>Engram: POST /v1/banks/{bank}/remember {"text": "...", "trust": "user_stated"}
    activate Engram
    Engram->>Engram: Redact sensitive patterns
    Engram->>Surreal: Transaction: INSERT episode (kind="curated") + INSERT priority job
    Surreal-->>Engram: OK
    Engram->>LLM: Immediate extraction call (bypasses batch buffer)
    LLM-->>Engram: Extracted facts & entities
    Engram->>Surreal: Transaction: Resolve entities, apply supersession, update meta
    Surreal-->>Engram: Committed
    Engram-->>Caller: 201 Created {"episode_id": "...", "facts_created": 2}
    deactivate Engram
```

### 5.4 Session End & Consolidation Pass
Triggered when a session completes, synthesizing durable observations.

```mermaid
sequenceDiagram
    autonumber
    participant Hermes as Hermes Core
    participant Plugin as Engram Plugin
    participant Engram as Engram Service
    participant LLM as LLM Provider
    participant Surreal as SurrealDB (:8000)

    Hermes->>Plugin: on_session_end(messages)
    Plugin->>Engram: POST /v1/banks/{bank}/sessions/{session_id}/end
    activate Engram
    Engram->>Surreal: Flush remaining pending episode batch for session
    Engram->>Surreal: Query entities with new_facts >= 5
    Surreal-->>Engram: List of entities & live facts
    loop For each candidate entity
        Engram->>Surreal: SELECT existing observations & supporting facts
        Engram->>LLM: POST /api/chat (consolidate.v1.md prompt)
        LLM-->>Engram: Updated observation claims
        Engram->>Surreal: Transaction: UPDATE old observation (valid_to=now), INSERT new observation
        Engram->>Engram: Deterministic summary rebuild from top live facts
        Engram->>Surreal: UPDATE entity SET summary = $summary
    end
    Engram-->>Plugin: 200 OK
    deactivate Engram
```

### 5.5 Pre-Compress Transcript Flush
Hermes compactor triggers a fail-safe checkpoint before truncating history.

```mermaid
sequenceDiagram
    autonumber
    participant Hermes as Hermes Compactor
    participant Plugin as Engram Plugin
    participant Engram as Engram Service
    participant Surreal as SurrealDB (:8000)

    Hermes->>Plugin: on_pre_compress(messages)
    Plugin->>Engram: POST /v1/banks/{bank}/sessions/{session_id}/flush {"wait_ms": 5000}
    activate Engram
    Engram->>Surreal: UPDATE job:['extract', session_id] SET run_after = time::now()
    Engram->>Engram: Bank worker processes batch; handler awaits watch channel (wait_ms <= 5000ms)
    Engram->>Surreal: SELECT extracted facts for session
    Surreal-->>Engram: List of newly written facts
    Engram-->>Plugin: 200 OK {"digest": "Extracted 4 facts: ..."}
    deactivate Engram
    Plugin-->>Hermes: Returns digest string (injected into compaction summary prompt)
```

### 5.6 Managed SurrealDB Startup Lifecycle
Orchestrated startup guaranteeing database readiness before traffic ingress.

```mermaid
sequenceDiagram
    autonumber
    participant Tini as tini (PID 1)
    participant Engram as engram serve (PID 7)
    participant Supervisor as supervisor module
    participant Surreal as surreal child (PID 14)

    Tini->>Engram: Spawns process
    Engram->>Supervisor: Initialize managed mode
    Supervisor->>Supervisor: Load or generate /data/secrets/surreal_root (mode 0600)
    Supervisor->>Surreal: Spawn: surreal start --bind 127.0.0.1:8000 rocksdb:/data/surreal
    loop Readiness Polling (every 100ms, max 30s)
        Supervisor->>Surreal: GET http://127.0.0.1:8000/health
        Surreal-->>Supervisor: 200 OK (surreal-version: surrealdb/3.3.4)
    end
    Supervisor->>Surreal: POST /rpc: DEFINE NAMESPACE IF NOT EXISTS engram;
    Supervisor->>Supervisor: Mark State = Ready
    Engram->>Engram: Apply global baseline schema migrations
    Engram->>Engram: Bind HTTP listener 0.0.0.0:8080
    Note over Engram: /readyz now returns 200 OK
```

### 5.7 Ordered Graceful Shutdown
Clean process draining preventing data loss or outbox corruption (ADR-03, VS4 FIND-05, FIND-06). Because the `surreal` child is spawned with `process_group(0)`, external signals from Docker/host reach only Engram, ensuring SurrealDB is not killed prematurely while Phase 2 (HTTP drain) and Phase 3 (outbox commit) are in progress.

```mermaid
sequenceDiagram
    autonumber
    actor Host as Docker / Host
    participant Tini as tini (PID 1)
    participant Engram as engram serve (PID 7)
    participant Workers as Outbox Workers
    participant Surreal as surreal child (PID 14, isolated PGID)

    Host->>Tini: SIGTERM
    Tini->>Engram: Forwards SIGTERM to Engram only (surreal in own PGID)
    Note over Engram: 1. Stop accepting HTTP/MCP traffic (/readyz returns 503)
    Engram->>Engram: Drain in-flight HTTP requests (timeout <= 10s)
    Note over Engram: 2. Outbox workers reach transaction boundary
    Engram->>Workers: Signal cancellation token
    Workers->>Surreal: Commit active transaction or release lease
    Workers-->>Engram: Workers stopped (timeout <= 15s)
    Note over Engram: 3. Terminate database child via libc::kill(SIGTERM)
    Engram->>Surreal: libc::kill(pid, SIGTERM)
    Surreal->>Surreal: Flush RocksDB memtables, close WAL
    Surreal-->>Engram: Child exits cleanly (code 0; <= 10s or fallback SIGKILL)
    Engram-->>Tini: Process exit (0)
```

### 5.8 Child Crash & Self-Healing Restart
Automatic recovery on unexpected child failure.

```mermaid
sequenceDiagram
    autonumber
    participant Supervisor as supervisor loop
    participant Surreal as surreal child
    participant Health as Health Subsystem (/readyz)

    Surreal->>Surreal: Unexpected termination (SIGSEGV / OOM)
    Supervisor->>Supervisor: child.wait() detects exit
    Supervisor->>Health: Set ready = false (/readyz returns 503 Service Unavailable)
    Supervisor->>Supervisor: Increment engram_surreal_restarts_total
    Note over Supervisor: Backoff delay: 1s -> 2s -> 4s (max 30s) + jitter
    Supervisor->>Surreal: Re-spawn child process
    loop Poll /health
        Supervisor->>Surreal: GET http://127.0.0.1:8000/health
        Surreal-->>Supervisor: 200 OK
    end
    Supervisor->>Health: Set ready = true (/readyz returns 200 OK)
    Note over Supervisor: Normal request routing resumes
```

---

## 6. Store Layer over SurrealDB HTTP RPC (ADR-02)

Engram communicates with SurrealDB exclusively over HTTP RPC calling `POST /rpc` using the **CBOR wire format** (`Content-Type: application/cbor`, `Accept: application/cbor`) via `ciborium`. JSON is used only for Engram's external REST API.

> [!IMPORTANT]
> **Why CBOR over /rpc is mandatory (ADR-02, VS4 FIND-02):**
> Empirical testing against SurrealDB 3.3.4 confirmed that when using `application/json`, any bound string parameter shaped like `ident:ident` (e.g. `"User: Hello\nAssistant: Hi"`, `"Note: fix the build"`, `"TODO: rotate key"`) is irreversibly coerced into a SurrealDB Record ID and truncated (`"Note: fix the build"` becomes `Note:fix`). SurrealQL type casting (`<string>$x`, `type::string($x)`) cannot recover the lost text.
> 
> Under CBOR (`application/cbor`), string values round-trip verbatim without truncation. In addition, SurrealDB data types map cleanly to explicit CBOR tags:
> - **Tag 6**: `NONE` (`Tag(6, Null)`)
> - **Tag 8**: Record ID `[table, id]` (e.g. `Tag(8, ["fact", "01JAY..."])`)
> - **Tag 12**: Datetime `[seconds, nanoseconds]` (tag 0 RFC 3339 strings are also accepted on input)

### 6.1 RPC Wire Request & Response Formats

#### CBOR RPC Query Request (JSON Logical Representation)
```json
{
  "id": "engram-query",
  "method": "query",
  "params": [
    "BEGIN TRANSACTION; LET $e = (CREATE ONLY entity SET name = $name, name_key = $name_key, kind = $kind); RELATE ONLY $e.id->fact->$target SET predicate = $pred, statement = $stmt, trust = $trust; COMMIT TRANSACTION;",
    {
      "name": "Ichsan",
      "name_key": "ichsan",
      "kind": "person",
      "target": "entity:garmin",
      "pred": "uses",
      "stmt": "Ichsan uses Garmin",
      "trust": "user_stated"
    }
  ]
}
```
*Note on `$target`:* In this JSON illustration, `$target` is represented as a string `"entity:garmin"`; on the CBOR RPC wire, record ID endpoints must be typed Record IDs encoded with CBOR Tag 8 (`Tag(8, ["entity", "garmin"])`).

#### HTTP Request Headers
```http
POST /rpc HTTP/1.1
Host: 127.0.0.1:8000
Authorization: Basic cm9vdDpzZWNyZXQ=
surreal-ns: engram
surreal-db: hermes-default
Content-Type: application/cbor
Accept: application/cbor
```
*Note:* As verified against `surrealdb:v3.3.4`, SurrealDB `/rpc` supports both HTTP Basic authentication (`-u root:pass`) and Bearer token authentication after invoking the `signin` method. Basic authentication with keep-alive pooling is used for all internal loopback requests.

#### CBOR RPC Successful Response (JSON Logical Representation)
```json
{
  "id": "engram-query",
  "result": [
    { "status": "OK", "time": "0ns", "type": null, "result": null },
    { "status": "OK", "time": "412.12µs", "type": null, "result": { "id": "entity:01JAX...", "name": "Ichsan", "name_key": "ichsan", "kind": "person" } },
    { "status": "OK", "time": "320.04µs", "type": null, "result": { "id": "fact:01JAY...", "in": "entity:01JAX...", "out": "entity:garmin", "predicate": "uses", "statement": "Ichsan uses Garmin", "trust": "user_stated" } },
    { "status": "OK", "time": "15.2µs", "type": null, "result": null }
  ]
}
```

#### CBOR RPC Statement Error Response (JSON Logical Representation)
When a statement fails or aborts inside a transaction:
```json
{
  "id": "engram-query",
  "result": [
    { "status": "OK", "time": "0ns", "type": null, "result": null },
    { "status": "ERR", "time": "89.1µs", "kind": "Validation", "result": "Record already exists: entity:ichsan", "details": { "kind": "RecordExists" } },
    { "status": "ERR", "time": "0ns", "kind": "Query", "result": "The query was not executed due to a failed transaction", "details": { "kind": "NotExecuted" } }
  ]
}
```

### 6.2 Error Classification & Rust Mapping
Every statement response is mapped into a typed `StoreError`:

```rust
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("Database not found: {0}")]
    DatabaseNotFound(String),
    #[error("Record already exists: {0}")]
    AlreadyExists(String),
    #[error("Transaction rolled back: {0}")]
    TransactionAborted(String),
    #[error("SurrealDB query error [{kind}]: {message}")]
    QueryFailed { kind: String, message: String },
    #[error("RPC transport error: {0}")]
    Transport(#[from] reqwest::Error),
    #[error("CBOR decode error: {0}")]
    CborDecode(#[from] ciborium::de::Error<std::io::Error>),
    #[error("CBOR encode error: {0}")]
    CborEncode(#[from] ciborium::ser::Error<std::io::Error>),
    #[error("JSON serialization error: {0}")]
    Json(#[from] serde_json::Error),
}
```
- **Database/Namespace Auto-Provisioning:** When SurrealDB returns `status: "ERR"`, `kind: "NotFound"`, with `details.kind == "Database"`, the store client recognizes the unprovisioned bank and triggers auto-creation.
- **Rollback on Error:** Any transaction containing a `THROW` statement or schema failure automatically aborts; subsequent statements return `NotExecuted`.

### 6.3 Connection Pooling & Idempotency Rules
1. **Reqwest Connection Pool:** A single `reqwest::Client` instance is shared across the process, configured with:
   - `pool_max_idle_per_host = 32`
   - `pool_idle_timeout = Duration::from_secs(90)`
   - `tcp_nodelay = true`
   - `connect_timeout = Duration::from_millis(500)`
2. **Idempotent Retry Policy:**
   - **Safe Reads (`SELECT`):** Retried up to 2 times with 50ms backoff on transport errors (`ErrorKind::ConnectionReset`, `BrokenPipe`).
   - **Mutations (`CREATE`, `RELATE`, `UPDATE`):** **Never retried blindly.** Write operations must supply an `idempotency_key` (derived from content hash or request header). Transactions assert uniqueness via SurrealDB index constraints:
     ```surql
     IF (SELECT VALUE id FROM episode WHERE idempotency_key = $key)[0] IS NONE {
         CREATE ONLY episode CONTENT $episode;
     };
     ```
3. **Bound Variable Injection Safety (ADR-02):** All dynamic user-derived text, identifiers, and vector arrays are strictly parameterized via `$params`. String interpolation of user text into SurrealQL is prohibited by lint and code review.
4. **KNN Integer Literal Exception (ADR-02):** The only exception to bound variables is the SurrealQL KNN operator `<|k,ef|>`. In SurrealDB 3.3.4, passing bound variables to `<|k,ef|>` triggers a parse error (`Unexpected token $`). Therefore, `k` and `ef` are formatted directly into query text from validated Rust `u16` primitives, never from unvalidated strings.
5. **Single-Field FULLTEXT Index Constraint (ADR-02):** In SurrealDB 3.3.4, a `FULLTEXT` index covers exactly one field. Multiple fields require distinct indexes (e.g. `episode_fts`, `entity_name_fts`) queried with positional references (`@0@`, `@1@`).
6. **Optimistic Concurrency Guards (ADR-08, VS2 FIND-07):** Fact supersession queries execute inside transactional blocks with active row-count assertions:
   ```surql
   LET $updated = (UPDATE $old_id SET status = 'superseded', valid_to = $new_valid_from, expired_at = time::now(), superseded_by = $new_id WHERE status = 'active');
   IF count($updated) == 0 {
       THROW "OptimisticConcurrencyConflict: Fact already superseded";
   };
   ```

---

## 7. Supervisor Design for Managed Mode

The supervisor runs as an asynchronous background actor supervising the `surreal` server binary.

### 7.1 State Machine

```mermaid
stateDiagram-v2
    [*] --> Stopped
    Stopped --> Spawning: start() invoked
    Spawning --> Probing: Child process spawned
    Probing --> Ready: /health probe returns 200 OK
    Probing --> Restarting: Probe timeout (30s) / Child crash
    Ready --> Restarting: Child exit detected
    Restarting --> Spawning: Exponential backoff elapsed
    Ready --> Stopping: SIGTERM / SIGINT received
    Probing --> Stopping: SIGTERM / SIGINT received
    Stopping --> Terminated: Child SIGTERM exit
    Stopping --> Failed: SIGKILL fallback (10s elapsed)
    Terminated --> [*]
    Failed --> [*]
```

- **Child Spawn Execution & Process Group Isolation (ADR-03, VS4 FIND-06):**
  The child process is spawned with `process_group(0)` using `std::os::unix::process::CommandExt`, placing SurrealDB in its own distinct process group (`PGID`):
  ```rust
  let mut cmd = Command::new(&config.binary_path);
  cmd.args([
      "start",
      "--bind", &config.bind_addr,
      "--user", &config.user,
      "--pass", &config.pass,
      "--log", "info",
      &config.engine,
  ]);
  cmd.process_group(0); // Isolate child from parent process group signals
  cmd.stdout(Stdio::piped());
  cmd.stderr(Stdio::piped());
  cmd.kill_on_drop(true); // Safety net for immediate ungraceful crashes
  ```
  This guarantees that group-directed host signals (e.g. from container runtimes) reach only Engram, allowing SurrealDB to stay alive while in-flight HTTP requests and outbox workers finish cleanly.
- **Graceful Termination & Safety Net (ADR-03, VS4 FIND-05):**
  During Phase 4 of service shutdown, the supervisor sends `SIGTERM` via `libc::kill(child.id() as i32, libc::SIGTERM)` and waits up to 10 seconds for clean RocksDB memtable flush and WAL sync using `tokio::time::timeout(Duration::from_secs(10), child.wait())`. If the child fails to exit within 10 seconds, it falls back to `child.kill().await` (SIGKILL).
- **Readiness Probing:** The supervisor issues HTTP requests to `http://127.0.0.1:8000/health` every 100ms. Upon receiving `200 OK` containing header `surreal-version: surrealdb/3.3.4`, the supervisor checks and initializes the `engram` namespace.
- **Restart Backoff:** If the child terminates unexpectedly, the supervisor calculates backoff:
  $$\text{delay} = \min(30s, 1s \times 2^{\text{restarts}-1}) \pm \text{jitter}$$
  The restart counter resets to 0 once the child maintains a healthy status for 300 seconds.
- **Log Streaming:** Child `stdout` and `stderr` pipes are captured asynchronously using `tokio::io::BufReader`. Lines are routed directly into the service's `tracing` pipeline under target `surrealdb`.
- **Health Propagation:** The global `/readyz` endpoint queries the supervisor's atomic status. If the supervisor is not in the `Ready` state, `/readyz` immediately emits `HTTP 503 Service Unavailable`.

---

## 8. Failure-Mode & Degradation Matrix

| Component Failure | Detection Mechanism | User-Visible Behaviour | Data-Safety Guarantee | Recovery Procedure |
|---|---|---|---|---|
| **SurrealDB Crash / Restart** | Child supervisor detects process termination; `/readyz` probe fails. | In-flight turns fail with 503; Hermes plugin spools turns to local disk (`spool.jsonl`). MCP clients receive 503 with `Retry-After: 2`. | In-flight uncommitted transactions roll back cleanly (RocksDB WAL integrity). Zero orphaned records. | Supervisor restarts child with exponential backoff; migrations verify schema; plugin replays spool. |
| **Embedding Provider Down** | `EmbeddingClient` HTTP timeout (5 000 ms) or connection refused. | `recall` falls back to sparse BM25 + Graph search only. Episode ingestion accepts turn (`202 Accepted`) but marks embed job `pending`. | Raw text is safely committed to `episode`. Embed jobs remain durable in outbox. | Outbox worker retries with backoff (1s..5min). Computes vectors automatically when provider returns. |
| **LLM Provider Down / Slow** | `LlmClient` HTTP timeout (30 000 ms) or HTTP 5xx. | Turn ingestion succeeds immediately. Graph fact extraction is delayed. Facts do not reflect latest turn until LLM recovers. | Episode is fully searchable via BM25 and vector k-NN immediately. Zero data loss. | Extraction jobs remain in outbox (`status = 'pending'`). Processed in arrival order once LLM recovers. |
| **LLM Schema Violation** | JSON deserialization failure on structured output. | Turn succeeds. Audit table records `extraction_parse_error`. Extracted facts dropped for that turn. | Episode remains durable. Entity graph is untouched, avoiding corrupt facts. | Job is retried up to 8 times with jitter. If persistent, job transitions to `status = 'dead'` for inspection. |
| **Host Disk Full (`/data`)** | RocksDB returns `IO error: No space left on device`. Store RPC returns HTTP 500. | All mutation endpoints return `HTTP 500 Insufficient Storage`. Hermes plugin spools turns to `$HERMES_HOME`. | Write fails closed. Existing data and indexes remain intact. | Operator expands disk or performs export/import round-trip (`engram export` -> fresh volume -> `engram import`). Service resumes without data loss. |
| **Hermes Plugin Network Partition** | Plugin `httpx.ConnectError` or timeout (>3 000 ms). | Hermes turn completes normally without blocking the user. Deterministic recall status indicator shows "offline". | Turn is appended to `$HERMES_HOME/engram/spool.jsonl` (capped at 10k lines / 20 MB). | Next successful call replays spooled turns oldest-first into `POST /episodes`. |
| **MCP Client Disconnect** | Axum detects closed TCP socket (`ClientDisconnected`). | Client connection closes. In-flight read query cancelled via Tokio `select!`. | Read queries abort immediately, freeing database resources. Mutations run to commit. | Client reconnects with standard MCP handshake. |

---

## 9. Tenancy & Bank Lifecycle

Engram enforces strict physical multi-tenancy using SurrealDB's two-tier architecture: **one namespace (`engram`) containing one database per memory bank (`[a-z0-9][a-z0-9_-]{0,62}`)**.

```
Namespace: engram
├── Database: hermes-default    (Hermes profile "default")
│   ├── meta:bank, episode, entity, fact, observation, job, audit
├── Database: hermes-work       (Hermes profile "work")
└── Database: default           (Shared MCP client bank)
```

### Bank Isolation & Index Independence
Because HNSW graphs and BM25 analyzers are scoped per database, facts from different banks never share vector graphs or full-text indexes. This prevents index bleed and avoids recall degradation caused by multi-tenant filtered scans.

### Bank Lifecycle Management

1. **Auto-Creation on First Use & Provisioning Order (ADR-05, ADR-17, VS5 M-02):**
   When a request arrives for a non-existent bank, SurrealDB returns `DatabaseNotFound`. To prevent race conditions from concurrent requests, the store layer coordinates initialization through an in-process per-bank single-flight lock (`std::sync::Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>`). The winning thread executes the strict three-stage provisioning sequence:
   - **Stage 1 (Namespace Provisioning):** `DEFINE NAMESPACE IF NOT EXISTS engram;` (dispatched with no `surreal-ns` or `surreal-db` headers).
   - **Stage 2 (Database Provisioning):** `DEFINE DATABASE IF NOT EXISTS <bank>;` (dispatched with header `surreal-ns: engram` only).
   - **Stage 3 (Schema Migrations & Metadata):** Dispatches forward-only migrations and seeds `meta:bank` (with both `surreal-ns: engram` and `surreal-db: <bank>` headers). Concurrent requests await the single-flight mutex and execute against the initialized database.
2. **Per-Bank Metadata Record (`meta:bank`):**
   ```surql
   UPSERT ONLY meta:bank SET
       schema_version = 1,
       embedding_model = "qwen3-embedding:0.6b",
       embedding_dim = 1024,
       vocabulary_version = "v1",
       timezone = "UTC";
   ```
   *Dimension Lock:* The vector dimension is immutable for the lifetime of a bank. Switching models requires running `engram reembed --bank <name>`.
3. **Per-Bank Schema Migrations:**
   Migrations are embedded into the binary (`migrations/*.surql`). Each bank maintains a `schema_migration` table tracking executed files and checksums. Migrations are executed in an isolated transaction before accepting write traffic.
4. **Deletion Policy (ADR-14, F-09):**
   - Soft retirement is preferred: `POST /v1/banks/{bank}/forget` marks entities and facts as `retracted`.
   - Permanent bank destruction is out of scope for v1 (the v1 REST API exposes no `DELETE /v1/banks` endpoint, and `engram` has no `bank drop` subcommand in v1; drop the SurrealDB database manually via SurrealDB SQL/CLI: `REMOVE DATABASE <bank>;`). No `DELETE /v1/banks` endpoint exists in REST or MCP.
5. **In-Place Re-Embedding Maintenance (ADR-17):**
   When migrating embedding models, `engram reembed --bank <name>` coordinates an in-place migration:
   - Sets `meta.maintenance = 'reembed'`. Active recall requests detect this flag, mark `degraded.vector = true` in response telemetry, and fall back transparently to BM25 and graph expansion channels.
   - Drops existing HNSW vector indexes (`REMOVE INDEX episode_vec ON episode;` etc.).
   - Re-embeds all existing records in batches of 100 via background `reembed` jobs.
   - Defines new HNSW vector indexes with the new target dimension.
   - Updates `meta.embedding_model` and `meta.embedding_dim`, then clears `meta.maintenance`. No shadow tables or schema bifurcation required.

---

## 10. Security Architecture & Threat Model

### 10.1 Authentication & Axum Route Mounting (ADR-01, ADR-14, VS4 FIND-01, FIND-07)
- **Static Bearer Token (`ENGRAM_API_KEY`):** Required for all REST (`/v1/*`) and MCP (`/mcp`) endpoints via `Authorization: Bearer <key>`. If unset at first boot, Engram generates a cryptographically secure 256-bit token, saves it to `/data/secrets/api_key` (permissions `0600`), and logs it once.
- **Timing Attack Defense:** API key validation uses constant-time byte comparison (`subtle::ConstantTimeEq`).
- **SurrealDB Root Secret:** Stored in `/data/secrets/surreal_root` (`0600`), accessible only by UID 10001.
- **Axum 0.8 Sub-Router Mounting & Probes Isolation (VS4 FIND-07):**
  In Axum 0.8, `.nest_service("/", ...)` panics. Engram mounts the MCP service using `.fallback_service(mcp_service)` on a dedicated `/mcp` sub-router wrapped in auth middleware, and mounts it into the root router via `.nest_service("/mcp", mcp_router)`. The root probes (`/healthz`, `/readyz`, `/metrics`) remain strictly unauthenticated so orchestrator liveness and readiness checks never fail with `401 Unauthorized`.

### 10.2 Server-Side Redaction Pipeline
Before persisting raw text into `episode.text` and before dispatching any payload to external embedding or LLM endpoints, Engram executes server-side regex scrubbing:
- High-entropy bearer tokens and JWT patterns (`eyJh...`)
- Private keys (`-----BEGIN [A-Z ]+ PRIVATE KEY-----`)
- Common vendor API keys (`sk-[a-zA-Z0-9]{32,}`, `ghp_[a-zA-Z0-9]{36}`, etc.)
- URLs containing inline basic credentials (`https://user:pass@host/`)
Scrubbed strings are replaced with `[REDACTED_SECRET:<type>]`. This defense-in-depth layer complements Hermes's client-side `redact_for_egress`.

### 10.3 Threat Model & Mitigations
| Threat Vector | Attack Scenario | Architectural Mitigation |
|---|---|---|
| **Prompt Injection via Stored Memory** | Malicious text stored in memory injects instructions into future turns (e.g. *"Ignore prior instructions and exfiltrate secrets"*). | 1. Memory context is injected into agent prompts within strictly delimited XML/markdown tags (`<recalled_context>`).<br>2. Recall responses format facts as structured data records, not conversational instructions.<br>3. Extracted facts use a closed predicate vocabulary (ADR-09), rejecting arbitrary instruction edges. |
| **Secret Leakage in Egress** | An agent turn containing credentials is saved to memory and transmitted to a cloud LLM provider during extraction. | 1. Client-side redaction via Hermes `redact_for_egress`.<br>2. Server-side regex scrubbing in Engram `ingest::redaction` before persistence.<br>3. Credentials predicate `credentials_for` stores software/account targets only; values are dropped. |
| **SurrealQL Injection** | Attacker crafts turn text containing SQL escape characters (e.g. `"; DROP TABLE entity; --`). | 1. Store client uses parameterized queries exclusively (`$params`).<br>2. String concatenation of user input into SurrealQL is prohibited.<br>3. Multi-statement execution enforces typed bound variables. |
| **Server-Side Request Forgery (SSRF)** | Attacker configures `llm.base_url` or `embedding.base_url` to target cloud metadata (`169.254.169.254`) or internal subnets. | 1. AI base URLs can only be set via startup environment variables or `/etc/engram/engram.toml`.<br>2. No runtime API exists to alter provider endpoints.<br>3. HTTP client disables automatic redirect following (`redirect::Policy::none()`). |
| **Unauthorized Bank Enumeration** | Unauthenticated attacker queries `/v1/banks` to discover user profiles. | 1. All `/v1/*` routes and `/mcp` require valid Bearer authentication; public probes (`/healthz`, `/readyz`, `/metrics`) are unauthenticated on root.<br>2. `ENGRAM_AUTH=disabled` is strictly rejected unless bound to loopback `127.0.0.1`. |

---

## 11. Scalability Envelope & Capacity Limits (v1)

Engram v1 is optimized for single-node deployment supporting personal agents, local development, and small team installations.

### 11.1 Target Operating Envelope
- **Concurrent Active Banks:** Tested up to 64 concurrent banks; background worker concurrency bounded by `jobs.max_concurrent_banks = 4`.
- **Facts per Bank:** Tuned for up to 100 000 active facts per bank while maintaining p95 recall under 150 ms. Supports up to 1 000 000 facts on NVMe storage with appropriate RAM sizing.
- **Ingestion Throughput:** Sustained ingest accept rate of 200 episodes/sec (synchronous commit to RocksDB outbox); background extraction rate bounded by external LLM provider throughput.

### 11.2 HNSW Vector Index Memory Calculation
SurrealDB holds active HNSW vector graph structures in RAM. The memory requirements for 1024-dimensional single-precision floating-point vectors (`F32`) are calculated as follows:

1. **Raw Vector Component:**
   $$\text{Bytes per Vector} = 1024 \times 4\text{ bytes} = 4\,096\text{ bytes (4.0 KiB)}$$
2. **Graph Structure Overhead:**
   SurrealDB HNSW indexes with default parameters ($M = 16$ bidirectional connections per node, 16-byte edge pointers, multi-layer hierarchy, record ID mappings, and memory alignment) require approximately **1.5 KiB to 2.0 KiB** of structural overhead per indexed vector.
3. **Total Resident Memory per Vector:**
   $$\text{Total RAM per Vector} \approx 4.0\text{ KiB} + 1.8\text{ KiB} = 5.8\text{ KiB}$$

#### Memory Scaling Table
| Fact / Vector Count | Raw Vector Footprint | HNSW Graph Overhead | Total Estimated RAM | Recommended Host RAM |
|---|---|---|---|---|
| **10 000** | 39.0 MiB | 17.5 MiB | **56.5 MiB** | 2 GiB |
| **100 000** | 390.6 MiB | 175.7 MiB | **566.3 MiB** | 4 GiB |
| **500 000** | 1.90 GiB | 878.9 MiB | **2.77 GiB** | 8 GiB |
| **1 000 000** | 3.81 GiB | 1.71 GiB | **5.52 GiB** | 16 GiB |

*Architectural Confirmation:* As documented in V05 (Finding FIND-03, GitHub issue #7337), DiskANN does not currently provide bounded-RAM caching in SurrealDB 3.3.4. Engram therefore explicitly configures `HNSW` over RocksDB for consistent, predictable memory usage.

---

## 12. Resolved Design Issues (history)

During empirical verification against `surrealdb/surrealdb:v3.3.4` and architectural analysis, the following items were identified and reconciled with `00-decisions.md`:

1. **SurrealDB Child Binary Path Inconsistency:**
   - `00-decisions.md` §3.5 lists default `surreal.binary = "/usr/local/bin/surreal"`, while ADR-03 notes the official image binary source `/surreal`.
   - *Status:* **Resolved in ADR-03 & §3.5.** The Dockerfile extracts `/surreal` to `/usr/local/bin/surreal` (`COPY --from=surrealdb /surreal /usr/local/bin/surreal`).
2. **Database Provisioning Order in SurrealDB 3.x:**
   - Scoped queries to a non-existent database return `NotFound`.
   - *Status:* **Resolved in ADR-05.** Standardized the three-phase provisioning sequence: `DEFINE NAMESPACE` (unscoped) $\to$ `DEFINE DATABASE` (namespace-scoped) $\to$ schema migrations (database-scoped).
3. **HTTP RPC Base URL vs RPC Path:**
   - Configuration key `surreal.url = "http://127.0.0.1:8000"` is a base URL.
   - *Status:* **Resolved in ADR-03.** The store client appends `/rpc` for CBOR queries and `/health` for readiness probing.
4. **CBOR Wire Format on SurrealDB `/rpc` (ADR-02, VS4 FIND-02):**
   - SurrealDB's JSON-RPC endpoint coerces string parameters matching `ident:ident` into record IDs and truncates the string (e.g. `"Note: fix the build"` $\to$ `Note:fix`).
   - *Status:* **Resolved in ADR-02.** Mandated CBOR (`application/cbor`) over `/rpc` via `ciborium` with native tags (tag 6 NONE, tag 8 RecordId, tag 12 Datetime). JSON is restricted to Engram's public REST API.
5. **Supervisor Signal Isolation & Graceful Termination (ADR-03, VS4 FIND-05, FIND-06):**
   - Default child processes share Engram's process group, causing container runtime signals to kill SurrealDB prematurely. Furthermore, `child.kill().await` sends an immediate SIGKILL, aborting RocksDB WAL flushes.
   - *Status:* **Resolved in ADR-03.** Spawn child with `process_group(0)`. Terminate child via `libc::kill(pid, SIGTERM)` with a 10s wait before fallback to SIGKILL.
6. **Bank Auto-Creation Concurrency & Single-Flight Lock (ADR-17, VS5 M-02):**
   - Concurrent requests for a new bank race on schema migration execution.
   - *Status:* **Resolved in ADR-17.** In-process per-bank single-flight lock (`std::sync::Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>`) serializes auto-creation and migrations.
7. **Durable Session Batching Timers (ADR-17, VS5 B-05):**
   - In-memory turn batching timers are lost if the daemon restarts.
   - *Status:* **Resolved in ADR-17.** Session batch timers are persisted into the outbox as `job:['extract', <session_id>]` with `run_after`.
8. **Flush Session Worker Notification Contract (ADR-17, VS5 M-05):**
   - Synchronous inline extraction in `/flush` violates the single-writer invariant per bank.
   - *Status:* **Resolved in ADR-17.** `/flush` sets `run_after = time::now()`, wakes the bank worker, and awaits an in-process watch channel notification.
