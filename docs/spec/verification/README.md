# Specification Verification Archive

> **Important for Contributors:** The files in this directory (`VS1`–`VS5`, `VS1b`, `VS2b`) are **historical, point-in-time audit records** produced during the multi-round authoring and empirical validation of the Engram v1 specification. They are preserved for engineering provenance and empirical benchmark traceability—**not** as normative specifications.
>
> **Normative Precedence:** When implementing Engram, always treat [`../00-decisions.md`](../00-decisions.md) (Architecture Decision Records + Canonical Registry), [`../../../migrations/0001_init.surql`](../../../migrations/0001_init.surql), and [`../01-prd.md`](../01-prd.md)–[`../12-prior-art-learnings.md`](../12-prior-art-learnings.md) as the single source of truth. Where an earlier verification report quotes draft prose or intermediate designs (for example, Round 1's JSON-RPC over `/rpc` before Round 2 proved SurrealDB 3.3.4 requires CBOR over `/rpc` for `NONE` and `record<T>` coercion), the main specification documents reflect the final ratified architecture.

---

## Audit Progression Overview

### Round 1 — Initial Empirical & Coverage Verification

| Report | Scope | What Was Empirically Tested | Key Outcome |
|---|---|---|---|
| [`VS1-consistency.md`](./VS1-consistency.md) | Cross-document invariants (`00`–`12`, `migrations/0001_init.surql`, `prompts/*.md`) | Exhaustive check of names, ports, config keys, REST routes, MCP tools, and schemas against `00-decisions.md`. | Identified 18 cross-document drift items (CLI flags, metric names, route parameters, and config defaults) resolved in Round 2. |
| [`VS2-storage-queries.md`](./VS2-storage-queries.md) | `migrations/0001_init.surql`, `03-data-model.md`, `04-ingestion-pipeline.md`, `05-retrieval.md` | Live execution against `surrealdb/surrealdb:v3.3.4` (`RocksDB` & `mem://`). | Caught SurrealQL 3.x parser/planner breaks (`SEARCH ANALYZER` → `FULLTEXT ANALYZER`, integer-literal KNN `<\|k,ef\|>`, single FULLTEXT index per field, `UPDATE ... LIMIT` prohibition, and CBOR `/rpc` requirement). |
| [`VS3-hermes-compliance.md`](./VS3-hermes-compliance.md) | `07-hermes-plugin.md` | Line-by-line inspection against Hermes Agent `v0.22.4` (`MemoryProvider` ABC, `PluginManager`, `tools/registry.py`). | Verified all 17 `MemoryProvider` lifecycle hooks, `spawn_context_thread` propagation, and `previous_content` curated memory mirroring. |
| [`VS4-rust-mcp-docker.md`](./VS4-rust-mcp-docker.md) | `11-rust-implementation-guide.md`, `06-api-and-mcp.md`, `Dockerfile`, `docker-compose.yml` | Compiled a working vertical slice (`cargo check`, `cargo test`, `cargo tree`) and built/booted the multi-stage Docker image on Docker 29.2.1. | Verified `#[rmcp::tool_router]` macros, `Router::nest_service("/mcp", ...)` routing, 218/245 crate counts, 7.41 MB stripped binary, and 584 MB / 140.76 MB gzipped container image. |
| [`VS5-coverage-quality.md`](./VS5-coverage-quality.md) | Full specification suite (`00`–`12`) vs [`../../../DISCOVERY_HANDOFF.md`](../../../DISCOVERY_HANDOFF.md) | Cross-document consistency, truth-maintenance state machines, and requirement traceability. | Identified 5 truth-maintenance edge cases (same-timestamp contest, authority guard, restatement conflict clearing, predecessor reopen on forget) and consolidation/outbox state refinements. |

### Round 2 — Deep Re-Verification After Architectural Refinements

| Report | Scope | What Was Empirically Tested | Key Outcome |
|---|---|---|---|
| [`VS1b-consistency-final.md`](./VS1b-consistency-final.md) | Cross-document invariant sweep across `00`–`12` | Automated and manual verification of all Round 1 fixes and CBOR RPC updates. | Confirmed resolution of all 18 Round 1 consistency findings across the specification package. |
| [`VS2b-storage-final.md`](./VS2b-storage-final.md) | CBOR `/rpc` wire protocol, `ciborium` tags, and updated `03`/`04`/`05` queries | Live Rust `reqwest` + `ciborium` client against `surrealdb/surrealdb:v3.3.4` (`POST /rpc` with `Accept: application/cbor`). | Proved JSON `/rpc` cannot coerce strings to `record<T>` or `null` to `NONE` in `SCHEMAFULL` tables; verified CBOR Tag 6 (`NONE`), Tag 8 (`RecordId`), and Tag 12 (`Datetime`) end-to-end. |

### Round 3 — Pre-Release Consistency & Executable Spec Audit

Prior to public release, a final 6-auditor cross-document and live SurrealDB `v3.3.4` execution pass further hardened:
- `fact.conflicts_with` as `array<record<fact>> DEFAULT []` so multiple competing claims are preserved without overwrite.
- Deterministic extract job lifecycle (`pending → running → completed | failed | dead`) with in-flight guard and post-commit re-arming (`Q-EXTRACT-JOB-UPSERT`, `Q-EXTRACT-JOB-COMPLETE`).
- CBOR `Option::None` → Tag 6 (`NONE`) and multi-statement transaction abort inspection in `store::rpc`.
- Full repository link hygiene (relative intra-repo links and commit/tag-pinned upstream citations).
