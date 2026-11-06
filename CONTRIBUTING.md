# Contributing to Engram

Welcome! Thank you for your interest in contributing to **Engram** — a unified, single-engine long-term memory service for autonomous AI agents built with Rust and SurrealDB.

This repository currently ships the **complete, empirically verified v1 specification package** (`docs/spec/`), baseline SurrealQL schema (`migrations/0001_init.surql`), versioned LLM prompts (`prompts/`), and container packaging (`Dockerfile`, `docker-compose.yml`). Contributors are invited to pick up milestones (`M0`–`M5`) and help build out the reference implementation.

---

## 1. Golden Rule: Normative Precedence

Before writing code or proposing changes, read [`docs/spec/00-decisions.md`](docs/spec/00-decisions.md).

1. **[`docs/spec/00-decisions.md`](docs/spec/00-decisions.md) is the single source of truth.** It contains all 19 Architecture Decision Records (`ADR-01` through `ADR-19`) and the **Canonical Registry (§3)** of ports, CLI subcommands, REST routes, MCP tools, SurrealDB tables/fields, configuration keys, and telemetry metrics.
2. **[`migrations/0001_init.surql`](migrations/0001_init.surql)** is the canonical database DDL, tested directly against `surrealdb/surrealdb:v3.3.4`.
3. If another document conflicts with `00-decisions.md`, **`00-decisions.md` wins** and the conflicting text is a documentation bug.
4. When proposing an architectural or wire-contract change, update `00-decisions.md` first in the same pull request and explain the rationale against the existing ADR.

For a guided tour of the specification, start at [`docs/spec/README.md`](docs/spec/README.md).

---

## 2. Implementation Roadmap & How to Pick Up Work

