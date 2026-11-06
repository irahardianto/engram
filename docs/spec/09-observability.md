# Engram — Observability & Telemetry Specification (09-observability)

**Status:** Accepted (v1 baseline) · **Date:** 2026-10-24 · **Owner:** irahardianto  
**Binding Inputs:** [`00-decisions.md`](00-decisions.md) (ADR-14, ADR-15, ADR-16, §3.5, §3.7)  
**Research & Verifications:** [`06-rust-stack-deployment.md`](../research/06-rust-stack-deployment.md), [`V06-rust-stack-deployment.md`](../research/verification/V06-rust-stack-deployment.md), [`01-hindsight.md`](../research/01-hindsight.md) §8.4

---

## 1. Structured Logging

Engram uses the Rust `tracing` and `tracing-subscriber` ecosystem to emit unified, structured log events. By default in container and production deployments, logs are formatted as line-delimited JSON (`ENGRAM_TELEMETRY_LOG_FORMAT=json`). For local interactive terminal debugging, pretty human-readable formatting is supported (`ENGRAM_TELEMETRY_LOG_FORMAT=pretty`).

### 1.1 JSON Schema & Standard Event Fields

Every emitted JSON log line adheres to the following fixed schema:

```json
{
  "ts": "2026-10-24T13:45:14.210543Z",
  "level": "INFO",
  "target": "engram::ingest::extract",
  "message": "Extracted 3 candidate facts from batch",
  "span": {
    "name": "job.run",
    "kind": "extract",
    "bank": "hermes-default"
  },
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "request_id": "req_01M5Q191YPSSVZEWK396DQC8FP",
  "bank": "hermes-default"
}
```

| Field | Type | Description |
|---|---|---|
| `ts` | `String` (ISO 8601 UTC) | Microsecond-precision timestamp generated via `jiff::Timestamp::now()` |
| `level` | `String` | Event severity: `ERROR`, `WARN`, `INFO`, `DEBUG`, or `TRACE` |
| `target` | `String` | Rust module path emitting the event (e.g. `engram::store::rpc`) |
| `message` | `String` | Human-readable log narrative (strictly non-sensitive) |
| `span` | `Object` | Active parent span metadata and scoped fields |
| `trace_id` | `String` (Hex 32) | W3C distributed trace identifier |
| `span_id` | `String` (Hex 16) | Current active span identifier |
| `request_id` | `String` (ULID) | Ingest/recall correlation identifier (from `x-request-id`) |
| `bank` | `String` | Active memory bank database identifier |

### 1.2 Redaction Guarantees in Logs

Per ADR-14, memory contents must never leak into operational log sinks:
1. **Never Log Memory at `INFO`:** Ingested conversational turns (`user_text`, `assistant_text`), memory unit bodies, raw fact statements, and LLM prompt/completion payloads are **strictly prohibited** from `INFO` and `WARN` events. Only metadata (counts, durations, hashes, status codes) is emitted at `INFO`.
2. **Sanitized Masking at `DEBUG`:** When `RUST_LOG=debug` is opted into for troubleshooting, text values pass through the server-side regex redaction engine (`domain::redact`). Common secret shapes are masked prior to log output:
   - Bearer / API tokens (`Bearer [REDACTED]`, `sk-[a-zA-Z0-9]{20,}` $\to$ `[REDACTED_API_KEY]`)
   - Private keys (`-----BEGIN [A-Z ]+ PRIVATE KEY-----` $\to$ `[REDACTED_PRIVATE_KEY]`)
   - Database / basic auth passwords in URLs (`http://user:pass@...` $\to$ `http://user:***@...`)
3. **`TRACE` Disabled in Production:** The `TRACE` level is compiled out or filtered by default to prevent inadvertent memory buffer dumps.

### 1.3 `RUST_LOG` Directives

Engram configures log filtering via standard `RUST_LOG` environment directives. The default production directive is:

```bash
RUST_LOG="info,engram=info,surreal=warn"
```

Common diagnostic overrides:
- **Supervisor Debugging:** `RUST_LOG="info,engram::supervisor=debug,surreal=info"`
- **Retrieval & RRF Tuning:** `RUST_LOG="info,engram::retrieve=debug"`
- **Outbox Job Queue:** `RUST_LOG="info,engram::jobs=debug"`

