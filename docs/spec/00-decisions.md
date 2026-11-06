# Engram — Architecture Decision Record & Canonical Registry

**Status:** Accepted (v1 baseline) · **Date:** 2026-10-24 · **Owner:** irahardianto
**Inputs:** `DISCOVERY_HANDOFF.md`, `docs/research/01..07-*.md`, `docs/research/verification/V01..V07-*.md`

This document is the **single source of truth** for every other file in `docs/spec/`. If a spec document disagrees with this file, this file wins and the spec document is a bug. Section 3 (Canonical Registry) fixes names, paths, keys and numbers so that independently written documents stay consistent.

---

## 1. Direction changes vs. `DISCOVERY_HANDOFF.md`

| Handoff said | v1 decision | Why |
|---|---|---|
| Python directory provider talks to SurrealDB directly; "not an MCP server" | **Rust service owns all memory logic**; Hermes plugin is a **thin Python HTTP client**; the same service exposes **MCP** for other agents | One implementation for every consumer; plugin stays dependency-free; Rust gives a lean, fast, typed core |
| Embedded mode, "no Docker" | **All-in-one Docker image** (Engram + SurrealDB) is the primary v1 distribution; the bare binary + `surreal` on PATH also works | Foolproof adoption: one `docker run` |
| `MTREE`, `SEARCH ANALYZER ... BM25` | `HNSW`, `FULLTEXT ANALYZER ... BM25` | MTREE and SEARCH were removed in SurrealDB 3.x (V05, executed) |
| `prefetch()` must only serve the previous turn's cache | `prefetch()` does a **live recall for the current query under a tight deadline**, falling back to the `queue_prefetch()` cache | Cache-only causes a 1-turn lag and cold-start blindness; Hermes gives prefetch its own thread + 8 s timeout; Hindsight/ByteRover recall live (V04 F-01) |
| Plugin-side single writer thread + durable queue | **No plugin queue.** `sync_turn` POSTs directly (Hermes already runs it on its `mem-sync` executor); a small **spool-on-failure** file covers service outages | Durability is owned by the service + SurrealDB (V04 F-02) |
| LLM-assigned float `confidence` | **Deterministic confidence** from source trust + support count | Hindsight removed LLM float confidence as uncalibrated noise (migration `g2h3i4j5k6l7`, V01) |
| Relation table `asserts` | Relation table **`fact`** | Same concept; name matches the API ("facts") |

Still binding from the handoff: bi-temporal facts from day one, immutable episodes, contradictions represented not resolved, closed predicate vocabulary, five tools, built-in `MEMORY.md`/`USER.md` stay active, never hand-edit Hermes `config.yaml`, secrets only in `.env`, `spawn_context_thread` for every plugin background job, `is_trivial_prompt()` gate, non-primary contexts don't write. Mem0/Cognee/Hindsight/Zep are **learned from, not adopted**.

---

## 2. Decisions

### ADR-01 — Service topology
Engram = one Rust binary (`engram`) exposing, on **one port (8080)**: REST API (`/v1/...`), MCP Streamable HTTP (`/mcp`), health (`/healthz`, `/readyz`) and Prometheus metrics (`/metrics`). All memory logic lives in the service. Consumers: Hermes (thin plugin, REST), any MCP client (Claude Code, Codex, Cursor, Gemini CLI, …), and plain HTTP clients. Bearer auth applies to `/v1/*` and `/mcp` only; `/healthz`, `/readyz`, `/metrics` are unauthenticated (expose no memory content). In axum 0.8 `/mcp` is mounted with `.nest_service("/mcp", …)` on an auth-layered sub-router — never nested at `/` (panics; VS4 FIND-07).

### ADR-02 — Talk to SurrealDB over HTTP RPC, not the `surrealdb` SDK crate
Engram's store layer is a small internal client over `reqwest` calling SurrealDB's **`POST /rpc`** (RPC envelope `{id, method: "query", params: [sql, vars]}`, **CBOR-encoded** — see wire-format rule below; bound variables; `surreal-ns`/`surreal-db` headers; Basic auth with the managed root credentials).
- **Verified 2026-10-24 on `surrealdb/surrealdb:v3.3.4`:** bound vars work; multi-statement `BEGIN … THROW … COMMIT` rolls back atomically; `search::rrf` works over RPC; anonymous access is rejected.
- **Why:** (1) the `surrealdb` crate *itself* is BSL-1.1 (V05 FIND-02, V06 F-03), so not linking it keeps Engram's binary permissively licensed; (2) removes the SDK's large transitive tree (we already need `reqwest` for LLM/embedding calls); (3) HTTP keep-alive pooling is enough; we do not need live queries.
- **Cost:** we own a ~300-line typed decode layer (`store::rpc`). Accepted.
- **Wire format: CBOR, never JSON (binding).** Verified 2026-10-24 on 3.3.4: with `Content-Type: application/json`, any bound string shaped like `ident:ident…` is coerced into a record id and truncated (`"User: Hello\nAssistant: Hi"` → record `User:Hello`; `"Note:fix the build"` → `Note:fix`; `"TODO: rotate key"` → `TODO:rotate`). Casting (`<string>$x`, `type::string`) cannot recover the lost text. With `Content-Type: application/cbor` + `Accept: application/cbor`, strings round-trip exactly and SurrealDB types are explicit CBOR tags: **tag 6** = NONE, **tag 8** = record id `[table, id]`, **tag 12** = datetime `[seconds, nanoseconds]` (tag 0 RFC 3339 string also accepted on input). `store::rpc` therefore uses `ciborium` (serde CBOR) with newtypes `RecordId` (tag 8), `Datetime` (tag 12) and an explicit NONE; JSON is used only for Engram's own REST API.
- **Injection rule:** all user-derived values are bound variables. The only exception is the KNN operator `<|k,ef|>`, which on 3.3.4 accepts integer literals only (bound params are a parse error): `k`/`ef` are formatted from validated `u16` values in code, never from strings.
- **Other verified 3.3.4 constraints:** a `FULLTEXT` index covers exactly one field (define one index per field, query with `@0@`/`@1@` …); KNN is evaluated before `WHERE` post-filters, so channels over-fetch (×3) when filtering on `status`.
- SurrealDB itself (the `surreal` server binary, BSL-1.1) runs as a separate process. Its Additional Use Grant permits this use because Engram does not offer a "Database Service" (third parties cannot create/manage schemas or tables). Document this in the README/NOTICE.