Implementation is structured into six sequential milestones defined in [`docs/spec/01-prd.md §10`](docs/spec/01-prd.md#10-milestones--acceptance-criteria) and mapped to concrete acceptance tests in [`docs/spec/10-testing-evaluation.md §9`](docs/spec/10-testing-evaluation.md#9-milestone-acceptance-criteria-mapping):

| Milestone | Focus | Primary Spec Guides |
|---|---|---|
| **M0** | Service foundation, CLI (`engram serve`, `migrate`, `healthcheck`, `doctor`, `key show`), SurrealDB child process supervisor, CBOR `/rpc` client (`store::rpc`), bank bootstrap (`0001_init.surql`), `/healthz` & `/readyz`, Hermes plugin skeleton | [`02-architecture.md`](docs/spec/02-architecture.md), [`03-data-model.md`](docs/spec/03-data-model.md), [`08-deployment-operations.md`](docs/spec/08-deployment-operations.md), [`11-rust-implementation-guide.md`](docs/spec/11-rust-implementation-guide.md) |
| **M1** | Episode ingestion (`POST /v1/banks/{bank}/episodes`), SHA-256 idempotency, secret redaction, transactional `job` outbox, async embedding worker | [`03-data-model.md`](docs/spec/03-data-model.md), [`04-ingestion-pipeline.md`](docs/spec/04-ingestion-pipeline.md), [`06-api-and-mcp.md`](docs/spec/06-api-and-mcp.md) |
| **M2** | 4-channel hybrid retrieval (Vector HNSW, BM25, 1-hop Graph with hub damping, Recency), EN/ID temporal parser, Weighted RRF ($k=60$), MMR ($\lambda=0.7$), token packing, Hermes live `prefetch()` | [`05-retrieval.md`](docs/spec/05-retrieval.md), [`07-hermes-plugin.md`](docs/spec/07-hermes-plugin.md) |
| **M3** | Batch LLM extraction with integer entity handles (`E1..En`), closed 15-predicate vocabulary, entity resolution cascade, deterministic truth maintenance (ADR-08 Rules 1–7), `remember` & `forget` | [`03-data-model.md`](docs/spec/03-data-model.md), [`04-ingestion-pipeline.md`](docs/spec/04-ingestion-pipeline.md), [`prompts/extract.v1.md`](prompts/extract.v1.md) |
| **M4** | Background `observation` consolidation, Hermes `on_memory_write` (`MEMORY.md`/`USER.md`) mirroring, `on_pre_compress` flush, offline `spool.jsonl`, logical `export`/`import`, `reembed`, `purge` | [`04-ingestion-pipeline.md`](docs/spec/04-ingestion-pipeline.md), [`07-hermes-plugin.md`](docs/spec/07-hermes-plugin.md), [`08-deployment-operations.md`](docs/spec/08-deployment-operations.md), [`prompts/consolidate.v1.md`](prompts/consolidate.v1.md) |
| **M5** | MCP Streamable HTTP server (`/mcp` via `rmcp`), 49 deterministic CI scenarios (`S01`–`S49`), LongMemEval_S evaluation harness, multi-stage Docker release image | [`06-api-and-mcp.md`](docs/spec/06-api-and-mcp.md), [`09-observability.md`](docs/spec/09-observability.md), [`10-testing-evaluation.md`](docs/spec/10-testing-evaluation.md) |

---

## 3. Non-Negotiable Engineering Guardrails

Every pull request must respect the following architectural invariants:

### 3.1 Clean-Room Permissive Licensing & Crate Budget (ADR-02, ADR-16)
- **Zero BSL-1.1 Rust Dependencies:** Never add `surrealdb`, `surrealdb-core`, or any BSL-1.1 crate to `Cargo.toml`. All SurrealDB communication goes through `src/store/rpc.rs` over `POST /rpc` using `reqwest` + `ciborium` (`Accept: application/cbor`).
- **Dependency Budget:**
  - Default build (`cargo tree -e normal --prefix none | sort -u | wc -l`): **≤ 300 crates** (verified baseline: 218).
  - With `--features otlp`: **≤ 340 crates** (verified baseline: 245).
  - Forbidden heavy stacks: `tonic`, `prost`, `ort`, `candle`, `Burn`, `arrow`, `polars`, `openssl-sys`, `sqlx`, `sea-orm`, `actix-web`, `warp`, `rocket`, `clap_derive`, `dashmap`, `chrono`.
- **Time & Concurrency Primitives:** Use `jiff` for timestamps/timezones and `std::sync::Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>` for per-bank concurrency locks.

### 3.2 SurrealDB 3.3.4 & CBOR Wire Rules (ADR-02, `03-data-model.md §6`)
- Always bind record IDs with CBOR **Tag 8** (`RecordId`), datetimes with **Tag 12** (`Datetime`), and `Option::None` with **Tag 6** (`NONE` — never JSON/CBOR `null`, which fails `SCHEMAFULL` `option<T>` validation in SurrealDB 3.3.4).
- Inspect every per-statement entry in `/rpc` response arrays (`status == "OK"`); SurrealDB still executes a trailing `RETURN` statement after `COMMIT TRANSACTION` aborts.
- In SurrealQL, KNN `<|k,ef|>` parameters must be integer literals (`36`, `100`), never `$params`.
- Never use `UPDATE ... LIMIT` (syntax error in SurrealDB 3.x); select candidate IDs first, then update by ID inside a transaction.

### 3.3 Deterministic Truth Maintenance (ADR-08, ADR-09)
- Confidence scores are computed exclusively by the deterministic Rust formula in `00-decisions.md` (ADR-09)—never trust an LLM-generated confidence float.
- Reconcile new facts against active facts using the exact 7-step ordered decision table in ADR-08:
  - Negative polarity (`polarity = "negative"`) closes `valid_to` in world time while keeping `status = "active"` and `expired_at = NONE`.
  - Functional supersession (`valid_from > existing.valid_from`) sets `status = "superseded"`, `valid_to = new.valid_from`, and `expired_at = time::now()`.
  - Retraction (`engram_forget`) sets `status = "retracted"` and `expired_at = time::now()`, leaving `valid_to` untouched and reopening any predecessor the retracted fact had superseded.

### 3.4 Python Hermes Plugin Contract (ADR-13, `07-hermes-plugin.md`)
- The Hermes plugin (`integrations/hermes/engram/`) must remain a thin client using only Python 3.11+ standard library modules plus `httpx` (already present in the Hermes runtime).
- `is_available()` and `backup_paths()` must never perform network calls.
- Background threads must be spawned via Hermes's `spawn_context_thread` helper.

---

## 4. Verification & Testing Expectations

Before opening a pull request:
1. **Formatting & Lints:** `cargo fmt --check` and `cargo clippy --all-targets --features otlp -- -D warnings`.
2. **License & Budget Gate:** `cargo deny check bans licenses sources` and verify crate count ≤ 300 (default) / ≤ 340 (`otlp`).
3. **Live SurrealDB Tests:** Run integration and scenario tests (`S01`–`S49`) against `surrealdb/surrealdb:v3.3.4` (`mem://` for fast integration tests; `rocksdb://` for restart durability tests).
4. **Python Plugin Tests:** `pytest integrations/hermes/engram/tests/`.

---

## 5. License

By contributing to Engram, you agree that your contributions will be licensed under the [Apache License, Version 2.0](LICENSE).
