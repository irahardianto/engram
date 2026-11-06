# Engram — Research Reports & Verification Registry

**Status:** Completed & Corrected · **Date:** 2026-10-24 · **Owner:** Engram Core Architecture Team  
**Governing Architecture Decision Record:** [`docs/spec/00-decisions.md`](../spec/00-decisions.md)

This directory houses the seven foundational research reports produced during Engram's discovery and architecture definition phase, along with their corresponding forensic verification reports (under [`verification/`](verification)). 

On **2026-10-24**, all seven research reports underwent rigorous static code inspection, live container execution, and mathematical verification. Every **BLOCKER**, **MAJOR**, and **MINOR** finding was corrected in place. Claims are annotated using the following standard markers:
- `*(corrected)*`: A factual error, schema mistake, code defect, or mathematical formula corrected per the verification audit.
- `*(unverified)*`: A vendor claim or empirical benchmark that cannot be statically proven from open-source codebases or local execution.
- `*(superseded by 00-decisions.md ADR-xx)*`: An architectural proposal that has since been decided differently in Engram's canonical spec registry.

---

## 1. Master Research & Verification Index

| ID | Research Report | Verification Report | Scope & Subject | Verification Verdict | One-Line Summary |
|---|---|---|---|---|---|
| **01** | [`01-hindsight.md`](01-hindsight.md) | [`V01-hindsight.md`](verification/V01-hindsight.md) | Hindsight (`vectorize-io/hindsight`) | **PASS-WITH-FIXES** | Reverse-engineers Hindsight's 4-way hybrid retrieval, Alembic migration history, opinion purge, and bi-temporal intervals. |
| **02** | [`02-cognee.md`](02-cognee.md) | [`V02-cognee.md`](verification/V02-cognee.md) | Cognee (`topoteretes/cognee`) | **PASS-WITH-FIXES** | Analyzes Cognee's poly-store coordination, cross-store ACID consistency flaws, 21 search modes, and Uvicorn daemon constraints. |
| **03** | [`03-mem0.md`](03-mem0.md) | [`V03-mem0.md`](verification/V03-mem0.md) | Mem0 (`mem0ai/mem0`) | **PASS-WITH-FIXES** | Evaluates Mem0's v1 vs v2 transition from 2-call in-place mutation to single-pass additive extraction, sigmoid BM25, and degree damping. |
| **04** | [`04-hermes-integration.md`](04-hermes-integration.md) | [`V04-hermes-integration.md`](verification/V04-hermes-integration.md) | Hermes Agent (`v0.22.4`) | **PASS-WITH-FIXES** | Specifies the complete Python `MemoryProvider` contract, prefetch concurrency, turn persistence, and pre-compress checkpointing. |
| **05** | [`05-surrealdb.md`](05-surrealdb.md) | [`V05-surrealdb.md`](verification/V05-surrealdb.md) | SurrealDB (`v3.3.4`) | **PASS-WITH-FIXES** | Validates SurrealDB 3.x native multi-model capabilities: HNSW vector search, BM25 full-text, graph relations, and native `search::rrf()`. |
| **06** | [`06-rust-stack-deployment.md`](06-rust-stack-deployment.md) | [`V06-rust-stack-deployment.md`](verification/V06-rust-stack-deployment.md) | Rust Stack & Packaging | **PASS-WITH-FIXES** | Defines the Tokio/Axum 0.8/RMCP 3.7 stack, supervised all-in-one container packaging, and dependency budget management. |
| **07** | [`07-temporal-kg-and-evals.md`](07-temporal-kg-and-evals.md) | [`V07-temporal-kg-and-evals.md`](verification/V07-temporal-kg-and-evals.md) | Temporal KG & Evals | **PASS-WITH-FIXES** | Studies Graphiti's bi-temporal rules, SurrealDB Agent Memory tri-temporal model, LongMemEval/LoCoMo/BEAM benchmarks, and CI harness. |

---

## 2. Top Corrections per Report

### Report 01 — Hindsight Deep-Dive
- **Target:** [`01-hindsight.md`](01-hindsight.md) · **Audit:** [`verification/V01-hindsight.md`](verification/V01-hindsight.md)
1. **Recursive CTEs Refuted (MAJOR, F-01):** Hindsight does not execute recursive CTEs (`WITH RECURSIVE`). Graph expansion uses non-recursive CTEs with `CROSS JOIN LATERAL` for 1-hop expansion and an iterative Python BFS loop (`max_iterations = 5`) for temporal spreading. Bottlenecks stemmed from LATERAL join fan-outs, not CTE recursion.
2. **SurrealDB Index Syntax Corrected (MAJOR, F-02):** Replaced broken `MTREE` index recommendations with `HNSW DIMENSION <dim> DIST COSINE`, as SurrealDB 3.x throws syntax errors on `MTREE`.
3. **Reranker Formulas Corrected (MAJOR, F-03):** Replaced the uncalibrated $\tanh$ proof boost with the verified logarithmic formula $\text{proof\_norm} = \min(1.0, \max(0.0, 0.5 + \ln(\text{proof\_count}) / 10.0))$ and restored the omitted multiplicative `temporal_boost` term in final reranking.