### ADR-03 — Packaging & process model (all-in-one image)
- Image = `debian:bookworm-slim` runtime + `tini` (PID 1) + `engram` + the official `surreal` binary copied from `surrealdb/surrealdb:v3.3.4` (source path `/surreal`, installed at `/usr/local/bin/surreal`; verified to run on bookworm-slim, V06).
- **Managed mode (default in image):** `engram` spawns and supervises `surreal start` bound to **127.0.0.1:8000** (never exposed), with **generated root credentials** persisted at `/data/secrets/surreal_root` (mode 0600). Engram waits for readiness (`GET {surreal.url}/health` poll with backoff) before running migrations; restarts the child with exponential backoff on crash; streams child logs into Engram's tracing output. `surreal.url` is a base URL; the store appends `/rpc` for queries.
- **External mode:** `ENGRAM_SURREAL_MODE=external` + `ENGRAM_SURREAL_URL` etc. → connect to an existing SurrealDB (compose/k8s/shared host).
- **Ordered shutdown (SIGTERM/SIGINT):** (1) stop accepting HTTP/MCP; (2) finish in-flight requests (≤10 s); (3) let running jobs reach a commit point or release their lease (≤15 s); (4) send SIGTERM to `surreal`, await exit (≤10 s, then SIGKILL); (5) exit. Docker `stop_grace_period` ≥ 40 s.
- **Signal isolation (VS4):** the `surreal` child is spawned with `process_group(0)` (own process group) so group-directed signals from the runtime/terminal reach only `engram`; step (4) uses `libc::kill(pid, SIGTERM)` + `tokio::time::timeout(10 s, child.wait())`, and `child.kill()` (SIGKILL) only on timeout. `kill_on_drop(true)` remains as a crash safety net.
- Rejected: embedding `surrealdb-core` in-process (605 vs ~380 crates, slow builds, BSL linkage, no Surrealist access) — may return as an optional feature post-v1. Rejected: two-container compose as the *primary* path (kept as a documented alternative via external mode).

### ADR-04 — Storage engine
Managed mode uses **RocksDB** (`rocksdb:///data/surreal`) by default — most mature engine; `surrealkv` selectable via `ENGRAM_SURREAL_ENGINE=surrealkv`. Raw data dirs are not portable across SurrealDB majors → **logical export (`surreal export` / Engram `engram export`) is the backup and upgrade format**.

### ADR-05 — Tenancy: one SurrealDB database per memory bank
Namespace `engram`; **database = bank id** (`[a-z0-9][a-z0-9_-]{0,62}`). A bank is an isolated memory (HNSW, FTS, graph all scoped). Banks are **auto-created on first use** with server defaults (foolproof) or explicitly via `PUT /v1/banks/{bank}`. Provisioning order (verified on 3.3.4: scoped requests to a non-existent ns/db return `NotFound`): `DEFINE NAMESPACE IF NOT EXISTS engram` (no ns/db headers) → `DEFINE DATABASE IF NOT EXISTS <bank>` (ns header only) → migrations (ns+db headers). Hermes maps one profile → one bank (default `hermes-<profile>`). MCP clients pick a bank via `X-Engram-Bank` header or `?bank=` (default `default`). Per-bank `meta` record stores schema version, embedding model + dimension, predicate vocabulary version, timezone.

### ADR-06 — Embeddings
External endpoint only in v1 (Ollama native `/api/embed` or OpenAI-compatible `/v1/embeddings`). **Default `qwen3-embedding:0.6b`, 1024 dims** (multilingual — the owner writes English and Indonesian; 32k context). Dimension is fixed per bank at creation and recorded in `meta`; changing model/dim = `engram reembed --bank X`, an in-place maintenance operation (vector channels degraded to BM25/graph while it runs; no shadow fields or tables) — procedure in ADR-17. In-process ONNX/candle rejected for v1 (dependency weight, V01/R6).

### ADR-07 — LLM extraction: one structured call per batch
- Provider: Ollama `/api/chat` with JSON-schema `format`, or OpenAI-compatible `/v1/chat/completions` with `response_format: json_schema` (OpenRouter works). Default model `qwen3:8b` on Ollama; configurable.
- **One LLM call per extraction batch** produces entities, facts (closed predicates), temporal bounds and polarity in one JSON document. Batching per session: up to `extraction.batch_max_turns` (4) turns or `extraction.batch_idle_ms` (20 000 ms) idle, whichever first; immediate flush on session end / pre-compress / explicit `remember`.
- **Candidate-entity priming (Mem0 integer-handle trick):** before the call, retrieve likely existing entities for the batch text (exact alias + BM25 + vector on names) and present them as `E1..En`; the LLM references handles instead of re-typing names/ids. Handles are mapped back in code; unknown handles are rejected.
- Prompts are versioned files (`prompts/extract.v1.md`), the version is stored on every derived record (`extractor_version`) for reproducible re-extraction.
- **Two-stage availability:** an episode is durable and BM25-searchable immediately on ingest; its embedding follows within seconds (job); graph facts follow after extraction. No "hours until searchable".