---

## 2. Distributed Tracing & W3C Context Propagation

Tracing spans instrument both synchronous HTTP/MCP request processing and background transactional outbox workers.

### 2.1 Span Tree Hierarchy

Every span name and key field strictly mirrors `00-decisions.md` §3.7:

```mermaid
flowchart TD
    subgraph RecallTree["Recall Request Span Tree"]
        HR1["http.request (route=/v1/banks/{bank}/recall)"]
        R1["recall"]
        RE["recall.embed (model, dim)"]
        RC1["recall.channel (channel=vector)"]
        RC2["recall.channel (channel=bm25)"]
        RC3["recall.channel (channel=recency)"]
        RG["recall.graph (seed_count, hops)"]
        RF["recall.fuse (k=60, candidate_count)"]
        RP["recall.pack (token_budget, packed_count)"]

        HR1 --> R1
        R1 --> RE
        R1 --> RC1
        R1 --> RC2
        R1 --> RC3
        R1 --> RG
        R1 --> RF
        R1 --> RP
    end

    subgraph ExtractionTree["Ingestion & Background Extraction Span Tree"]
        HR2["http.request (route=/v1/banks/{bank}/episodes)"]
        IA["ingest.accept (count, kind)"]
        JR["job.run (kind=extract, bank, attempt)"]
        EL["extract.llm (model, batch_turns)"]
        REn["resolve.entities (eval_count, merged)"]
        RFa["reconcile.facts (created, superseded, contested)"]
        SQ["store.query (op=tx_reconcile)"]

        HR2 --> IA
        IA -.->|"transactional outbox"| JR
        JR --> EL
        JR --> REn
        JR --> RFa
        RFa --> SQ
    end
```

#### Synchronous Recall Spans
- `http.request`: Root HTTP span (fields: `method`, `route`, `status_code`, `bank`, `client_ip`).
- `recall`: Execution of hybrid recall algorithm.
- `recall.embed`: External embedding call for the user query (fields: `model`, `dimensions`, `duration_ms`).
- `recall.channel`: Channel retrieval dispatches (field: `channel` $\in$ `{"vector", "bm25", "recency"}`).
- `recall.graph`: Graph expansion from seed entities (fields: `seed_count`, `hops`, `traversed_edges`).
- `recall.fuse`: Weighted Reciprocal Rank Fusion execution (fields: `rrf_k`, `candidate_count`).
- `recall.pack`: MMR de-duplication and token-budget trimming (fields: `token_budget`, `packed_count`, `estimated_tokens`).

#### Asynchronous Ingest & Extraction Spans
- `ingest.accept`: Ingestion validation, secret redaction, and atomic outbox job creation.
- `job.run`: Outbox job processing loop (field: `kind` $\in$ `{"embed", "extract", "consolidate", "reembed"}`).
- `extract.llm`: Structured LLM extraction call (fields: `model`, `batch_turns`, `prompt_tokens`, `completion_tokens`).
- `resolve.entities`: Entity resolution step (fields: `candidates_evaluated`, `merged_count`, `new_count`).
- `reconcile.facts`: Deterministic truth maintenance pass (fields: `proposals_count`, `created`, `superseded`, `contested`).
- `consolidate.llm`: Periodic observation synthesis (fields: `entities_count`, `candidate_facts`).
- `store.query`: Internal SurrealDB HTTP RPC execution (field: `op` $\in$ `{"query", "rpc", "tx_reconcile", "export"}`).
- `surreal.supervisor`: Process lifecycle tracking for managed SurrealDB daemon.

### 2.2 W3C Context Propagation Contract

1. **Inbound HTTP Requests:** Engram's Axum middleware extracts the W3C `traceparent` header (e.g. `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`) sent by the Hermes Python plugin or external MCP clients. The parsed trace context is attached as the parent of the root `http.request` span.
2. **Outbox Trace Continuation:** When `ingest.accept` inserts a background `job` record into SurrealDB, the active `trace_id` and `span_id` are serialized into `job.trace_context`. When the outbox worker claims the job, `job.run` restores the original trace as a linked parent, preserving causality across the asynchronous boundary.
3. **Outbound Model Calls:** When Engram calls external AI APIs (Ollama, OpenAI, OpenRouter) via `reqwest`, an outbound middleware injects the active W3C `traceparent` and `tracestate` headers into HTTP request headers.
4. **Request Correlation:** If an inbound request lacks `x-request-id`, Engram generates a new ULID (`req_...`), echoes it in the `X-Request-Id` response header, and binds it to all child spans.