### Report 02 — Cognee Deep-Dive
- **Target:** [`02-cognee.md`](02-cognee.md) · **Audit:** [`verification/V02-cognee.md`](verification/V02-cognee.md)
1. **In-Memory Graph Engine Discrepancy (MAJOR, F-01):** `brute_force_triplet_search` does not project subgraphs into NetworkX or run BFS; it instantiates `CogneeGraph` (a custom Python dictionary/list-backed structure subclassing `CogneeAbstractGraph`) and ranks edges using `heapq.nsmallest`.
2. **MCP Tool Catalog Registration for `improve` (MAJOR, F-02):** `cognee-mcp` exposes only 5 tools (`remember`, `recall`, `code_search`, `forget`, `cognify_status`). While `async def improve(...)` exists in `server.py`, it lacks the `@registry.tool(...)` decorator and is never exposed over MCP.
3. **Closer Worker Filename Correction (MINOR, F-03):** Replaced non-existent `out_of_band_closer.py` with the actual script `exit_watcher.py` (`python exit_watcher.py --state <path> [--final]`).

### Report 03 — Mem0 Architecture & Lessons
- **Target:** [`03-mem0.md`](03-mem0.md) · **Audit:** [`verification/V03-mem0.md`](verification/V03-mem0.md)
1. **Silently Discarded Extractions & Dead Code in OSS v2 (MAJOR, FIND-01):** Documented that while `ADDITIVE_EXTRACTION_PROMPT` prompts the LLM to output `linked_memory_ids`, the OSS v2.x codebase completely ignores this field during Phase 6 vector insertion (`main.py:1017-1041`), and `uuid_mapping` at `main.py:937-941` is unreferenced dead code.
2. **`Memory.search()` Return Type Inconsistency (MAJOR, FIND-02):** Corrected the return signature of core OSS `Memory.search()` to a flat `List[Dict[str, Any]]`. The dictionary envelope `{"results": [...]}` was used in v1 and remains in REST/Platform mode, but is not used in the core SDK.
3. **Restored Memory Types & Added Memory Export (MINOR, FIND-06):** Restored the full `MemoryType` enum definition (`SEMANTIC`, `EPISODIC`, `PROCEDURAL`) and documented Mem0's asynchronous background memory export capabilities (`create_memory_export`).

### Report 04 — Hermes Agent Integration
- **Target:** [`04-hermes-integration.md`](04-hermes-integration.md) · **Audit:** [`verification/V04-hermes-integration.md`](verification/V04-hermes-integration.md)
1. **Prefetch 1-Turn Lag & Cold-Start Blindness (BLOCKER, F-01):** Corrected the claim that `prefetch()` must only drain prior turn cache. Cache-only prefetch causes turn-1 blindness and 1-turn prompt lag. Because Hermes gives `prefetch()` an 8.0s timeout on a dedicated thread, Engram performs live recall under a tight deadline (~1500 ms) with cache fallback.
2. **Redundant Python SQLite Write Queue Dropped (MAJOR, F-02):** Dropped the internal SQLite queue in Python; Hermes already executes `sync_turn` on a serialized background thread (`mem-sync`, `DaemonThreadPoolExecutor(max_workers=1)`). Direct HTTP POST with local spool-on-failure is used instead.
3. **Memory Removal Drop Bug in `on_memory_write` (MAJOR, F-03):** Fixed a critical bug in `on_memory_write` where `if not content.strip(): return` silently dropped all memory removals, because Hermes passes removed text in `metadata["previous_content"]`.

### Report 05 — SurrealDB Deep-Dive
- **Target:** [`05-surrealdb.md`](05-surrealdb.md) · **Audit:** [`verification/V05-surrealdb.md`](verification/V05-surrealdb.md)
1. **Vector Dimension Mismatch in Query Proof (MAJOR, FIND-01):** Annotated query proof snippet to clarify that literal `[0.95, 0.05, 0.0, 0.0]` is a 4-dimensional mock vector requiring a 4-dim index, whereas production schema specifies `DIMENSION 1024`.
2. **BSL 1.1 Contagion of Rust SDK Crate (MAJOR, FIND-02):** Documented that the `surrealdb` Rust client SDK crate is licensed under BSL 1.1. To preserve a clean Apache-2.0 / MIT binary, ADR-02 decided to access SurrealDB over HTTP JSON-RPC (`POST /rpc` via `reqwest`) rather than linking the SDK crate.
3. **DiskANN Bounded RAM Claim Refuted (MAJOR, FIND-03):** Corrected claim regarding DiskANN bounded RAM caching; open issue #7337 shows it holds full graph and vector copies in process RAM in 3.3.4. Recommended HNSW exclusively for Engram.