### ADR-08 — Truth maintenance is deterministic code, not an LLM judgment
**Two independent axes.** `status` is the *belief lifecycle* (transaction time): `active | superseded | retracted | pending`. `valid_from/valid_to` is *world time*. A fact can be `active` with a past `valid_to` (a believed historical fact, e.g. "lived in London 2021–2023"). **Current truth** = `status = 'active' AND (valid_to IS NONE OR valid_to > now)`. **Historical / as-of-T truth** uses the validity interval and `recorded_at/expired_at` (see 03-data-model).

**Trust ranks** (high→low): `user_stated` (5: explicit user statement, `engram_remember`, mirrored `MEMORY.md`/`USER.md`) › `user_implied` (4) › `assistant_stated` = `tool_output` (3) › `inferred` (2, consolidation). Confidence = `trust_base[trust] × (1 + 0.1·min(support−1, 5))`, clamped to [0,1], 2 dp; `trust_base = {user_stated: .9, user_implied: .75, assistant_stated: .6, tool_output: .6, inferred: .5}`.

**Ordered rules** for an incoming fact `n = (s, p, o_n, polarity)` against existing `active` facts `E` with the same `(s, p)`; first matching rule wins; every outcome is written to `audit`:
1. **Restatement** — same object and polarity as `e ∈ E`: `e.support += 1`, `e.source_episodes += episode`, recompute confidence, no new edge. If `e.contested` and `rank(n) ≥ 4` and `rank(n) ≥ rank(c)` for every `c ∈ e.conflicts_with`: **resolve** — each `c` becomes `superseded` (`valid_to = n.valid_from`, `expired_at = now`, `superseded_by = e`), `e.contested = false`, `conflicts_with` cleared on both sides.
2. **Authority guard** — `p` functional, `e` is `user_stated`, `rank(n) ≤ 3`, objects differ: **reject** `n` (no fact written; audit `rejected_low_trust`). Same guard applies to a negative-polarity `n` targeting a `user_stated` fact. Assistant/tool/inferred claims never contest or close what the user said.
3. **Negative polarity** — closes the matching positive `e` (any cardinality) in *world time only*: `e.valid_to = n.valid_from`; `e.status` stays `active` (it is now a believed historical fact); the closing episode is appended to `e.source_episodes` and recorded in `audit`. No new edge. (`superseded` always implies a `superseded_by` successor; `retracted` is reserved for `forget`.)
4. **`related_to`** and **multi** predicates with a different object: insert as a new independent fact (never reconciled).
5. **Functional, orderable, later** — both `time_precision ≠ unknown`, `n.valid_from > e.valid_from` (strict), `rank(n) ≥ rank(e)`: **supersede** `e` (`valid_to = n.valid_from`, `expired_at = now`, `status = superseded`, `superseded_by = n`; `n.supersedes = e`). With `reconcile.require_approval = true` and `n.trust ≠ user_stated`, `n` is written as `pending` instead and `e` is untouched until approval.
6. **Functional, orderable, earlier (history backfill)** — `n.valid_from < e.valid_from`: `n` is a historical fact; insert with `valid_to = min(n.valid_to, e.valid_from)` and `status = active`; no contest.
7. **Otherwise contest** — equal `valid_from`, unknown precision on either side, or `rank(n) < rank(e)` with `n` later: insert `n`, set `contested = true` on both, link `conflicts_with` both ways.

**Concurrency guard:** every supersede/close is `UPDATE … WHERE status = 'active'` inside the commit transaction, and the transaction `THROW`s if the affected row count is 0 (VS2 FIND-07); the job retries and re-evaluates. **Retraction** (`forget`) of a fact that superseded `e` reopens `e` (`status = active`, `valid_to`/`expired_at`/`superseded_by` cleared) unless another active fact has since superseded it. Graphiti rules adopted in the extraction prompt: future plans anchor `valid_from` to statement time; deadlines never set `valid_to`; never infer an ending from recency alone.

### ADR-09 — Closed predicate vocabulary (v1 defaults, configurable per bank)
Out-of-vocabulary relations are stored as `related_to` with a free-text `label` (low retrieval weight, never reconciled) unless `extraction.strict_vocabulary = true`, in which case they are dropped and counted.

| Predicate | Cardinality | Typical subject → object |
|---|---|---|
| `is_a` | multi | any → concept |
| `works_at` | functional | person → organization |
| `has_role` | functional | person → concept |
| `reports_to` | functional | person → person |
| `located_in` | functional | person/org/thing → place |
| `member_of` | multi | person → organization/project |
| `part_of` | multi | any → any |
| `owns` | multi | person/org → project/account/thing |
| `uses` | multi | any → tool/software/concept |
| `written_in` | functional | software/project → concept (language/stack) |
| `depends_on` | multi | software/project → software/tool |
| `prefers` | multi | person → concept (polarity negative = avoids) |
| `scheduled_for` | multi | event/task → event (date carried in `valid_from`) |
| `credentials_for` | multi | account/secret-name → software/service (never the secret value) |
| `related_to` | multi | catch-all with `label` |

Entity kinds: `person`, `organization`, `project`, `software`, `tool`, `account`, `place`, `concept`, `event`.

### ADR-10 — Entity resolution
In order, first match wins: (1) LLM picked a primed handle `E#`; (2) exact match on normalized key (`lowercase`, trim, collapse whitespace, strip punctuation) against `entity.name_key` or any `aliases` key; (3) same kind and `string::similarity::jaro_winkler ≥ 0.92` on normalized names; (4) same kind and name-embedding cosine ≥ `resolution.embed_merge` (0.90). Scores in [`resolution.embed_review`, `embed_merge`) = [0.80, 0.90) create a new entity plus a `possible_same_as` note in `meta`-tracked review list (surfaced by `engram_entities`, merged by consolidation or `POST …/entities/merge`). Otherwise create. All thresholds configurable. Hub damping in retrieval: edge weight × 1/√(degree).

