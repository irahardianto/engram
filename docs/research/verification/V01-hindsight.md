# Verification Report: R1 Hindsight Deep-Dive (V01-hindsight)

**Target Document:** [`docs/research/01-hindsight.md`](../01-hindsight.md)  
**Verification Date:** October 24, 2026  
**Verifier:** Independent Principal Engineer Verifier  
**Primary Sources Checked:**
- Local repository clone: `vectorize-io/hindsight`
- Hermes Agent codebase & catalog: `~/.hermes/hermes-agent/plugin-catalog/hindsight.yaml`, `~/.hermes/hermes-agent/agent/`
- Executable test against SurrealDB: Docker container `surrealdb/surrealdb:latest` (v3.3.4)
- Context & Requirements: [`DISCOVERY_HANDOFF.md`](../../../DISCOVERY_HANDOFF.md)

---

## 1. Summary Verdict

### **Verdict: PASS-WITH-FIXES**

The research report [`01-hindsight.md`](../01-hindsight.md) is an exceptionally thorough, high-fidelity reverse-engineering of Hindsight's architecture. Its analysis of the Alembic migration history, Pydantic extraction schemas, prompt texts, Hermes integration lifecycle, and benchmark methodology is substantially corroborated by primary code sources.

However, the report contains **three MAJOR technical inaccuracies** and several **MINOR factual discrepancies** that must be corrected before using this report as the blueprint for Engram's PRD and implementation:

1. **[MAJOR] Recursive CTEs Claim is Factually Inaccurate:** The report repeatedly claims Hindsight uses "massive recursive CTEs" causing query planner failure. In reality, Hindsight's graph link expansion uses **non-recursive CTEs with `CROSS JOIN LATERAL`** for 1-hop seed expansion, and an iterative **Python BFS loop** (`max_iterations = 5`) for multi-hop temporal/causal spreading. There is zero `WITH RECURSIVE` in Hindsight's graph query paths.
2. **[MAJOR] Broken SurrealDB Index Recommendation (`MTREE` vs `HNSW`):** The report recommends `DEFINE INDEX ... MTREE DIMENSION 1024` for SurrealDB vector search. When executed against modern SurrealDB (v3.3.4), `MTREE` throws a syntax parse error (`Unexpected token 'an identifier', expected Eof`). Modern SurrealDB requires `HNSW` (`DEFINE INDEX ... HNSW DIMENSION ... DIST COSINE`).
3. **[MAJOR] Reranking Formula & Proof Count Mathematical Errors:** The report claims Proof Count Boost is computed as $1.0 + \alpha \times \tanh(\text{proof\_count} \times 0.2)$. In reality, `proof_norm` is computed logarithmically: $\min(1.0, \max(0.0, 0.5 + \ln(\text{proof\_count}) / 10.0))$, and the boost is $1.0 + \alpha \times (\text{proof\_norm} - 0.5)$. Furthermore, the report's final score formula omitted the multiplicative `temporal_boost`.

---

## 2. Findings Table