---

## 3. OpenTelemetry (OTLP) Export

Engram includes optional OTLP distributed trace export gated behind the `otlp` Cargo feature flag.

### 3.1 Crate Versions & Feature Lockstep

Verified on October 24, 2026, against crates.io:

```toml
[dependencies]
# Core OpenTelemetry ecosystem
opentelemetry = "0.33.1"
opentelemetry_sdk = { version = "0.33.1", features = ["trace", "rt-tokio"] }
opentelemetry-otlp = { version = "0.33.1", default-features = false, features = ["http-proto", "reqwest-client", "trace"] }
tracing-opentelemetry = "0.34.0"
```

> [!NOTE]
> `opentelemetry-otlp` is configured with `http-proto` and `reqwest-client`. This exports traces via standard HTTP/protobuf (`POST /v1/traces`) reusing Engram's existing `reqwest` HTTP client, avoiding heavy gRPC/Tonic dependencies and reducing binary weight.

### 3.2 OTel Environment Configuration

OTLP trace export is compiled into the official container image (`ghcr.io/irahardianto/engram:latest`), but remains **completely inactive** until `OTEL_EXPORTER_OTLP_ENDPOINT` is defined.

Standard OpenTelemetry environment variables honoured by Engram:

```bash
# Target collector endpoint (HTTP protobuf receiver)
OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4318"

# Service identification
OTEL_SERVICE_NAME="engram"

# Resource attributes (comma-separated key=value)
OTEL_RESOURCE_ATTRIBUTES="service.name=engram,service.version=0.1.0,deployment.environment=production"

# Sampler configuration: parentbased_always_on (default), traceidratio, or always_off
OTEL_TRACES_SAMPLER="parentbased_always_on"
OTEL_TRACES_SAMPLER_ARG="1.0"
```

---

## 4. Prometheus Metrics Catalog

Engram exports production metrics in standard Prometheus text exposition format at `GET /metrics`.