### ADR-11 — Retrieval
Per recall: embed query (one call) → **one multi-statement SurrealQL round trip** returning ranked lists for: vector (fact.statement, observation, episode), BM25 (same + entity names/aliases), and recent-episodes → **graph expansion round trip** from seed entities (query-mentioned entities ∪ subjects/objects of top hits), 1 hop by default (`retrieval.graph_hops` ≤ 2), live facts only, hub-damped → **temporal handling**: rule-based parser (English + Indonesian keywords: yesterday/kemarin, last week/minggu lalu, in July/bulan Juli, ISO dates) yields an optional window used to filter/boost and to switch on historical (superseded) facts; otherwise recency acts as a channel → **weighted RRF in Rust** (k = 60; weights vector 1.0, bm25 1.0, graph 0.8, recency 0.5) → validity filter (superseded excluded unless historical/`as_of` query; contested pairs kept together) → **MMR** (λ = 0.7) → **token-budget packing** (default 1 200 tokens, estimate = ceil(chars/3.5)) → markdown + JSON. Optional external cross-encoder rerank (`/rerank` TEI/Jina/Cohere-style) off by default. `search::rrf` exists in 3.3 and may be used for two-list fusion, but cross-channel fusion stays in Rust for weights and per-channel tracing. No LLM on the read path.

**Latency targets (local Ollama, NVMe, bank ≤ 100k facts):** recall p95 ≤ 150 ms service-side (embedding call dominates); ingest accept p95 ≤ 20 ms; Hermes `prefetch` p95 ≤ 250 ms end-to-end.

### ADR-12 — Consolidation (observations)
Triggered on session end, and when an entity accumulates ≥ `consolidation.min_new_facts` (5) new facts since last pass — tracked by `entity.unconsolidated_facts` (int, incremented in the commit transaction for subject and object; when it reaches the threshold the same transaction enqueues a `consolidate` job and resets it to 0). One LLM call per batch (≤ 20 facts + ≤ 10 candidate observations). Hindsight rules adopted: prefer update over create, one facet per observation, preserve history on state change, no arithmetic inference, recency by statement time not arrival order. Observations are never deleted: updates create a new version and close the old (`valid_to`, `superseded_by`). `support` = number of distinct supporting episodes; `evidence` references facts/episodes. Entity `summary` is rebuilt **deterministically** from top live facts (no LLM).