| ID | Severity | Location in R1 | Claim in R1 | Evidence from Code / Execution | Recommended Fix |
|---|---|---|---|---|---|
| **F-01** | **MAJOR** | §10.1 (L628-632), §11 (L656), §0 (L16) | Hindsight multi-hop graph expansion uses "massive recursive CTEs" that crash PostgreSQL query planners. | `grep -rn "WITH RECURSIVE"` finds no recursive CTEs in graph retrieval. `link_expansion.py:336-344` and `ops_postgresql.py:982-1015` show non-recursive CTEs with `CROSS JOIN LATERAL` (1-hop). Multi-hop spreading is executed in Python (`recall.py:578-587`) via BFS loop (`max_iterations=5`). | Correct text: Hindsight uses non-recursive CTEs with `CROSS JOIN LATERAL` for 1-hop expansion and Python BFS for temporal spreading. State accurately that LATERAL join fan-outs—not recursive CTEs—prompted the timeout and fallback. |
| **F-02** | **MAJOR** | §11 Matrix (L654, L665), Draft Schema (§2.1 / Handoff §6.4) | Recommends SurrealDB `MTREE` index for vector k-NN: `DEFINE INDEX ... MTREE DIMENSION 1024`. | Executing SurrealQL against `surrealdb/surrealdb:latest` (v3.3.4) fails: `Parse error: Unexpected token 'an identifier', expected Eof` on `MTREE`. SurrealDB 2.x/3.x uses `HNSW` (`DEFINE INDEX ... HNSW DIMENSION <dim> DIST COSINE`). | Update all SurrealQL schema definitions and recommendations to use `HNSW DIMENSION <dim> DIST COSINE`. |
| **F-03** | **MAJOR** | §4.3 (L451-452) | Proof Count Boost is $1.0 + \alpha \times \tanh(\text{proof\_count} \times 0.2)$, and Final Score is $\text{BaseScore} \times \text{RecencyBoost} \times \text{ProofCountBoost}$. | In `reranking.py:287-305`, `proof_norm = min(1.0, max(0.0, 0.5 + (math.log(proof_count) / 10.0)))`, `proof_count_boost = 1.0 + alpha * (proof_norm - 0.5)`. Also, `combined_score` includes `temporal_boost = 1.0 + temporal_alpha * (sr.temporal - 0.5)`. | Correct mathematical formulas in §4.3 to reflect the logarithmic centering and include the `temporal_boost` term. |
| **F-04** | **MINOR** | §11 Matrix (L663) | Recommends in-process ONNX cross-encoder reranking in Rust via `ort` crate. | `DISCOVERY_HANDOFF.md` specifies a "lean production-grade Rust service, minimal dependencies". Adding `ort` links heavy C++ shared libraries (`libonnxruntime.so` >100MB), complicates musl/aarch64 builds, and inflates memory. Hindsight's own Dockerfile explicitly chose NOT to bundle ONNX Runtime in standalone images. | Recommend delegating cross-encoder reranking to external endpoints (TEI / Ollama / FastEmbed service) or keeping `ort` strictly behind an optional Cargo feature flag. |
| **F-05** | **MINOR** | §2.2 (L265) | `SET LOCAL hnsw.max_scan_tuples = 5000; (_vector_index.py:136-143)`. | In `_vector_index.py:141`, `hnsw.max_scan_tuples` is set to `""` dynamically. The actual default in `config.py:1625` is `DEFAULT_ANN_MAX_SCAN_TUPLES = 4000`, not 5000. | Change `5000` to `4000` (from `config.py:1625`). |
| **F-06** | **MINOR** | §4.1 (L424) | Semantic graph seed selection threshold defaults to $\ge 0.5$. | In `config.py:1422` and `link_expansion.py:57`, `DEFAULT_GRAPH_SEED_MIN_SIMILARITY = 0.3`, not 0.5. (0.5 is the saturation scale in `math.tanh(row["score"] * 0.5)`). | Change seed threshold from $\ge 0.5$ to $\ge 0.3$. |
| **F-07** | **MINOR** | §4.4 (L455) | Recalled candidates trimmed using `tiktoken/tokenizers (token_encoding.py:1-80)`. | `token_encoding.py:10-53` explicitly documents why `tiktoken` was purged and replaced with `toktok` (compiled vocabulary, 2-7x faster, zero heap allocation, immune to `<|endoftext|>` HTTP 500 crashes). | Note that Hindsight replaced `tiktoken` with `toktok`. |
| **F-08** | **MINOR** | §6.2 (L528) | "Hindsight exposes 36 tools over MCP". | `mcp_tools.py:45-87` explicitly registers 39 tools in `_ALL_TOOLS`. The 8 bullet categories in §6.2 actually sum to 39 tools ($5+7+3+5+3+7+6+3=39$). | Correct count to 39 tools. |
| **F-09** | **NIT** | §4.1 (L419) | Cosine similarity floor 0.1 cited at `config.py:101-103`. | `config.py:101-103` defines the `hierarchical()` helper. The constant is at `config.py:1423` (`DEFAULT_TEMPORAL_SEMANTIC_MIN_SIMILARITY = 0.1`). | Fix line citation to `config.py:1423`. |
| **F-10** | **NIT** | §4.2 (L442) | Cited `config.py:DEFAULT_RRF_K = 60`. | Constant `DEFAULT_RRF_K` does not exist in `config.py`. It is a default parameter `k: int = 60` in `fusion.py:29`. | Fix citation to `fusion.py:29`. |
| **F-11** | **NIT** | §1.1 (L25) | Cited `hindsight_api/engine/response_models.py:12-25` for disposition traits. | Lines 12-25 define `Budget`. The `DispositionTraits` model is defined at lines 270-285. | Fix line citation to `response_models.py:270-285`. |
| **F-12** | **NIT** | §7.2 (L565) | Cited `__init__.py:2150-2200` for `on_memory_write()`. | In `hindsight-integrations/hermes/__init__.py`, `on_memory_write` is located at lines 2054-2076. | Fix line citation to `__init__.py:2054-2076`. |
| **F-13** | **NIT** | §1.1 (L26) | Cited path `hindsight_dev/generate_bank_template_schema.py:1-40`. | Actual repository path is `hindsight-dev/hindsight_dev/generate_bank_template_schema.py`. | Fix path prefix. |
| **F-14** | **NIT** | §2.2 (L270) | Cited `entity_resolver.py:53-55` for `CREATE INDEX idx_entities_canonical_name_trgm`. | The index is created in Alembic migrations `b3e8d1c6f4a9` and `7c2e5a9d1f40` on `LOWER(canonical_name)`. Line 53-55 of `entity_resolver.py` is only a docstring comment. | Cite the Alembic migrations `b3e8d1c6f4a9` / `7c2e5a9d1f40`. |