### Report 06 — Rust Stack & Deployment
- **Target:** [`06-rust-stack-deployment.md`](06-rust-stack-deployment.md) · **Audit:** [`verification/V06-rust-stack-deployment.md`](verification/V06-rust-stack-deployment.md)
1. **Nonexistent Feature on `tokio-util` (BLOCKER, F-01):** Removed nonexistent `features = ["sync"]` on `tokio-util = "0.7.20"`, resolving a build-abort error.
2. **MCP Tool Routing & Handler Wiring Defect (MAJOR, F-02):** Corrected `rmcp 3.7.0` wiring from `#[rmcp::tool_router(router = engram_tools)]` to `#[rmcp::tool_router(server_handler)]`, which generates and exposes `list_tools()` and `call_tool()` implementations.
3. **Dependency Budget Understatement & Pruning (MAJOR, F-04):** Corrected crate count from prototype measurement of 341 crates to full master manifest count of 388 crates (28 over budget). Motivated ADR-16 dependency pruning (`figment`, `validator`, `backon`, `anyhow` in lib, and `surrealdb` SDK dropped to achieve ≤300 unique crates).

### Report 07 — Temporal KG & Evaluation Harness
- **Target:** [`07-temporal-kg-and-evals.md`](07-temporal-kg-and-evals.md) · **Audit:** [`verification/V07-temporal-kg-and-evals.md`](verification/V07-temporal-kg-and-evals.md)
1. **Defective MemoryAgentBench Citation (MAJOR, F-01):** Replaced unrelated medical vision citation `arXiv:2410.21000` with the real paper `arXiv:2507.05257` (Hu, Wang, McAuley et al., UCSD) and corrected the 4th competency from "Conflict Resolution" to *Selective Forgetting*.
2. **SurrealDB Agent Memory Vector Substrate (`MTREE` -> `HNSW`) (MAJOR, F-02):** Replaced legacy `MTREE Index` label in architecture diagram with `HNSW Index (COSINE)` to match SurrealDB Agent Memory specification (`recall.md`).
3. **Benchmark Score and Scale Corrections (MINOR, F-03, F-04, F-05):** Corrected Zep LongMemEval headline score from 71.4% to published 71.2% (arXiv:2501.13956), clarified LoCoMo scale (conversations spanning up to 35 sessions each), and distinguished LongMemEval's 5 cognitive abilities from its 7 question types.

---

## 3. Architectural Evolution & Spec Authority

The research reports represent the empirical discovery and reverse-engineering phase. Following their completion and verification, high-level architecture decisions were formally ratified in [`docs/spec/00-decisions.md`](../spec/00-decisions.md). In any instance where a research report's initial proposal differs from `00-decisions.md`, **the decision record is the authoritative single source of truth**.

Key ratifications include:
- **Topology (ADR-01):** Single Rust binary exposing REST (`/v1/...`), MCP Streamable HTTP (`/mcp`), and Prometheus (`/metrics`) on port 8080.
- **SurrealDB Client (ADR-02):** HTTP JSON-RPC (`POST /rpc` via `reqwest`) rather than `surrealdb` client SDK crate, preserving permissive licensing (BSL-1.1 avoidance).
- **Packaging (ADR-03):** All-in-one Docker image (`debian:bookworm-slim` + `tini` + `engram` + official `surreal` binary) with internal supervised loopback on `127.0.0.1:8000`.
- **Storage Engine (ADR-04):** RocksDB default (`rocksdb:///data/surreal`), logical export as backup/upgrade format.
- **Tenancy (ADR-05):** One SurrealDB database per memory bank (`ns: engram, db: <bank_id>`).
- **Embeddings & LLM (ADR-06, ADR-07):** Default `qwen3-embedding:0.6b` (1024 dims) and `qwen3:8b` via Ollama/OpenAI-compatible HTTP endpoints; single structured LLM extraction call per turn batch.
- **Truth Maintenance (ADR-08, ADR-09):** Deterministic code reconciliation over closed 15-predicate vocabulary; soft bi-temporal retirement (`valid_to = now`, `contested = true`, `contradiction_of`), immutable episodes.
- **Retrieval Pipeline (ADR-11):** Parallel vector, BM25, and 1-hop graph expansion; weighted RRF in Rust; MMR diversity; token-budget packing.
- **Hermes Plugin (ADR-13):** Thin Python client using pinned `httpx`; live recall prefetch with fallback; direct background `sync_turn` with spool-on-failure; mirror built-in `MEMORY.md`/`USER.md`.
- **Dependency Budget (ADR-16):** ≤300 unique crates; MSRV 1.88; Edition 2024.