### ADR-13 — Hermes plugin shape
Directory provider `engram` (installed to `$HERMES_HOME/plugins/engram/`), **zero extra Python deps** (uses Hermes' pinned `httpx`). `prefetch`: live recall with `prefetch_timeout_ms` (1 500) deadline → fallback to the `queue_prefetch` cache → else `""`; circuit breaker (3 consecutive failures → 30 s open). `sync_turn`: POST episode (timeout 3 s) → on failure append to spool `$HERMES_HOME/engram/spool.jsonl` (cap 10 000 lines / 20 MB), replayed oldest-first after the next success. Writes only when `agent_context == "primary"` (configurable). `on_memory_write` mirrors add/replace/remove (removal reads `metadata["previous_content"]`). `on_pre_compress`: flush the session (`…/sessions/{id}/flush`, wait ≤ 5 s) and return a short "facts captured" digest; `pre_compress_checkpoint_api_version` stays **1** in v1 (v2 opt-in only after the fail-closed contract is implemented and tested). `on_session_end` → `…/sessions/{id}/end`. Five tools mirror the MCP tools. `backup_paths()` returns `[]` (service data lives in the Docker volume; the spool is inside `HERMES_HOME`).
- **Hard wall-clock deadline (VS3-02):** httpx timeouts are per phase, so `prefetch` runs the recall on a `spawn_context_thread` worker and `join(timeout=prefetch_timeout_ms)`; if still alive it counts a breaker failure and returns the cache. Measured: 1 508 ms on a stalled server with a 1 500 ms budget.
- **Profile-scoped config (VS3-01/05):** `memory.engram.*` is read with `hermes_cli.config.load_config_readonly()` inside `set_hermes_home_override(hermes_home)` / `reset_hermes_home_override(token)`; same for `save_config`. List-valued settings (`write_contexts`) use `type: "text"` (comma-separated) in `get_config_schema`. Tool schemas are returned in the bare `{name, description, parameters}` shape; errors via `from tools.registry import tool_error`.

### ADR-14 — Security
Single static bearer key (`ENGRAM_API_KEY`) for REST and MCP; if unset at first boot, Engram generates one, stores it at `/data/secrets/api_key` (0600) and logs it **once** (`engram key show` prints it later). Constant-time comparison. `ENGRAM_AUTH=disabled` allowed only when bound to loopback. Docs publish the port as `-p 127.0.0.1:8080:8080`. Server-side regex redaction of common secret shapes (API keys, bearer tokens, private keys, passwords in URLs) before persistence and before any embedding/LLM egress — on by default, complements Hermes' own `redact_for_egress`. No telemetry phone-home, ever.
- **Access policy (v1):** one key = full access to all banks over REST and MCP (single-operator product). Per-bank scoped keys are a v1.1 item.
- **Purge (irreversible, admin):** `POST /v1/banks/{bank}/purge` `{ "ids": [...], "confirm": "PURGE" }` physically deletes the listed episodes/facts/observations, plus facts and observations whose *only* evidence is a purged record, and scrubs them from `audit` (the audit keeps an `action = purge` row with ids and counts, never content). For leaked secrets/PII and right-to-be-forgotten. Not exposed as an MCP/Hermes tool. Normal deletion remains soft (`forget`).

### ADR-15 — Observability
`tracing` + `tracing-subscriber` (JSON logs by default, pretty optional) everywhere; span names fixed in §3.7. W3C `traceparent` accepted from callers (Hermes plugin sends one) and echoed; `x-request-id` set/propagated. **OTLP trace export** behind cargo feature `otlp` (`opentelemetry-otlp` over HTTP/protobuf using reqwest — no tonic/gRPC), **enabled in the official image** and activated only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. **Metrics:** `prometheus-client` (official Prometheus Rust client, small) rendered at `/metrics`. A per-bank `audit` table records the decision trace of every extraction/reconciliation (what was proposed, what code decided, why) with retention (default 30 days).

### ADR-16 — Rust stack & dependency budget
Tokio ecosystem end to end: `tokio`, `axum 0.8`, `tower`, `tower-http`, `tracing`, `tracing-subscriber`, `rmcp 3.7` (server + macros + streamable-http-server), `reqwest` (rustls, json, no default features), `serde`/`serde_json`, `ciborium` (CBOR for the SurrealDB RPC wire, ADR-02), `schemars` (via rmcp), `thiserror`, `toml`, `clap` (derive, minimal features), `prometheus-client`, `tokio-util` (no features), `subtle` (constant-time key compare) and `libc` (SIGTERM to the child) — both already transitive, 0 net crates, `jiff` (feature `tzdb-bundle-always`) for all date/time math and timezone handling (bundled tzdb, because `debian:bookworm-slim` ships no `/usr/share/zoneinfo`). Temporal expressions are resolved in the bank timezone (`meta.timezone`, default from `server.timezone` = `UTC`; a recall/episode request may pass `timezone`). **Not used:** `surrealdb` SDK, `figment`, `validator`, `backon`, `anyhow` in library code, `async-openai`, `fastembed`. **Budget:** ≤ 300 unique crates in the default build (`cargo tree -e normal --prefix none | sort -u | wc -l`), ≤ 340 with `otlp`; stripped release binary ≤ 25 MB; image ≤ 650 MB uncompressed / ≤ 160 MB compressed pull (the official `surreal` 3.3.4 binary alone is 352 MB, 105 MB gzipped — measured 2026-10-24; Engram's own contribution must stay ≤ 40 MB uncompressed). Edition 2024, MSRV 1.88. **Measured 2026-10-24 (11-rust-implementation-guide.md):** 218 normal crates default / 245 with `otlp` (incl. `ciborium`, VS4 vertical slice), stripped binary 7.41 MB; adding the `surrealdb` SDK would cost +124 normal crates and 7 BUSL-1.1 crates. `cargo-deny` allowlist: Apache-2.0, MIT, BSD-2/3, ISC, Unicode-3.0, Zlib, MPL-2.0 (file-level), CDLA-Permissive-2.0 (`webpki-root-certs` via reqwest/rustls).

### ADR-17 — Jobs (outbox in SurrealDB)
All async work is a `job` record written in the **same transaction** as the data that caused it (outbox). Kinds: `embed`, `extract`, `consolidate`, `reembed`. Workers claim with a lease (`lease_until`), retry with exponential backoff (1 s → 5 min, max 8 attempts, jitter), then `status = dead` (visible in `engram_status`, retryable via API). **One writer worker per bank** (serializes resolution/reconciliation, avoids HNSW write races); banks processed concurrently up to `jobs.max_concurrent_banks` (4). Embedding jobs may run concurrently with each other but commit via the bank writer.
- **Durable batching timers (no in-memory timers):** extraction batching is a single `extract` job per session with deterministic id `job:['extract', <session_id>]`, upserted in the ingest transaction: first pending turn creates it with `run_after = now + batch_idle_ms`; each further turn pushes `run_after = now + batch_idle_ms`; the `batch_max_turns`-th pending turn, `remember`, curated writes, `…/flush` and `…/end` set `run_after = now`. Workers claim `status IN ['pending', 'failed'] AND run_after <= now` (or `running` with an expired lease), so restarts lose nothing.
- **Job status lifecycle (binding; matches the migration enum):** `pending` (runnable at `run_after`) → `running` (claimed: `claimed_by`, `lease_until`, `attempts += 1`) → on success `completed` (written in the commit transaction; housekeeping deletes `completed` jobs older than 24 h) · on error `failed` with `last_error` and `run_after = now + backoff` (claimable again) · after `max_attempts` `dead`. `POST …/jobs/{id}/retry` sets a `dead`/`failed` job to `pending`, `attempts = 0`, `run_after = now`. No other status values exist.
- **Extract-job re-arm rules (verified on 3.3.4):** the ingest upsert uses `SET` (never `CONTENT`, which rewrites the READONLY `created_at` and fails on the second turn) and must (a) never downgrade a `running` job (`status = IF status = 'running' { 'running' } ELSE { 'pending' }`), and (b) reset `attempts = 0` when reviving a `completed` or `dead` job. When an extraction commits, the same transaction sets the job to `pending` with `attempts = 0` and the lease cleared if the session still has `extraction_state = 'pending'` episodes (turns that arrived during the run), otherwise `completed`. Canonical statements: `03-data-model.md` `Q-EXTRACT-JOB-UPSERT` and `Q-JOB-CLAIM`.
- **Flush contract:** `POST …/sessions/{id}/flush` sets that job's `run_after = now`, wakes the bank worker, and waits (≤ `wait_ms`, max 10 000) on an in-process completion notification; response `{"status": "completed" | "pending", "facts_written": n, "digest": [...]}`. The HTTP handler never runs extraction itself (single writer preserved).
- **Bank auto-create:** per-bank single-flight lock in process (`Mutex` map) around provisioning + migrations; DDL is idempotent anyway, so a second process/racer is harmless.
- **Re-embedding (`engram reembed`)** is an in-place maintenance operation: set `meta.maintenance = 'reembed'` (recall marks `degraded.vector = true` and skips vector channels), `REMOVE` the HNSW indexes, re-embed rows in batches of 100 via `reembed` jobs, `DEFINE` the HNSW indexes with the new dimension, update `meta.embedding_model/embedding_dim`, clear maintenance. No shadow fields.

### ADR-18 — MCP
Streamable HTTP at `/mcp` (rmcp `StreamableHttpService` nested into axum; tools wired with `#[tool_router(server_handler)]` — V06 F-02). Supports protocol revisions from `2025-06-18` through `2026-07-28` as provided by rmcp 3.7. Same bearer auth. Tools = the five in §3.4; no resources/prompts required in v1 (one optional `engram://guide` resource). stdio transport deferred to v1.1 (`engram mcp-stdio` bridge).

### ADR-19 — Evaluation
CI: deterministic suite (≥ 30 scenarios, mocked LLM/embeddings, real SurrealDB in memory mode) gating truth maintenance, temporal rules, idempotency, recall formatting/budget. Nightly/manual: LongMemEval_S subset (100 questions, 20 per ability) with strict scoring, plus latency/cost capture. Report strict accuracy; never drop abstention questions. **Targets are goals, not claims:** (a) local-only stack (default Ollama models): record the baseline at M5; a later release may not regress strict accuracy by > 3 points; (b) frontier answer/judge model with the same memory: goal ≥ 70 % strict on the 100-question subset (Zep reported 71.2 % on LongMemEval with GPT-4o — context, not a like-for-like comparison).

---

## 3. Canonical Registry (names every document must use)

### 3.1 Process, ports, paths
| Item | Value |
|---|---|
| Binary | `engram` (subcommands: `serve`, `migrate [--bank <b> \| --all]`, `export`, `import`, `reembed --bank <b> [--model <m>] [--dim <n>]`, `key show`, `doctor`, `healthcheck`; no others in v1) |
| HTTP port | `8080` (`ENGRAM_BIND`, default `0.0.0.0:8080` in image, `127.0.0.1:8080` bare) |
| Managed SurrealDB | `127.0.0.1:8000`, namespace `engram`, database = bank id |
| Data dir | `/data` (`ENGRAM_DATA_DIR`): `/data/surreal/` (engine files), `/data/secrets/` (`api_key`, `surreal_root`), `/data/backups/` |
| Container user | UID/GID `10001` (`engram`); bind mounts need `chown -R 10001:10001` |
| Image | `ghcr.io/irahardianto/engram:<version>` |

### 3.2 REST API (all JSON; errors `{"error":{"code","message","details"}}`)
| Method & path | Purpose |
|---|---|
| `GET /healthz` · `GET /readyz` · `GET /metrics` | liveness · readiness (SurrealDB reachable + migrations done) · Prometheus |
| `GET /v1/status` | service status: version, SurrealDB state, banks, job backlog |
| `GET /v1/banks` · `PUT /v1/banks/{bank}` · `GET /v1/banks/{bank}` | list · create/configure · bank stats & config |
| `POST /v1/banks/{bank}/episodes` | ingest 1..100 episodes (turns, notes, curated mirrors, delegations) → `202` |
| `POST /v1/banks/{bank}/recall` | hybrid recall → markdown + items |
| `POST /v1/banks/{bank}/remember` | explicit memory (free text or structured triple), trust `user_stated`, priority extraction |
| `POST /v1/banks/{bank}/forget` | retire a fact/observation/episode by id (soft; never hard delete) |
| `GET /v1/banks/{bank}/entities` · `GET /v1/banks/{bank}/entities/{ref}` · `POST /v1/banks/{bank}/entities/merge` | search/list · inspect (live facts, `?history=true`, `?as_of=`) · merge duplicates |
| `GET /v1/banks/{bank}/facts` · `GET /v1/banks/{bank}/facts/{id}` | filter by subject/predicate/status · single fact with provenance |
| `POST /v1/banks/{bank}/sessions/{session_id}/flush` | run pending extraction for a session now (`wait_ms` ≤ 10 000) |
| `POST /v1/banks/{bank}/sessions/{session_id}/end` | mark session ended → flush + consolidation |
| `GET /v1/banks/{bank}/jobs` · `POST /v1/banks/{bank}/jobs/{id}/retry` | job backlog / dead jobs · retry |
| `POST /v1/banks/{bank}/export` · `POST /v1/banks/{bank}/import` | admin: logical export/import (SurrealQL) |
| `POST /v1/banks/{bank}/purge` | admin: irreversible physical deletion (ADR-14) |
| `ANY /mcp` | MCP Streamable HTTP |

Headers: `Authorization: Bearer <key>`, optional `traceparent`, `x-request-id`, `Idempotency-Key` (episodes/remember), MCP bank selection `X-Engram-Bank`.

### 3.3 SurrealDB tables (per bank database)
`meta` (singleton `meta:bank`), `episode`, `entity`, `fact` (RELATION `entity`→`entity`), `mentions` (RELATION `episode`→`entity`), `observation`, `session`, `job`, `audit`, `schema_migration`.

Key fact fields: `in`, `out`, `predicate`, `label`, `polarity`, `statement`, `embedding`, `valid_from`, `valid_to`, `time_precision`, `recorded_at`, `expired_at`, `status` (`active|superseded|retracted|pending`), `contested`, `conflicts_with` (`array<record<fact>>`, default `[]` — a fact may contest several others), `supersedes`, `superseded_by`, `trust`, `support`, `confidence`, `source_episodes`, `extractor_version`.
Key episode fields: `session_id`, `kind` (`turn|note|curated|delegation|document`), `user_text`, `assistant_text`, `text` (rendered, indexed), `author`, `occurred_at`, `recorded_at`, `content_hash`, `idempotency_key`, `trust`, `embedding`, `extraction_state` (`pending|done|skipped|failed`), `metadata`, `retracted_at`.
Key observation fields: `text`, `embedding`, `subject` (option<record<entity>>), `support`, `evidence` (array of fact/episode records), `confidence`, `valid_from`, `valid_to`, `recorded_at`, `expired_at`, `status` (`active|superseded|retracted` — same lifecycle as `fact`), `supersedes`, `superseded_by`, `extractor_version`.
Key entity fields: `name`, `name_key` (UNIQUE), `kind`, `aliases`, `alias_keys`, `summary`, `embedding`, `first_seen`, `last_seen`, `last_updated`, `mention_count`, `unconsolidated_facts`, `confidence`.
Key meta fields (`meta:bank`): `schema_version`, `bank_id`, `embedding_model`, `embedding_dim`, `vocabulary_version`, `timezone`, `maintenance` (`option<string>`), `created_at`, `updated_at`.
Enums: `time_precision` = `exact|day|month|year|unknown`; `polarity` = `positive|negative`; `trust` = `user_stated|user_implied|assistant_stated|tool_output|inferred`.
Episode idempotency: `idempotency_key` is **always set** — the client `Idempotency-Key`/field if given, else `sha256(session_id ‖ kind ‖ text)` computed in the ingest query — with a UNIQUE index; a duplicate returns the existing episode id with `duplicate: true` (HTTP 202).
**Forget semantics:** fact/observation → `status = retracted`, `expired_at = now` (`valid_to` untouched: retraction withdraws belief, it does not assert an end in the world), plus ADR-08 predecessor reopen (a retracted observation reopens the observation it superseded); episode → `retracted_at = now`, and facts whose *only* source episodes are all retracted are retracted too (each cascaded fact applies the same predecessor reopen). Response `{"id", "status": "retracted", "retracted_at", "cascade": {"facts": n, "reopened": n}}` — `cascade.facts` counts facts retracted *because of* an episode retraction (0 when a fact is forgotten directly); `cascade.reopened` counts reopened predecessors.
**Audit schema (canonical = migration):** `at`, `actor` (`engram|api|mcp|hermes|system`), `action` (e.g. `extract`, `reconcile.supersede`, `reconcile.contest`, `reconcile.rejected_low_trust`, `forget`, `purge`, `consolidate`), `target_type`, `target_id` (string), `job` (option record), `details` (`object FLEXIBLE` — proposal hash, extractor_version, resolution and reconciliation decisions with reasons), optional `trace_id`, `session_id`, `reason` (strings).
**Recall response (canonical, used by 05/06/07/10):**
```json
{ "context_markdown": "string", "estimated_tokens": 0,
  "items": [{ "type": "fact|observation|episode|entity", "id": "fact:01…", "text": "…",
              "score": 0.0, "channels": {"vector": 1, "bm25": 3, "graph": null, "recency": null},
              "valid_from": "…", "valid_to": null, "occurred_at": null, "status": "active",
              "contested": false, "conflicts_with": [], "confidence": 0.9, "support": 2 }],
  "counts": {"facts": 0, "observations": 0, "episodes": 0, "entities": 0},
  "timings_ms": {"embed": 0, "channels": 0, "graph": 0, "fuse": 0, "pack": 0, "total": 0},
  "degraded": {"vector": false, "graph": false, "rerank": false},
  "temporal_window": null }
```
(`channels` holds the 1-based rank per channel or null.)

### 3.4 Tools (identical names in Hermes plugin and MCP)
`engram_recall`, `engram_remember`, `engram_forget`, `engram_entities`, `engram_status`. **Canonical input schemas live in `06-api-and-mcp.md` (MCP tools section)**; the Hermes plugin (07) returns the same parameter schemas in the bare `{name, description, parameters}` shape. Rust field names that are keywords use `#[serde(rename)]` + `#[schemars(rename)]` (e.g. `ref`).

### 3.5 Service configuration (`/etc/engram/engram.toml` or `$ENGRAM_CONFIG`; every key overridable by env `ENGRAM_<SECTION>_<KEY>`)
| Key | Default |
|---|---|
| `server.bind` | `0.0.0.0:8080` (image) |
| `server.api_key` (`ENGRAM_API_KEY`) | generated on first boot |
| `server.default_bank` | `default` |
| `server.timezone` | `UTC` (IANA name; copied into `meta.timezone` at bank creation; owner sets `Asia/Jakarta`) |
| `surreal.mode` (`ENGRAM_SURREAL_MODE`) | `managed` |
| `surreal.url` / `surreal.user` / `surreal.pass` | managed: `http://127.0.0.1:8000`, generated |
| `surreal.engine` | `rocksdb` |
| `surreal.binary` | `/usr/local/bin/surreal` |
| `data_dir` (`ENGRAM_DATA_DIR`) | `/data` |
| `embedding.provider` / `base_url` / `model` / `dimensions` | `ollama` / `http://host.docker.internal:11434` / `qwen3-embedding:0.6b` / `1024` |
| `embedding.api_key` (`ENGRAM_EMBEDDING_API_KEY`) | empty |
| `llm.provider` / `base_url` / `model` | `ollama` / `http://host.docker.internal:11434` / `qwen3:8b` |
| `llm.api_key` (`ENGRAM_LLM_API_KEY`) | empty |
| `extraction.enabled` / `batch_max_turns` / `batch_idle_ms` / `strict_vocabulary` | `true` / `4` / `20000` / `false` |
| `resolution.jaro_winkler` / `embed_merge` / `embed_review` | `0.92` / `0.90` / `0.80` |
| `reconcile.require_approval` | `false` |
| `retrieval.top_k` / `token_budget` / `rrf_k` / `graph_hops` / `mmr_lambda` | `12` / `1200` (max `8192`) / `60` / `1` / `0.7` |
| `retrieval.weight_vector` / `weight_bm25` / `weight_graph` / `weight_recency` | `1.0` / `1.0` / `0.8` / `0.5` |
| `rerank.enabled` / `base_url` / `model` | `false` / — / — |
| `rerank.timeout_ms` | `100` (rerank skipped on timeout) |
| `consolidation.enabled` / `min_new_facts` | `true` / `5` |
| `jobs.max_concurrent_banks` / `max_attempts` | `4` / `8` |
| `redaction.enabled` | `true` |
| `audit.retention_days` | `30` |
| `telemetry.log_format` | `json` |
| `telemetry.metrics_include_bank` | `false` (adds a `bank` label; opt-in because of cardinality) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` (standard env) | unset (OTLP off) |

### 3.6 Hermes plugin configuration (`memory.engram.*` via `hermes config set`; secret in `.env`)
`url` (`http://127.0.0.1:8080`), `bank` (`hermes-<profile>`), `prefetch_timeout_ms` (`1500`), `top_k` (`12`), `token_budget` (`1200`), `write_contexts` (`["primary"]`), `tools_enabled` (`true`), `mirror_builtin` (`true`); secret `ENGRAM_API_KEY`.

### 3.7 Telemetry names
Spans: `http.request`, `recall`, `recall.embed`, `recall.channel` (field `channel`), `recall.graph`, `recall.fuse`, `recall.pack`, `ingest.accept`, `job.run` (field `kind`), `extract.llm`, `resolve.entities`, `reconcile.facts`, `consolidate.llm`, `store.query` (field `op`), `surreal.supervisor`.
Metrics: `engram_http_requests_total{route,method,status}`, `engram_http_request_duration_seconds{route}`, `engram_recall_duration_seconds{stage}`, `engram_recall_items{type}`, `engram_ingest_episodes_total{kind}`, `engram_jobs_pending{kind}`, `engram_job_duration_seconds{kind,outcome}`, `engram_llm_requests_total{purpose,outcome}`, `engram_llm_tokens_total{purpose,direction}`, `engram_embedding_requests_total{outcome}`, `engram_facts_total{event}`, `engram_surreal_up`, `engram_surreal_restarts_total`, `engram_store_query_duration_seconds{op}`.

### 3.8 Repository layout
```
engram/
├── Cargo.toml  Cargo.lock  deny.toml  Dockerfile  docker-compose.yml  README.md  LICENSE  NOTICE
├── src/        # single crate, lib + bin
│   ├── main.rs  lib.rs  config.rs  error.rs  cli.rs
│   ├── api/        # axum routers, handlers, auth, errors
│   ├── mcp/        # rmcp server + tools
│   ├── domain/     # pure types: predicates, trust, temporal, reconciliation rules (no IO)
│   ├── ingest/     # accept, redaction, batching, extraction orchestration, resolution
│   ├── retrieve/   # query analysis, channels, fusion, mmr, packing, rendering
│   ├── consolidate/
│   ├── jobs/       # outbox worker, leases, backoff
│   ├── ai/         # embedding + llm + rerank HTTP clients
│   ├── store/      # rpc client, repositories, migrations
│   ├── supervisor/ # managed surreal child process
│   └── telemetry/  # tracing init, metrics registry, otlp (feature)
├── migrations/ 0001_init.surql …
├── prompts/    extract.v1.md  consolidate.v1.md
├── integrations/hermes/engram/   # thin Python plugin
├── tests/      # integration (real SurrealDB), scenario suite
└── eval/       # LongMemEval harness
```

---

## 4. Answers to the handoff's open questions (§11)
1. **Embedding model/dim:** `qwen3-embedding:0.6b`, 1024, per-bank fixed; `engram reembed` migration (ADR-06).
2. **Extraction cost:** 1 LLM call per ≤4-turn batch (+1 per consolidation pass). Measured estimate to be produced in `04-ingestion-pipeline.md` (prompt ≈ 1.5–2.5k tokens in, ≤ 800 out per batch).
3. **Auto vs approved writes:** episodes auto; facts auto with full reversibility; optional approval staging for supersessions by non-`user_stated` sources (ADR-08).
4. **Entity-resolution thresholds:** ADR-10 (0.92 JW, 0.90/0.80 embedding), configurable.
5. **Graph scope:** closed 15-predicate vocabulary, `related_to` catch-all (ADR-09).
6. **Consolidation policy:** session end or ≥5 new facts per entity; episodes kept; evidence referenced (ADR-12).
7. **Subagent/cron writes:** read yes, write no by default (`write_contexts`).
8. **Backup:** logical `engram export` (wraps SurrealDB export per bank) — not raw data dirs (ADR-04).
9. **Migrations:** `schema_migration` table + forward-only embedded migrations applied per bank at startup/creation; v1→v2 rehearsal test in CI.
10. **Failure UX:** Hermes always starts (no network in `is_available`); prefetch degrades to cache/empty; writes spool locally and replay; service returns `503` with `Retry-After` while SurrealDB is restarting; jobs are durable.