---

## 3. High-Priority Requirement Verification

### 3.1 Migration `g2h3i4j5k6l7` (Purge of Opinions & Confidence Scores)
- **Status:** **VERIFIED (Exact Code Match)**
- **File Location:** [`hindsight-api-slim/hindsight_api/alembic/versions/g2h3i4j5k6l7_remove_opinion_fact_type.py`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/alembic/versions/g2h3i4j5k6l7_remove_opinion_fact_type.py#L1-L55)
- **Create Date:** 2026-04-02
- **Direct Code Quote:**
  ```python
  def _pg_upgrade() -> None:
      schema = _get_schema_prefix()

      # 1. Delete any remaining opinion rows
      op.execute(f"DELETE FROM {schema}memory_units WHERE fact_type = 'opinion'")

      # 2. Drop opinion-specific indexes
      op.execute(f"DROP INDEX IF EXISTS {schema}idx_memory_units_opinion_confidence")
      op.execute(f"DROP INDEX IF EXISTS {schema}idx_memory_units_opinion_date")

      # 3. Drop confidence_score constraints and column (only used for opinions, always NULL otherwise)
      op.execute(f"ALTER TABLE {schema}memory_units DROP CONSTRAINT IF EXISTS confidence_score_fact_type_check")
      op.execute(f"ALTER TABLE {schema}memory_units DROP CONSTRAINT IF EXISTS memory_units_confidence_score_check")
      op.execute(f"ALTER TABLE {schema}memory_units DROP COLUMN IF EXISTS confidence_score")

      # 4. Replace fact_type CHECK constraint
      op.execute(f"ALTER TABLE {schema}memory_units DROP CONSTRAINT IF EXISTS memory_units_fact_type_check")
      op.execute(
          f"ALTER TABLE {schema}memory_units ADD CONSTRAINT memory_units_fact_type_check "
          f"CHECK (fact_type IN ('world', 'experience', 'observation'))"
      )
  ```
- **Architectural Significance for Engram:** Corroborates the decision to reject ungrounded floating-point confidence scores on subjective opinions in favor of structured proof counts (`proof_count`) and explicit evidence links (`evidence` / `source_memory_ids`).

---

### 3.2 Data Model & PostgreSQL Extensions
- **Status:** **VERIFIED (With Discrepancy Noted)**
- **Tables Present in Migrations:**
  - Core: `banks`, `documents`, `chunks`, `memory_units`, `invalidated_memory_units`, `entities`, `unit_entities`, `entity_cooccurrences`, `memory_links`, `mental_models`, `directives`, `async_operations`.
  - **Observations:** No separate `observations` table exists in PostgreSQL. Observations are stored directly in `memory_units` with `fact_type = 'observation'`. Evidence tracking uses native PostgreSQL arrays: `source_memory_ids UUID[]` (migration `k6l7m8n9o0p1` explicitly made junction table `observation_sources` an Oracle-only fallback).
- **Postgres Extensions Managed:**
  - Verified in [`hindsight-api-slim/hindsight_api/_pg_extensions.py:38-49`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/_pg_extensions.py#L38-L49):
    `MANAGED_EXTENSIONS = ("vector", "vectorscale", "vchord", "alloydb_scann", "pg_trgm", "btree_gin", "vchord_bm25", "pg_textsearch", "pg_search", "pgroonga")`.
  - Required baseline: `vector`, `pg_trgm`, `btree_gin`.
  - Lexical alternatives: ParadeDB `pg_search`, VectorChord `vchord_bm25`, PGroonga `pgroonga`, or native `tsvector`.

---

### 3.3 Retain Pipeline
- **Status:** **VERIFIED (Exact Code Match)**
- **Pydantic Extraction Models:** Verified in [`fact_extraction.py:269-315`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/retain/fact_extraction.py#L269-L315).
  - 5W fields: `what`, `when`, `where`, `who`, `why`.
  - Categorization: `fact_kind: Literal["event", "conversation"]`, `fact_type: Literal["world", "assistant"]`.
  - Causality: `causal_relations: list[FactCausalRelation] | None` with `target_index < current_index` and `relation_type = 'caused_by'`.
  - Attachments: `from_attachments: list[int] | None`.
- **Extraction Prompt:** Verified in [`fact_extraction.py:1066-1185`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/retain/fact_extraction.py#L1066-L1185). Direct match for coreference rules, conciseness instructions, and coarse date handling.
- **Temporal Normalization:** Verified in [`fact_extraction.py:97-133`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/retain/fact_extraction.py#L97-L133) (`_infer_temporal_date`).
- **Entity Resolution Algorithm:** Verified in [`entity_resolver.py:122-150, 190-201, 219-300, 1290-1353`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/memories/pg/entity_resolver.py#L1290-L1353):
  - In-batch dedup threshold: `0.5` (`_find_intrabatch_similar_pairs`), capped at `_INTRABATCH_MAX_NAMES = 250`.
  - Trigram candidate cutoff: `DEFAULT_ENTITY_TRGM_SIMILARITY_THRESHOLD = 0.3` (`config.py:2017`).
  - Token compatibility gate: `_tokens_are_compatible` (word subset and number collision check).
  - Multi-signal composite score formula:
    $$\text{Score} = (\text{NameSim} \times 0.5) + (\text{Cooccurrence} \times 0.3) + (\text{Temporal} \times 0.2)$$
  - Hub damping: $\text{weight} = 1.0 / \sqrt{\max(\text{degree}, 1)}$.
  - Merge decision threshold: `round(best_score, 6) >= 0.6`.

---

### 3.4 Recall Pipeline
- **Status:** **VERIFIED (With Parameter Corrections)**
- **The 4 Strategies:**
  1. Dense vector: partial HNSW per fact_type, floor 0.1 (`config.py:1423`).
  2. Sparse BM25: `ts_rank_cd(search_vector, to_tsquery('english', $tokens))` with OR tokens (`postgresql.py:429-432, 478`).
  3. Graph expansion: seeds up to `GRAPH_SEED_LIMIT = 20` (`base.py:800`), seed threshold is **0.3** (`config.py:1422`, not 0.5 as reported in F-06). Expansion intra-score: $\tanh(\text{count} \times 0.5) + \text{semantic} + \text{causal} \in [0, 3]$ (`link_expansion.py:233-266`).
  4. Temporal spreading: `_TEMPORAL_POOL_SIZE = 60`, `_TEMPORAL_COVERAGE_BUCKETS = 8`, `_TEMPORAL_ENTRY_POINTS = 10`, round-robin bucket selection (`recall.py:310-380`). BFS decay $= 0.7$, causal boost $= 2.0$ for `causes`/`caused_by` and $1.5$ for `enables`/`prevents` (`recall.py:317-318`). Max BFS iterations $= 5$ (`recall.py:586`).
- **Fusion:** RRF with $k = 60$ (`fusion.py:29`).
- **Cross-Encoder Reranker:** Default local model `cross-encoder/ms-marco-MiniLM-L-6-v2` (`config.py:1383`). Recency decay half-life 90 days. Multiplicative adjustments centered at $0.5$ with $\alpha_{\text{recency}} = 0.2$, $\alpha_{\text{temporal}} = 0.2$, $\alpha_{\text{proof}} = 0.1$. Proof normalization is logarithmic $\min(1.0, \max(0.0, 0.5 + \ln(\text{proof\_count}) / 10.0))$ (corrected in F-03).

---

### 3.5 Reflect Loop & Consolidation
- **Status:** **VERIFIED (Exact Code Match)**
- **Reflect Tools:** Verified in [`reflect/tools.py:134-591`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/reflect/tools.py#L134-L591) and [`tools_schema.py:1-60`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/reflect/tools_schema.py#L1-L60):
  - `search_mental_models` (curated summaries first)
  - `read_mental_models` (read full text of snippet hits)
  - `search_observations` (consolidated knowledge with freshness/staleness)
  - `recall` (raw world/experience facts ground truth)
  - `expand` (multi-hop graph inspection)
- **Disposition Traits:** `skepticism`, `literalism`, `empathy` (integers 1–5, default 3) verified in [`response_models.py:270-285`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/response_models.py#L270-L285) and migration `e0a1b2c3d4e5`.
- **Consolidation Trigger:** `enable_auto_consolidation` (default true) triggers background consolidation after retain (`memory_engine.py:7268`). Dedup threshold is `0.97` (`config.py:1927`). Rules 1, 2, 4, 7, 8, 10 verified in [`consolidation/prompts.py:55-80`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/consolidation/prompts.py#L55-L80).

---

### 3.6 API Surface & Hermes Agent Provider
- **Status:** **VERIFIED (Exact Code Match)**
- **Endpoints:** Verified in [`api/http.py:4780-6600`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/api/http.py#L4780-L6600).
- **MCP Tools:** 39 tools registered in `_ALL_TOOLS` ([`mcp_tools.py:45-87`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/mcp_tools.py#L45-L87)).
- **Hermes Provider:** Verified in [`hindsight-integrations/hermes/__init__.py:1-2266`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-integrations/hermes/__init__.py#L1-L2266):
  - Modes: `cloud`, `local_external`, `local_embedded` (`__init__.py:524-536`).
  - `is_available()`: pure config check, no network (`__init__.py:594-608`).
  - `queue_prefetch()`: spawns `spawn_context_thread(_run, name="hindsight-prefetch")` (`__init__.py:1807-1832`).
  - `prefetch()`: joins prefetch thread with 3.0s ceiling, serves cached markdown (`__init__.py:1788-1800`).
  - `sync_turn()`: non-blocking queue push to single writer thread (`__init__.py:1987-2053`).
  - `recall_status()`: returns `RecallStatus(provider_label="Hindsight", count=N, glyph="⟐")` (`__init__.py:1801-1805`).
  - `on_memory_write()`: mirrors built-in `MEMORY.md` and `USER.md` writes (`__init__.py:2054-2076`).

---

### 3.7 Deployment & Embedded PostgreSQL (`pg0`)
- **Status:** **VERIFIED (Exact Code Match)**
- **All-in-One Docker Image:** Verified in [`docker/standalone/Dockerfile:1-462`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/docker/standalone/Dockerfile#L1-L462) and [`start-all.sh`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/docker/standalone/start-all.sh):
  - Base: `python:3.11-slim` with multi-stage builds.
  - Bundles: FastAPI backend, Next.js Control Plane (port 9999), and embedded Postgres (`pg0-embedded`).
  - ML Models: Pre-downloads HuggingFace models `BAAI/bge-small-en-v1.5` and `cross-encoder/ms-marco-MiniLM-L-6-v2` during Docker build (`Dockerfile:409-433`).
  - Runtime: Runs rootless as `hindsight` user (UID 1000). Data stored in `/home/hindsight/.pg0`.
  - Startup: `start-all.sh` verifies `.pg0` volume permissions and runs Alembic migrations automatically on startup.
- **Slim Image:** `hindsight-api-slim` excludes `local-ml` dependencies (~300MB image) and requires external TEI/OpenAI/Cohere endpoints.

---

### 3.8 Hindsight Weaknesses: Evidence-Based vs Speculative Analysis
- **10.1 "Recursive CTEs causing planner overhead and OOM":**
  - **PARTIALLY SPECULATIVE / MISCHARACTERIZED.** The claim that Hindsight uses "recursive CTEs" is technically false (see Finding F-01). However, the underlying vulnerability—query planner instability under high-fanout entity self-joins—is **evidence-based**: `link_expansion.py:349-366` contains explicit `asyncio.wait_for(..., timeout=config.link_expansion_timeout)` falling back to semantic+causal expansion when entity expansion times out.
  - The OOM claim is **100% evidence-based**: [`links.py:97-101`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/memories/pg/links.py#L97-L101) directly quotes bug `#3848` where 36K unconstrained temporal link candidates produced 1.3 billion tuples, killing worker processes.
- **10.2 "Asynchronous Retain & Read-After-Write Hazards":**
  - **100% EVIDENCE-BASED.** Corroborated by [`hermes/__init__.py:1820-1823`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-integrations/hermes/__init__.py#L1820-L1823) (`_wait_for_retains_drained`). Fast successive turns race against asynchronous server-side ingestion.
- **10.3 "Poly-Extension Fragility":**
  - **100% EVIDENCE-BASED.** Corroborated by [`_pg_extensions.py:1-20`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/_pg_extensions.py#L1-L20) and issue `#4118` (search_path tenant pollution breaking trigram operators).
- **10.4 "Double LLM Tax Per Turn":**
  - **100% EVIDENCE-BASED.** Retain LLM call (`fact_extraction.py`) plus immediate background auto-consolidation LLM call (`consolidator.py`).

---

### 3.9 Engram Recommendations Evaluation
1. **SurrealDB Vector Index Type (CRITICAL DEFECT):**
   - The report recommends `MTREE` (`DEFINE INDEX ... MTREE DIMENSION 1024`).
   - **Technical Reality:** SurrealDB 3.x (and 2.x) does **not** use MTREE. Executing this syntax in `surrealdb/surrealdb:latest` results in a fatal parse error. SurrealDB requires `HNSW`:
     ```surql
     DEFINE INDEX entity_vec ON entity FIELDS embedding HNSW DIMENSION 1024 DIST COSINE;
     ```
2. **In-Process ONNX Reranker (ARCHITECTURAL MISALIGNMENT):**
   - The report recommends `ort` (ONNX Runtime) in Rust for local cross-encoder reranking.
   - **Technical Reality:** Embedding `ort` contradicts Engram's core architectural goal: "lean production-grade Rust service, minimal dependencies". ONNX Runtime links large dynamic C++ libraries (`libonnxruntime.so` >100MB), complicates cross-compiling static Linux binaries, and increases idle memory RSS.
   - **Recommended Engram Architecture:** Follow Hindsight's slim architecture: keep Engram's core Rust binary pure and lightweight; delegate embeddings and reranking to local HTTP endpoints (e.g. Ollama, TEI, or an external micro-service). If local ONNX is supported, place it strictly behind a non-default Cargo feature flag (`--features local-onnx`).

---

## 4. Verified-Correct Claims (Inventory)

The following load-bearing claims in [`01-hindsight.md`](../01-hindsight.md) were verified and confirmed against primary code sources:

1. **Purge of Opinions:** Migration `g2h3i4j5k6l7` (2026-04-02) completely dropped `opinion` from `fact_type` check constraints, deleted opinion rows, dropped opinion indexes, and dropped `confidence_score` column.
2. **Rename of Terminology:** Migration `t5o6p7q8r9s0` renamed `mental_model` fact type to `observation`, and renamed `reflections` table to `mental_models`.
3. **Core Database Schemas:** Table definitions and constraints for `banks`, `documents`, `chunks`, `memory_units`, `invalidated_memory_units`, `entities`, `unit_entities`, `entity_cooccurrences`, `memory_links`, `mental_models`, `directives`, and `async_operations` match migrations.
4. **Bi-Temporal Timestamps:** `occurred_start`, `occurred_end`, `mentioned_at`, `event_date`, and `updated_at` accurately represent the world-validity vs transaction-time split.
5. **Extraction Prompt & JSON Schemas:** 5W extraction schema, Pydantic models, conciseness rules, coreference resolution, coarse date handling (spanning whole calendar period), and relative date normalization regex (`_infer_temporal_date`) match `fact_extraction.py`.
6. **Entity Resolution Scoring:** Bounded intrabatch join at 250 names, trigram floor 0.3, token compatibility gate, 0.5/0.3/0.2 composite weights, hub damping $1/\sqrt{\text{degree}}$, and 0.6 rounded merge threshold match `entity_resolver.py`.
7. **Temporal Coverage Selection:** 8 buckets, 10 entry points, 60 pool size, round-robin tier selection match `recall.py:310-380`.
8. **Link Decay & Causal Multipliers:** Per-hop temporal decay 0.7, causal boost 2.0 (`causes`/`caused_by`) and 1.5 (`enables`/`prevents`) match `recall.py:317-318`.
9. **Reciprocal Rank Fusion:** Formula $1 / (k + \text{rank})$ with $k = 60$ matches `fusion.py:29`.
10. **Reflect Tool Hierarchy:** `search_mental_models`, `read_mental_models`, `search_observations`, `recall`, `expand` match `reflect/tools.py`.
11. **Disposition Traits:** `skepticism`, `literalism`, `empathy` on 1–5 integer scale defaulting to 3 match `response_models.py` and migration `e0a1b2c3d4e5`.
12. **Consolidation Prompt Rules:** Rules 1, 2, 4, 7, 8, 10 match `consolidation/prompts.py:55-80`.
13. **Hermes Integration Lifecycle:** Non-blocking `sync_turn` queue, background `queue_prefetch` with `spawn_context_thread`, cached `prefetch` join with 3.0s ceiling, `RecallStatus` format, and `on_memory_write` mirroring match `hermes/__init__.py`.
14. **Standalone Docker Pattern:** Multi-stage Dockerfile bundling backend, control plane, preloaded sentence-transformers models, and rootless `pg0-embedded` matches `docker/standalone/Dockerfile`.
15. **Benchmark Citations:** 94.6% on LongMemEval-s, 92.0% on LoCoMo, and 64.1% on BEAM (10M tokens) match published findings in `2026-03-23-agent-memory-benchmark.mdx` and `2026-10-13-memlake.md`.

---

## 5. Unverifiable Items

1. **Independent Verification of 64.1% BEAM at 10M Tokens Benchmark:** The score is verified as an official claim published in Hindsight's official technical blog post ([`2026-10-13-memlake.md:53`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-docs/blog/2026-10-13-memlake.md#L53)), but reproducing the 10-million-token evaluation run requires massive GPU/cloud infrastructure outside the scope of this static code verification.

---

## 6. Actionable Recommendations for Engram Authoring

Before authoring Engram's PRD and SurrealQL schemas:
1. **Replace `MTREE` with `HNSW`:** Update all schema templates to `HNSW DIMENSION <dim> DIST COSINE`.
2. **Clarify Graph Traversal Architecture:** In the architecture comparison, accurately note that Hindsight's graph query bottlenecks stemmed from **relational self-joins with `CROSS JOIN LATERAL` fan-outs**, not recursive CTEs. Emphasize that SurrealDB eliminates relational self-joins entirely via pointer-based graph edges (`SELECT ->asserts[WHERE valid_to IS NONE]->entity.* FROM $seeds`).
3. **Decouple ML Dependencies from Engram Core:** Maintain a single, lean Rust binary. Do not bundle heavy ONNX Runtime or PyTorch bindings into the core engine. Interface with embeddings and cross-encoders via HTTP APIs (Ollama / TEI / OpenAI-compatible).
4. **Adopt Exact Reranking Boost Logic:** When implementing hybrid fusion and reranking in Rust (`engram-core/src/retrieval/rerank.rs`), implement the verified multiplicative boost structure:
   $$\text{FinalScore} = \text{Score}_{\text{base}} \times [1 + \alpha_r (\text{recency} - 0.5)] \times [1 + \alpha_t (\text{temporal} - 0.5)] \times [1 + \alpha_p (\text{proof\_norm} - 0.5)]$$
   with logarithmic proof normalization.