Metrics are implemented using the official, lightweight [`prometheus-client`](https://crates.io/crates/prometheus-client) crate (`v0.25.1`), avoiding heavy reflection dependencies while providing sub-microsecond atomic updates.

### 4.1 Bounded Cardinality Policy (The Bank Label Rule)

> [!IMPORTANT]
> The `bank` identifier is **deliberately excluded** from default metric labels across all high-throughput metrics.  
> **Rationale:** In autonomous multi-agent environments, Hermes profiles, project scopes, and subagents can create hundreds or thousands of unique memory banks. Exposing `bank` as a label on high-volume metrics (`engram_http_requests_total`, `engram_recall_duration_seconds`) creates unbounded cardinality, consuming gigabytes of RAM in Prometheus time-series indices.  
> Bank-specific statistics (total facts, vector counts, job queue depths) are retrieved via admin endpoint `GET /v1/banks/{bank}` or enabled globally via explicit configuration flag `ENGRAM_TELEMETRY_METRICS_INCLUDE_BANK=true`.  
> Per ADR-01, `GET /metrics` is **unauthenticated** (exposes internal operational counters only, with zero memory contents or customer secrets), permitting standard Prometheus scraping without token distribution.

### 4.2 Comprehensive Metric Catalog

The catalog defines all 14 official metrics required by `00-decisions.md` §3.7:

| Metric Name | Type | Labels & Allowed Values | Histogram Buckets (s) | Description | Example PromQL |
|---|---|---|---|---|---|
| `engram_http_requests_total` | Counter | `route` (Axum parameterized template: `/v1/banks/{bank}/recall`, `/v1/banks/{bank}/episodes`, `/healthz`, `/readyz`, `/metrics`, `/mcp`)<br>`method` (`GET`, `POST`, ...)<br>`status` (`200`, `202`, `400`, `401`, `500`) | — | Total incoming HTTP/MCP requests | `sum(rate(engram_http_requests_total{status=~"5.."}[5m]))` |
| `engram_http_request_duration_seconds` | Histogram | `route` (Axum parameterized route template) | `[0.005, 0.010, 0.025, 0.050, 0.100, 0.250, 0.500, 1.0, 2.5, 5.0]` | End-to-end HTTP request latency | `histogram_quantile(0.95, sum(rate(engram_http_request_duration_seconds_bucket[5m])) by (le, route))` |
| `engram_recall_duration_seconds` | Histogram | `stage` (`embed`, `channel_vector`, `channel_bm25`, `graph`, `fuse`, `pack`) | `[0.002, 0.005, 0.010, 0.025, 0.050, 0.100, 0.150, 0.250, 0.500]` | Internal execution latency for each recall pipeline phase | `histogram_quantile(0.95, sum(rate(engram_recall_duration_seconds_bucket[5m])) by (le, stage))` |
| `engram_recall_items` | Histogram | `type` (`episode`, `fact`, `observation`, `entity`) | `[1, 2, 4, 8, 12, 16, 24, 32]` | Count of items retrieved and packed per recall query | `avg(rate(engram_recall_items_sum[5m]) / rate(engram_recall_items_count[5m]))` |
| `engram_ingest_episodes_total` | Counter | `kind` (`turn`, `note`, `curated`, `delegation`, `document`) | — | Cumulative ingested memory episodes | `sum(rate(engram_ingest_episodes_total[5m])) by (kind)` |
| `engram_jobs_pending` | Gauge | `kind` (`embed`, `extract`, `consolidate`, `reembed`, `dead`) | — | Current depth of outbox jobs awaiting processing | `sum(engram_jobs_pending{kind="dead"})` |
| `engram_job_duration_seconds` | Histogram | `kind` (`embed`, `extract`, `consolidate`)<br>`outcome` (`success`, `error`, `retry`) | `[0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0]` | Background worker job execution duration | `histogram_quantile(0.95, sum(rate(engram_job_duration_seconds_bucket[5m])) by (le, kind))` |
| `engram_llm_requests_total` | Counter | `purpose` (`extract`, `consolidate`)<br>`outcome` (`success`, `error`, `rate_limited`) | — | Outbound LLM chat completion calls | `sum(rate(engram_llm_requests_total{outcome="error"}[5m]))` |
| `engram_llm_tokens_total` | Counter | `purpose` (`extract`, `consolidate`)<br>`direction` (`prompt`, `completion`) | — | Cumulative tokens consumed by LLM calls | `sum(rate(engram_llm_tokens_total[5m])) by (purpose, direction)` |
| `engram_embedding_requests_total` | Counter | `outcome` (`success`, `error`) | — | Outbound embedding API calls | `rate(engram_embedding_requests_total{outcome="error"}[5m])` |
| `engram_facts_total` | Counter | `event` (`created`, `superseded`, `contested`, `reinforced`, `dropped_unknown_predicate`) | — | Bi-temporal fact lifecycle transitions | `sum(rate(engram_facts_total[5m])) by (event)` |
| `engram_surreal_up` | Gauge | *(None)* | — | Health of managed SurrealDB child (1 = up, 0 = down) | `engram_surreal_up == 0` |
| `engram_surreal_restarts_total` | Counter | *(None)* | — | Total supervisor restarts of SurrealDB child process | `increase(engram_surreal_restarts_total[1h])` |
| `engram_store_query_duration_seconds` | Histogram | `op` (`query`, `rpc`, `tx_reconcile`, `export`) | `[0.001, 0.002, 0.005, 0.010, 0.025, 0.050, 0.100, 0.250]` | Internal CBOR RPC query execution time against SurrealDB (ADR-02) | `histogram_quantile(0.99, sum(rate(engram_store_query_duration_seconds_bucket[5m])) by (le, op))` |

### 4.3 Implementation Architecture (`prometheus-client`)

```rust
use prometheus_client::registry::Registry;
use prometheus_client::metrics::counter::Counter;
use prometheus_client::metrics::gauge::Gauge;
use prometheus_client::metrics::family::Family;
use prometheus_client::metrics::histogram::{Histogram, exponential_buckets};
use prometheus_client::encoding::text::encode;
use prometheus_client::encoding::EncodeLabelSet;

#[derive(Clone, Debug, Hash, PartialEq, Eq, EncodeLabelSet)]
pub struct HttpLabels {
    pub route: &'static str,
    pub method: &'static str,
    pub status: u16,
}

pub struct TelemetryMetrics {
    pub registry: Registry,
    pub http_requests: Family<HttpLabels, Counter>,
    pub surreal_up: Gauge,
}

impl TelemetryMetrics {
    pub fn new() -> Self {
        let mut registry = Registry::default();
        let http_requests = Family::<HttpLabels, Counter>::default();
        let surreal_up = Gauge::default();

        registry.register("engram_http_requests_total", "Total HTTP requests", http_requests.clone());
        registry.register("engram_surreal_up", "SurrealDB status", surreal_up.clone());

        Self { registry, http_requests, surreal_up }
    }

    pub fn render(&self) -> String {
        let mut buffer = String::new();
        encode(&mut buffer, &self.registry).unwrap();
        buffer
    }
}
```

---

## 5. Health & Readiness Endpoints Semantics

Engram implements the Kubernetes-standard liveness and readiness probe split on port 8080:

```
GET /healthz  --> Process Liveness Probe (Unauthenticated)
GET /readyz   --> Subsystem Readiness Probe (Unauthenticated)
```

Per ADR-01 and FIND-07, `/healthz` and `/readyz` (along with `/metrics`) are **completely unauthenticated** to allow container runtimes, Kubernetes kubelets, and Docker daemon healthchecks to probe status without distributing API secrets. They expose operational status only, never memory content. In Axum 0.8, Bearer auth middleware is applied strictly to `/v1/*` sub-routes and `/mcp`, leaving health probes public.

### 5.1 `/healthz` (Liveness)
- **Semantics:** Indicates whether the Tokio async reactor and Axum HTTP listener are responsive.
- **Status Codes:** Always returns HTTP 200 OK `{"status":"ok"}` as long as the process is running.
- **Failure:** Process crash or deadlock terminates the TCP socket, causing container orchestrators to restart the container.

### 5.2 `/readyz` (Readiness)
- **Semantics:** Indicates whether Engram is capable of serving memory recall and accepting ingestion turns.
- **Probe Conditions:**
  1. SurrealDB child process is running and loopback HTTP RPC (`POST /rpc`) answers within 200ms.
  2. Database schema migrations (`schema_migration` table) for active banks are complete.
  3. External embedding provider endpoint is reachable.
- **Status Codes & Response Payloads:**
  - **Healthy (HTTP 200 OK):**
    ```json
    {
      "status": "ready",
      "version": "0.1.0",
      "surreal": { "connected": true, "engine": "rocksdb", "latency_ms": 0.45 },
      "banks_loaded": 2,
      "pending_jobs": 0
    }
    ```
  - **Starting / Recovering (HTTP 503 Service Unavailable):**
    Engram returns HTTP 503 with a `Retry-After: 2` header during initial boot or when the supervisor is restarting SurrealDB:
    ```json
    {
      "status": "unavailable",
      "reason": "surreal_starting",
      "message": "Managed SurrealDB child process is starting storage engine",
      "restart_count": 1
    }
    ```

### 5.3 Native CLI Healthcheck (`engram healthcheck`)

Container health checks invoke Engram's native CLI command rather than external tools:

```bash
docker exec engram engram healthcheck
```

- **Exit 0:** When `GET http://127.0.0.1:8080/readyz` returns HTTP 200 OK within 2 seconds.
- **Exit 1:** When connection fails or returns HTTP 503. Docker marks the container as `unhealthy`, preventing upstream reverse proxies from routing traffic.

---

## 6. The Audit Table & Decision Tracing

Per ADR-15 and §3.3, every memory mutation (fact creation, functional supersession, contradiction detection, entity merge, forget, purge) is deterministically recorded in the bank's internal `audit` table.

### 6.1 Audit Record Schema (Canonical = Migration)

The schema matches `migrations/0001_init.surql:212-226` verbatim:

```surql
DEFINE TABLE OVERWRITE audit SCHEMAFULL;
DEFINE FIELD OVERWRITE at           ON audit TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE actor        ON audit TYPE string DEFAULT "engram" ASSERT $value IN ["engram", "api", "mcp", "hermes", "system"];
DEFINE FIELD OVERWRITE action       ON audit TYPE string;
DEFINE FIELD OVERWRITE target_type  ON audit TYPE string;
DEFINE FIELD OVERWRITE target_id    ON audit TYPE option<string>;
DEFINE FIELD OVERWRITE job          ON audit TYPE option<record<job>>;
DEFINE FIELD OVERWRITE details      ON audit TYPE object FLEXIBLE DEFAULT {};
DEFINE FIELD OVERWRITE trace_id     ON audit TYPE option<string>;
DEFINE FIELD OVERWRITE session_id   ON audit TYPE option<string>;
DEFINE FIELD OVERWRITE reason       ON audit TYPE option<string>;

DEFINE INDEX OVERWRITE audit_retention ON audit FIELDS at;
DEFINE INDEX OVERWRITE audit_target    ON audit FIELDS target_type, target_id;
DEFINE INDEX OVERWRITE audit_action    ON audit FIELDS action;
```

#### Field Specifications
- **`at`**: Immutable UTC timestamp when the audit entry was written.
- **`trace_id`**: Distributed W3C trace ID from the incoming `traceparent` header, correlating internal background outbox decisions back to the originating HTTP/MCP request.
- **`session_id`**: Optional client conversation session identifier.
- **`actor`**: Subsystem executing the mutation (`"engram"`, `"api"`, `"mcp"`, `"hermes"`, `"system"`).
- **`action`**: Operation type: `"extract"`, `"reconcile.supersede"`, `"reconcile.contest"`, `"reconcile.rejected_low_trust"`, `"forget"`, `"purge"`, `"consolidate"`.
- **`target_type`**: Table or record type targeted: `"fact"`, `"observation"`, `"episode"`, `"entity"`, `"bank"`, `"session"`.
- **`target_id`**: Canonical record ID string (e.g. `"fact:01JAY000000000000000000001"`).
- **`details`**: `object FLEXIBLE` holding the deterministic decision payload (proposal hash, subject, predicate, object, prior fact ID, trust levels, support counts, and reconciliation rules).
- **`reason`**: Human-readable explanation of why the action was taken.

### 6.2 Retention Window

Audit records are retained for `audit.retention_days` (default 30 days). An automated background cleanup job executes daily:
```surql
DELETE audit WHERE at < time::now() - 30d;
```

### 6.3 Debugging Recipe: "Why does Engram believe X?"

When an agent displays unexpected memory recall, query the audit log using SurrealQL:

```surql
-- Trace all historical decisions regarding Alice's employer or role
SELECT at, actor, action, target_type, target_id, details, reason, trace_id 
FROM audit 
WHERE target_id = "entity:alice" OR details.subject = "entity:alice" 
ORDER BY at DESC;
```

Example result:
```json
[
  {
    "at": "2026-10-24T12:00:00Z",
    "actor": "engram",
    "action": "reconcile.supersede",
    "target_type": "fact",
    "target_id": "fact:01JAY000000000000000000002",
    "details": {
      "subject": "entity:alice",
      "predicate": "works_at",
      "object": "entity:stripe",
      "prior_fact_id": "fact:01JAY000000000000000000001",
      "proposal_hash": "a1b2c3d4e5f6...",
      "decision": "superseded"
    },
    "reason": "functional_cardinality_superseded_by_newer_valid_from",
    "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"
  },
  {
    "at": "2026-06-01T09:00:00Z",
    "actor": "engram",
    "action": "extract",
    "target_type": "fact",
    "target_id": "fact:01JAY000000000000000000001",
    "details": {
      "subject": "entity:alice",
      "predicate": "works_at",
      "object": "entity:acme_corp",
      "decision": "created"
    },
    "reason": "initial_user_stated_claim",
    "trace_id": "1af82b2177b34da6a3ce929d0e0e9981"
  }
]
```

### 6.4 Purge Scrubbing Guarantee (ADR-14)

Under GDPR right-to-be-forgotten and leaked-secret compliance protocols, soft-forgetting (`POST /v1/banks/{bank}/forget`) is insufficient because raw text remains in historical audit trails. When administrative physical purge (`POST /v1/banks/{bank}/purge`) is invoked:
1. All existing `audit` entries referencing the purged target IDs are scrubbed to eliminate residual textual evidence from RocksDB storage.
2. A single sanitized audit entry is committed recording the administrative event without storing the purged memory content:
   ```json
   {
     "at": "2026-10-24T14:30:00Z",
     "actor": "api",
     "action": "purge",
     "target_type": "bank",
     "target_id": "default",
     "details": {
       "purged_ids": ["episode:01JAY000000000000000000001", "fact:01JAY000000000000000000002"],
       "purged_counts": { "episodes": 1, "facts": 1, "observations": 0 }
     },
     "reason": "administrative_physical_purge",
     "trace_id": "9bc12e4577b34da6a3ce929d0e0e1122"
   }
   ```

---

## 7. Suggested Alerts & Grafana Dashboard

### 7.1 Prometheus Alerting Rules

```yaml
groups:
  - name: engram_service_alerts
    rules:
      # Critical: Managed SurrealDB is down
      - alert: EngramSurrealDown
        expr: engram_surreal_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Engram cannot reach managed SurrealDB instance"
          description: "SurrealDB child process is down or unresponsive for > 1 minute on container loopback."

      # Warning: Supervisor restart thrashing
      - alert: EngramSurrealRestartLoop
        expr: increase(engram_surreal_restarts_total[10m]) > 3
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "SurrealDB supervisor in crash loop"
          description: "SurrealDB child process has restarted > 3 times in 10 minutes. Check disk space and RocksDB logs."

      # Warning: Dead-lettered jobs present in outbox
      - alert: EngramDeadJobsDetected
        expr: engram_jobs_pending{kind="dead"} > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Engram has dead background jobs"
          description: "{{ $value }} jobs have exceeded max attempts. Inspect /v1/banks/{bank}/jobs?status=dead."

      # Warning: LLM extraction failure rate high
      - alert: EngramExtractionFailureRateHigh
        expr: sum(rate(engram_llm_requests_total{outcome="error"}[5m])) / sum(rate(engram_llm_requests_total[5m])) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "LLM extraction error rate exceeds 5%"
          description: "Ollama or external LLM endpoint is failing extraction calls."

      # Warning: Recall latency degradation (p95 > 250ms target)
      - alert: EngramRecallLatencyP95Exceeded
        expr: histogram_quantile(0.95, sum(rate(engram_recall_duration_seconds_bucket[5m])) by (le)) > 0.250
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Recall p95 latency exceeds 250ms SLA"
          description: "P95 recall latency is currently {{ $value }}s."
```

### 7.2 Minimal Grafana Dashboard Panels

A minimal production dashboard for Engram consists of six panels:
1. **Traffic & Response Codes (Timeseries):** Rate of `engram_http_requests_total` stacked by `status` (2xx, 4xx, 5xx).
2. **Recall Latency Breakdown (Stacked Area):** `engram_recall_duration_seconds` quantile p95 broken down by pipeline stage (`embed`, `channel_vector`, `channel_bm25`, `graph`, `fuse`, `pack`).
3. **Outbox Queue Depth (Stat / Timeseries):** Current `engram_jobs_pending` grouped by `kind` (`embed`, `extract`, `consolidate`, `dead`).
4. **LLM Extraction Throughput & Token Rate (Timeseries):** `rate(engram_llm_tokens_total[5m])` split by `prompt` and `completion`.
5. **Fact Mutation Dynamics (Bar Chart):** Rate of `engram_facts_total` grouped by event (`created`, `superseded`, `contested`).
6. **SurrealDB Internal Health (Stat + Gauge):** `engram_surreal_up` state, `engram_surreal_restarts_total`, and `engram_store_query_duration_seconds` p99 latency.

---

## 8. End-to-End Debugging Playbook: Tracing a Hermes Turn

When an agent turn is processed, trace the entire flow across Hermes and Engram using this playbook:

```mermaid
sequenceDiagram
    autonumber
    participant H as Hermes Agent
    participant P as Engram Plugin
    participant E as Engram Service
    participant S as SurrealDB (Managed)
    participant O as Ollama (Local)

    H->>P: prefetch(query)
    P->>E: POST /v1/banks/hermes/recall (W3C traceparent)
    E->>O: Embed query (qwen3-embedding)
    E->>S: Multi-statement SurrealQL (Vector + BM25 + Graph)
    E-->>P: Return Markdown memory block
    P-->>H: Injected into prompt context

    H->>H: LLM Generates Response
    H->>P: sync_turn(user_msg, assistant_msg)
    P->>E: POST /v1/banks/hermes/episodes (W3C traceparent)
    E->>S: Atomic TX: Insert episode + insert outbox job:extract
    E-->>P: HTTP 202 Accepted

    Note over E,O: Asynchronous Background Outbox
    E->>S: Claim job:extract lease
    E->>O: Structured chat completion (qwen3:8b)
    O-->>E: Candidate entities & facts JSON
    E->>E: Resolve entities (Jaro-Winkler + Embeddings)
    E->>E: Reconcile facts (Deterministic rules)
    E->>S: Atomic TX: Upsert facts + append audit log + complete job
```

### 8.1 Step-by-Step Diagnostic Inspection

1. **Locate the Request ID / Trace ID:**  
   In Hermes terminal output or logs, copy the reported `trace_id` or `x-request-id` (e.g. `req_01M5Q191YPSSVZEWK396DQC8FP`).
2. **Filter Engram Logs by Correlation ID:**
   ```bash
   docker logs engram | grep "req_01M5Q191YPSSVZEWK396DQC8FP"
   ```
3. **Verify Outbox Ingestion:**
   Check that `ingest.accept` returned HTTP 202 and committed the episode without spooling:
   ```json
   {"ts":"...","level":"INFO","target":"engram::api","message":"Ingested episode ep_01M5Q191... (turn)","request_id":"req_01M5Q191..."}
   ```
4. **Inspect Background Extraction Execution:**
   Find the matching `job.run` log matching `trace_id`:
   ```json
   {"ts":"...","level":"INFO","target":"engram::jobs","message":"Extraction completed: 2 entities, 3 facts (1 superseded)","span":{"kind":"extract"}}
   ```
5. **Inspect the Decision Trace:**
   Verify the audit table in SurrealDB to confirm why the reconciliation engine accepted or superseded the fact:
   ```bash
   docker exec -i engram /usr/local/bin/surreal sql --endpoint http://127.0.0.1:8000 --ns engram --db hermes-default --user root --pass $(cat /data/secrets/surreal_root) << 'EOF'
   SELECT * FROM audit WHERE trace_id = "4bf92f3577b34da6a3ce929d0e0e4736";
   EOF
   ```

---

## 9. Resolved Design Issues (history)

- **ADR-01 & FIND-07 (Unauthenticated Probes):** Confirmed `/healthz`, `/readyz`, and `/metrics` are completely unauthenticated to allow Kubernetes/Docker health checks and Prometheus scraping without token distribution. Bearer authentication is strictly scoped to `/v1/*` and `/mcp`.
- **ADR-02 (CBOR RPC Wire Format):** Metric `engram_store_query_duration_seconds` explicitly documents the CBOR RPC query wire format against SurrealDB `POST /rpc`.
- **ADR-14 (Purge Scrubbing Guarantee):** Documented in §6.4 how `POST /v1/banks/{bank}/purge` permanently scrubs target records and their corresponding audit trace history, leaving only a sanitized administrative summary entry.
- **Section 3.3 & Migration Alignment (F-04, ST-10):** Aligned Section 6 to match `migrations/0001_init.surql:212-226` and `00-decisions.md` §3.3 verbatim (`at`, `actor`, `action`, `target_type`, `target_id`, `job`, `details`, `trace_id`, `session_id`, `reason`). The flexible `details` object encapsulates the proposal hash and decision breakdown, eliminating invented top-level fields.
- **Section 3.7 & Metric Cardinality (F-25):** Parameterized `route` labels on `engram_http_requests_total` and `engram_http_request_duration_seconds` to use Axum templates (`/v1/banks/{bank}/recall`), preventing cardinality explosion. Verified all 15 spans and 14 metrics match §3.7.
