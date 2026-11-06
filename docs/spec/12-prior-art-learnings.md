# Engram Specification: Prior Art Learnings & Architectural Lineage

**Document:** `docs/spec/12-prior-art-learnings.md`  
**Status:** Accepted (v1 baseline) · **Date:** 2026-10-24 · **Author:** Engram Core Architecture Team  
**Governing Standard:** [`docs/spec/00-decisions.md`](00-decisions.md) (ADR-01 through ADR-19)  
**Primary Research Inputs:** `docs/research/01..07-*.md` and Verification Audits `docs/research/verification/V01..V07-*.md`  
**Target Audience:** Systems engineers, database architects, and AI agent runtime implementers

---

## 1. System Profiles

This section establishes concise technical baselines for the seven memory architectures analyzed during Engram's discovery. Each profile captures the system's core architecture, underlying storage engines, consistency guarantees, Hermes Agent integration status, and production maturity.

### 1.1 Hindsight (Vectorize.io)
Hindsight is an agent memory engine built around a multi-tier pipeline separating raw interaction units from synthesized observations and directives ([`docs/research/01-hindsight.md`](../research/01-hindsight.md) §1.1). Storage relies on PostgreSQL with a suite of C-extensions (`vector`, `pg_trgm`, `btree_gin`, and optional lexical accelerators; [`_pg_extensions.py:38-49`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/_pg_extensions.py#L38-L49)). Graph relationships are modeled relationally through link tables (`memory_links`) and traversed via non-recursive `CROSS JOIN LATERAL` queries combined with an iterative Python BFS loop (`recall.py:578-587`; [`docs/research/verification/V01-hindsight.md`](../research/verification/V01-hindsight.md) §2 F-01). Consistency within PostgreSQL is transactional, but asynchronous write-behind retain operations introduce read-after-write hazards during rapid multi-turn conversations (`hermes/__init__.py:1820-1823`). Its Hermes integration is fully functional across cloud, local external, and local embedded (`pg0`) modes (`plugin-catalog/hindsight.yaml`). Hindsight demonstrates high algorithmic maturity, achieving headline benchmark scores of 94.6% on LongMemEval-s and 64.1% on BEAM 10M, but its storage architecture relies on SQL joins emulating graph edges.

### 1.2 Cognee (Topoteretes)
Cognee is an ingestion and retrieval coordinator designed to construct knowledge graphs from multi-modal documents and agent sessions ([`docs/research/02-cognee.md`](../research/02-cognee.md) §1.1). It functions as a poly-store coordinator, driving three distinct database layers in parallel: relational ledgers (SQLAlchemy with SQLite or PostgreSQL), graph stores (Neo4j, FalkorDB, Kùzu/Ladybug, or Neptune), and vector databases (LanceDB, Qdrant, or PGVector). Because writes span multiple independent engines without a two-phase commit (2PC) coordinator, partial pipeline failures leave orphaned graph nodes and phantom vector entries ([`add_data_points.py:325-336`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py#L325-L336); [`docs/research/verification/V02-cognee.md`](../research/verification/V02-cognee.md) §2 Priority 3). Local embedded storage locks forced the Hermes provider (`plugin-catalog/cognee.yaml`) to run a background Uvicorn daemon on port 8011 (`server_bootstrap.py`, `exit_watcher.py`). While Cognee (v1.6.5) features 21 distinct search modes in its `SearchType` enum, its heavy write path (2 LLM calls and 4 embeddings per chunk; `estimator.py:62-75`) and post-hoc contradiction handling impose significant operational overhead.

### 1.3 Mem0
Mem0 is a vector-centric agent memory layer focused on rapid extraction and search of personal and semantic facts ([`docs/research/03-mem0.md`](../research/03-mem0.md) §1.1). In release v2.0.0 (PR #4805, April 2026), Mem0 deprecated and deleted over 4,000 lines of external graph database drivers (`mem0/graphs/`, `graph_memory.py`, Neo4j, Kùzu, Memgraph; [`docs/changelog/sdk.mdx:398`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/docs/changelog/sdk.mdx#L398)), moving entirely to a single-pass additive pipeline (`ADDITIVE_EXTRACTION_PROMPT`; [`prompts.py:468-944`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/configs/prompts.py#L468-L944)) backed by 26 vector stores alongside SQLite history tables (`storage.py:108-142`). While the extraction prompt instructs the LLM to output `linked_memory_ids`, the OSS v2.x ingestion engine silently discards this field and leaves `uuid_mapping` as dead code ([`main.py:1017-1041`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L1017-L1041); [`docs/research/verification/V03-mem0.md`](../research/verification/V03-mem0.md) §2 FIND-01). The Hermes integration (`plugin-catalog/mem0.yaml`) applies a 450-character message truncation cap and a 3-second thread block on prefetch. Mem0 is widely adopted and fast, but treats memory as flat text statements rather than an interconnected world model.

### 1.4 Graphiti / Zep
Graphiti is Zep's open-source temporal knowledge graph engine ([arXiv:2501.13956](https://arxiv.org/abs/2501.13956); [`docs/research/07-temporal-kg-and-evals.md`](../research/07-temporal-kg-and-evals.md) §A). It models knowledge strictly as bi-temporal entity edges, bifurcating real-world validity (`valid_at`, `invalid_at`) from system transaction time (`created_at`, `expired_at`; [`edges.py:263-290`](../research/07-temporal-kg-and-evals.md#L73-L102)). Graphiti runs atop third-party graph engines (Neo4j, FalkorDB, Kùzu), storing vector embeddings on both nodes and edges. Contradictions are resolved by an LLM prompt (`prompts/dedupe_edges.py`) combined with deterministic Python interval checks (`edge_operations.py:748-783`; [`docs/research/verification/V07-temporal-kg-and-evals.md`](../research/verification/V07-temporal-kg-and-evals.md) §3.1). Graphiti has no native Hermes plugin, and self-hosting Zep requires orchestrating multiple services. Its bi-temporal data model and deterministic invalidation logic are best-in-class, but its multi-stage extraction pipeline triggers 4 to 12+ LLM calls per episode, creating latency and API cost bottlenecks on interactive write paths.

### 1.5 SurrealDB Agent Memory
SurrealDB Agent Memory is a vendor architecture specification introducing typed, temporal, and auditable memory directly within SurrealDB 3.x ([`docs/research/07-temporal-kg-and-evals.md`](../research/07-temporal-kg-and-evals.md) §B). It rejects poly-store coordinators by implementing documents, bi-temporal graph edges, HNSW vector search, and BM25 full-text indexing within a single storage engine under unified ACID transactions ([`docs/research/05-surrealdb.md`](../research/05-surrealdb.md) §3.1). The architecture uses a three-clock temporal model (`SurrealDB VERSION`, `as_of`, `valid_from`/`valid_until`), three memory primitives (Attribute, Relation, Action), six experiential categories, and deterministic reconciliation in code. While SurrealDB Agent Memory achieves high benchmark accuracy (57.1% strict and 77.2% Kendall $\tau$ on BEAM 1M; [`benchmarks.md:119`](../research/07-temporal-kg-and-evals.md#L440)), the vendor implementation is cloud-first, exposed primarily via MCP tool calls, and lacks lifecycle hooks for local Hermes agent execution.

### 1.6 MemGPT / Letta
MemGPT ([arXiv:2310.08560](https://arxiv.org/abs/2310.08560)) and its production successor Letta formalize an operating-system-inspired memory hierarchy for LLM agents ([`docs/research/07-temporal-kg-and-evals.md`](../research/07-temporal-kg-and-evals.md) §D.1). Memory is partitioned into Core Memory (in-context, agent-editable blocks for human and persona traits), Recall Memory (sliding conversation history), and Archival Memory (unbounded out-of-context vector/document store). Storage couples PostgreSQL/SQLite with vector indexes (pgvector, Chroma). State consistency is maintained relationally, but moving facts between tiers requires explicit tool invocations (`core_memory_append`, `archival_memory_search`). Hermes adopted MemGPT's Core Memory pattern directly via its built-in `MEMORY.md` and `USER.md` files. While proven for long-horizon persona consistency, Letta's dependence on explicit agent-driven memory tool calls introduces the "ignorance paradox," where an agent fails to recall facts because it does not realize it has forgotten them.

### 1.7 A-MEM
A-MEM ([arXiv:2502.12110](https://arxiv.org/abs/2502.12110), February 2025) adapts the Zettelkasten slip-box note-taking methodology to agent memory ([`docs/research/07-temporal-kg-and-evals.md`](../research/07-temporal-kg-and-evals.md) §D.2). Rather than enforcing a rigid graph ontology, A-MEM stores memories as atomic notes enriched with tags, contextual summaries, and dynamic associative links (`links: [note_id_1, note_id_2]`). When new notes are indexed, existing links and connection weights evolve dynamically based on topical co-occurrence and semantic affinity. Storage is split between vector indexes and relational link tables, resulting in eventual consistency across the link network. A-MEM remains an academic research system with no Hermes provider or production daemon. Its dynamic cross-linking offers an alternative to rigid schemas, but its unstructured link evolution makes deterministic contradiction tracking and time-travel querying difficult.

---

## 2. Master Pattern Matrix

The matrix below evaluates 30 critical agent memory patterns across the primary prior art implementations, detailing Engram's concrete decision (`ADOPT`, `ADAPT`, or `REJECT`) and citing the governing ADR or specification section.

| Pattern | Hindsight | Cognee | Mem0 | Graphiti | Engram Decision & Spec Placement |
|---|---|---|---|---|---|
| **1. Single-call structured extraction** | **REJECT:** 2 calls/turn (extract + background consolidation; `fact_extraction.py:269`, `consolidator.py:1`; R01 §3.1) | **REJECT:** 2 calls + 4 embeddings per chunk (`estimator.py:62-75`; R02 §2.2, V02 §2) | **ADAPT:** Single-pass additive prompt (`ADDITIVE_EXTRACTION_PROMPT`; `prompts.py:468`), but outputs flat text; R03 §2.2 | **REJECT:** 4–12+ calls per episode (`graphiti.py:1471-1539`; R07 §A.9, V07 §3.2) | **ADOPT (ADR-07):** 1 structured JSON-schema call per ≤4-turn batch extracting entities, facts, and dates; `04-ingestion-pipeline.md` |
| **2. Integer-handle candidate priming** | **REJECT:** Relational string joins on names (`entity_resolver.py:722`; R01 §3.3) | **REJECT:** Free-form entity names in Cypher (`generate_graph_prompt.txt`; R02 §3.1) | **ADAPT:** Pioneered `uuid_mapping` `0..N` (`v1.0.11:main.py:585`), but dead code in v2 (`main.py:937`; V03 FIND-01) | **REJECT:** Emits full UUID strings to LLM prompts (`prompts/dedupe_edges.py:25`; R07 §A.2) | **ADOPT (ADR-07, ADR-10):** Prime top candidate entities as `E1..En`, mapped back in Rust; `04-ingestion-pipeline.md` |
| **3. 5W/coreference extraction rules** | **ADOPT:** 5W fields (`who/what/when/where/why`) + coreference rules (`fact_extraction.py:269-315`; R01 §3.1) | **REJECT:** Heuristic node/edge rules without 5W decomposition (`generate_graph_prompt.txt`; R02 §3.1) | **ADAPT:** Self-contained contextually rich statement rules (`prompts.py:608-615`; R03 §2.2) | **REJECT:** Free-form prose facts on edges (`edges.py:64`; R07 §A.1) | **ADOPT (ADR-07):** Adopt Hindsight 5W coreference rules and Mem0 context richness; `prompts/extract.v1.md` |
| **4. Relative-date normalization** | **ADOPT:** Regex engine (`_infer_temporal_date`) normalizes relative dates to ISO (`fact_extraction.py:97`; R01 §3.1) | **REJECT:** Leaves dates as raw `{verb}_at` edge leaves (`generate_graph_prompt.txt:40`; R02 §3.1) | **ADOPT:** Prompt anchors relative time to observation calendar date (`prompts.py:535`; R03 §2.2) | **ADOPT:** Anchors relative time via `reference_time` (`prompts/extract_edges.py:260`; R07 §A.7) | **ADOPT (ADR-07, ADR-11):** Anchors relative dates via `jiff` using turn timestamp and bank timezone; `04-ingestion-pipeline.md` |
| **5. Coarse-date intervals** | **ADOPT:** Infers month/year intervals spanning entire calendar periods (`fact_extraction.py:110`; R01 §3.1) | **REJECT:** Point-in-time timestamp nodes only (`cognify.py:57-66`; R02 §2.2) | **REJECT:** Dates embedded as flat prose in text string (`main.py:1017`; R03 §2.2) | **ADOPT:** Date range bounds on `valid_at`/`invalid_at` (`edges.py:90-97`; R07 §A.1) | **ADOPT (ADR-08, ADR-11):** `valid_from`/`valid_to` bounds with `time_precision` enum; `03-data-model.md` |
| **6. Bi-temporal edges with `expired_at`** | **ADAPT:** Tracks `occurred_start/end` vs `updated_at` on unit rows (`memory_units`; R01 §2.1) | **REJECT:** No bi-temporal edges; dropped `Event` nodes in v1.6.3 (`cognify.py:57`; R02 §2.2) | **REJECT:** Flat memories; v1 `invalidated_at` dropped in v2 (`main.py:422`; R03 §4.2) | **ADOPT:** `valid_at/invalid_at` vs `created_at/expired_at` (`edges.py:82-101`; R07 §A.1) | **ADOPT (ADR-08):** `fact` relation carries `valid_from/to` and `recorded_at/expired_at`; `03-data-model.md` |
| **7. Deterministic vs LLM contradiction** | **ADAPT:** Purged LLM opinion confidence in `g2h3i4j5k6l7`; tracks proof counts (`alembic/versions`; V01 §3.1) | **REJECT:** Post-hoc batch LLM conflict review (`improve(review_conflicts=True)`; R02 §6.1) | **REJECT:** v1 used LLM prompt; v2 abandoned reconciliation for additive pile-up (`main.py:942`; R03 §2.1) | **ADAPT:** LLM classifies contradiction, Python enforces temporal intervals (`edge_operations.py:748`; R07 §A.2) | **ADOPT (ADR-08):** Deterministic Rust logic based on predicate cardinality, trust hierarchy, and dates; `04-ingestion-pipeline.md` |
| **8. Soft invalidation** | **ADOPT:** `invalidated_memory_units` table retains retired facts (`schema.py:140`; R01 §2.1) | **ADAPT:** `status_label` `[superseded; as of ...]` sorts to bottom (`resolve_edges_to_text.py:61`; R02 §6.2) | **REJECT:** v1 hard deleted; v2 leaves contradictory duplicates active (`main.py:1047`; R03 §2.2) | **ADOPT:** Sets `expired_at = utc_now()`; rows are never deleted (`edge_operations.py:770`; R07 §A.2) | **ADOPT (ADR-08):** Sets `valid_to = new.valid_from`, `expired_at = now`, `status = superseded`; `04-ingestion-pipeline.md` |
| **9. Observation consolidation** | **ADOPT:** Synthesizes `observation` units with `proof_count` and `source_memory_ids` (`fact_extraction.py:270`; R01 §1.1) | **ADAPT:** Chunk summarization into `TextSummary` collection (`estimator.py:62`; R02 §2.2) | **REJECT:** Flat facts only; no observation synthesis (`main.py:918`; R03 §2.2) | **ADAPT:** Community summaries via LPA and Sagas (`nodes.py:907`; R07 §A.5) | **ADOPT (ADR-12):** `observation` table consolidates ≥5 facts, updating `support_count` and evidence; `04-ingestion-pipeline.md` |
| **10. No LLM float confidence** | **ADOPT:** Migration `g2h3i4j5k6l7` completely dropped `confidence_score` column (`alembic/versions`; V01 §3.1) | **REJECT:** Uncalibrated float similarity in user-space BFS (`CogneeGraph.py:428`; R02 §4.1) | **ADOPT:** No LLM confidence floats stored; ranks by cosine + BM25 (`scoring.py:60`; R03 §5.1) | **ADOPT:** No LLM confidence floats; relies on boolean contradiction flags (`prompts/dedupe_edges.py`; R07 §A.2) | **ADOPT (ADR-08):** Deterministic confidence formula from source trust base + support count; `03-data-model.md` |
| **11. Entity resolution cascade** | **ADAPT:** Trigram $\ge 0.3$, token compatibility gate, 0.5/0.3/0.2 composite score (`entity_resolver.py:1290`; V01 §3.3) | **REJECT:** No fuzzy cascade; matches exact endpoint names (`add_data_points.py`; R02 §3.1) | **ADAPT:** spaCy batch NER + vector cosine $\ge 0.95$ merge (`main.py:1100`; R03 §2.2) | **ADAPT:** Exact -> MinHash/LSH $J \ge 0.9$ (entropy $\ge 1.5$) -> LLM (`dedup_helpers.py:31`; V07 §3.1) | **ADAPT (ADR-10):** Primed `E#` -> exact key -> Jaro-Winkler $\ge 0.92$ -> embedding cosine $\ge 0.90$; `04-ingestion-pipeline.md` |
| **12. Hub / degree damping** | **ADOPT:** Inverse square root damping $1/\sqrt{\text{degree}}$ on co-occurrences (`entity_resolver.py:190`; V01 §3.3) | **REJECT:** No degree damping; hub nodes cause graph traversal blowup (`CogneeGraph.py:428`; R02 §4.1) | **ADOPT:** Quadratic degree damping $1 / (1 + 0.001(N-1)^2)$ (`main.py:1805`; V03 §3) | **REJECT:** Shortest path distance without degree penalty (`search_utils.py:1804`; R07 §A.6) | **ADOPT (ADR-10, ADR-11):** Edge traversal weight multiplied by $1/\sqrt{\text{degree}}$; `05-retrieval.md` |
| **13. 4-way retrieval** | **ADOPT:** Dense vector + BM25 + graph link expansion + temporal spreading (`recall.py:310`; V01 §3.4) | **REJECT:** 21 fragmented single-focus search modes without unified fusion (`SearchType.py`; V02 §2) | **REJECT:** Vector + BM25 + entity boost without true graph traversal (`main.py:1745`; R03 §5.1) | **ADAPT:** Dense vector + BM25 + BFS traversal + episode recency (`search_config.py:32`; R07 §A.6) | **ADOPT (ADR-11):** Parallel Dense Vector + BM25 + 1-Hop Graph Traversal + Temporal Recency; `05-retrieval.md` |
| **14. RRF $k=60$** | **ADOPT:** Reciprocal Rank Fusion with $k = 60$ (`fusion.py:29`; V01 §3.4) | **REJECT:** Heuristic algebraic formula over distances (`CogneeGraph.py:428`; V02 §2 F-01) | **REJECT:** Additive normalizer with variable divisors and sigmoid BM25 (`scoring.py:60`; V03 §3) | **ADAPT:** Reciprocal Rank Fusion with $k = 1$ (`search_utils.py:1786`; R07 §A.6) | **ADOPT (ADR-11):** Weighted RRF in Rust with $k = 60$ (weights 1.0, 1.0, 0.8, 0.5); `05-retrieval.md` |
| **15. Temporal spreading** | **ADAPT:** 8 buckets, 10 entry points, 60 pool size, BFS decay 0.7 (`recall.py:310`; V01 §3.4) | **REJECT:** No spreading; raw temporal date filter only (`SearchType.TEMPORAL`; R02 §4.1) | **REJECT:** No temporal spreading across memory history (`main.py:1745`; R03 §5.1) | **ADAPT:** Sequential episode chaining via `NextEpisodeEdge` (`nodes.py:907`; R07 §A.5) | **ADAPT (ADR-11):** Temporal rule parser activates time-window filtering and superseded fact recall; `05-retrieval.md` |
| **16. Cross-encoder rerank** | **ADAPT:** Local `ms-marco-MiniLM-L-6-v2` cross-encoder (`config.py:1383`; V01 §3.4) | **REJECT:** No cross-encoder reranking stage (R02 §4.1) | **ADAPT:** Pluggable remote rerankers (Cohere, HuggingFace; `reranker/`; V03 §5) | **ADAPT:** Optional remote `bge-reranker-v2-m3` (`bge_reranker_client.py:34`; R07 §A.6) | **ADAPT (ADR-11):** Optional external HTTP cross-encoder endpoint; off by default; `05-retrieval.md` |
| **17. Recency / proof boosts** | **ADOPT:** Multiplicative boosts centered at 0.5 with log proof norm (`reranking.py:287`; V01 §2 F-03) | **REJECT:** No recency or proof boost adjustments (R02 §4.1) | **REJECT:** No proof counts; simple timestamp weighting (`scoring.py`; R03 §5.1) | **ADAPT:** Frequency boost via episode mentions count (`search_utils.py:1890`; R07 §A.6) | **ADOPT (ADR-08, ADR-11):** Recency channel in RRF + deterministic confidence scaling with support; `05-retrieval.md` |
| **18. MMR** | **REJECT:** Relies solely on RRF and cross-encoder scores (`recall.py`; R01 §4.2) | **REJECT:** No diversity reranking in pipeline (R02 §4.1) | **REJECT:** Cosine similarity thresholding only (`main.py:1399`; R03 §5.1) | **ADOPT:** Maximal Marginal Relevance with $\lambda = 0.5$ (`search_utils.py:1912`; R07 §A.6) | **ADOPT (ADR-11):** MMR with $\lambda = 0.7$ applied over RRF candidates before packing; `05-retrieval.md` |
| **19. Token-budget packing** | **ADOPT:** Greedy token packing using `toktok` tokenizer (`token_encoding.py:10`; V01 §2 F-07) | **REJECT:** Emits unconstrained markdown into prompt context (`resolve_edges_to_text.py`; R02 §6.2) | **REJECT:** Limits by item count `top_k`, risking context overflow (`main.py:1745`; R03 §5.5) | **REJECT:** Context stuffing without token budgeting (`search_utils.py`; R07 §C.3) | **ADOPT (ADR-11):** Greedy packing up to `token_budget` (default 1200 tokens, `ceil(chars/3.5)`); `05-retrieval.md` |
| **20. Injected-context header** | **ADOPT:** Markdown block formatted with provenance glyph `⟐` (`hermes/__init__.py:1801`; V01 §3.6) | **ADAPT:** Markdown block with `[current]` and `[superseded]` tags (`resolve_edges_to_text.py:61`; R02 §6.2) | **REJECT:** Flat bullet list without temporal or status markers (`hermes-plugin-mem0/__init__.py:310`; R03 §8.2) | **ADAPT:** Prose facts annotated with endpoint labels (`edges.py:64`; R07 §A.1) | **ADOPT (ADR-11, ADR-13):** Header `## Recalled context (Engram)` with dates, confidences, and `[contested]`; `07-hermes-plugin.md` |
| **21. Content-hash idempotency** | **ADAPT:** Hash checks on document chunk texts (`chunks.py:40`; R01 §2.1) | **ADOPT:** SHA-256 `content_hash` skips reprocessing via `PipelineRunAlreadyCompleted` (R02 §2.1, V02 §2) | **ADAPT:** MD5 hash deduplication in Phase 5 (`main.py:1007`; V03 §3) | **REJECT:** Relies on exact text equality checks (`dedup_helpers.py`; R07 §A.3) | **ADOPT (ADR-07, ADR-13):** SHA-256 `content_hash` on `episode` deduplicates turn ingestion; `03-data-model.md` |
| **22. Task status tracking** | **ADAPT:** `async_operations` table tracks asynchronous background jobs (`schema.py:180`; R01 §2.1) | **ADOPT:** Fine-grained task status tracking across pipeline runs (`pipeline_status.py`; R02 §2.1) | **REJECT:** Synchronous background threads without task tracking (`main.py`; R03 §2.3) | **REJECT:** In-memory execution without persistent task records (`graphiti.py`; R07 §A.9) | **ADOPT (ADR-17):** SurrealDB `job` table tracks status `pending|running|done|dead` and leases; `08-deployment-operations.md` |
| **23. Outbox jobs** | **REJECT:** Direct DB writes + Celery dispatch without transactional outbox (R01 §2.1) | **REJECT:** Independent store calls in sequence without transactional outbox (`add_data_points.py:325`; V02 §2) | **REJECT:** Direct vector insertion followed by SQLite history append (`main.py:1047`; R03 §2.2) | **REJECT:** Direct graph driver execution without outbox (`graphiti.py`; R07 §A.9) | **ADOPT (ADR-17):** `job` records created in the exact same SurrealDB transaction as the episode; `08-deployment-operations.md` |
| **24. Single-writer** | **REJECT:** Concurrent worker pools accessing Postgres with row locks (R01 §2.1) | **ADAPT:** Enforced via background Uvicorn daemon on port 8011 (`server_bootstrap.py`; V02 §2) | **ADAPT:** Single writer thread in Hermes plugin (`hermes-plugin-mem0/__init__.py:263`; R03 §8.2) | **REJECT:** Relies on database-level write locks in Neo4j/driver (`graphiti.py`; R07 §A.9) | **ADOPT (ADR-17):** One worker task per bank in Rust serializing reconciliation and HNSW writes; `08-deployment-operations.md` |
| **25. Prefetch strategy** | **ADAPT:** Background `queue_prefetch` + 3.0s join timeout in `prefetch` (`hermes/__init__.py:1788`; V01 §3.6) | **REJECT:** Drains prior turn's cache; causes 1-turn lag on current query (`provider.py:681`; V04 §2 F-01) | **REJECT:** 3.0s blocking thread join on user hot path (`hermes-plugin-mem0/__init__.py:294`; V03 §3) | **N/A:** No Hermes plugin; evaluated as library reference (R07 §A.1) | **ADOPT (ADR-13):** Live recall on current query with 1500ms deadline, falling back to cache; `07-hermes-plugin.md` |
| **26. Circuit breaker** | **ADAPT:** Async timeout fallback on graph expansion (`link_expansion.py:349`; V01 §3.8) | **REJECT:** No circuit breaker; plugin hangs if daemon crashes (`provider.py`; R02 §9.2) | **ADOPT:** Breaker trips after 5 failures, 120s cooldown (`hermes-plugin-mem0/__init__.py:30`; V03 §3) | **REJECT:** No circuit breaker pattern in driver (`graphiti.py`; R07 §A.9) | **ADOPT (ADR-13):** Breaker trips after 3 prefetch failures, cooling down for 30s; `07-hermes-plugin.md` |
| **27. Message truncation** | **REJECT:** Token packing at recall, full text preserved on ingest (`token_encoding.py`; R01 §4.4) | **REJECT:** Token-aware chunking without arbitrary character caps (`utils.py:53`; V02 §2) | **REJECT:** Blind 450-char cap (`_SYNC_MSG_MAX_CHARS = 450`) drops long turns (`hermes-plugin-mem0/__init__.py:43`; V03 §3) | **REJECT:** Preserves full turn content without truncation (`nodes.py:54`; R07 §A.4) | **REJECT (ADR-06, ADR-07):** Full turn ingested; `qwen3-embedding:0.6b` supports 32k tokens; `04-ingestion-pipeline.md` |
| **28. Telemetry policy** | **REJECT:** Integrated Sentry error reporting and PostHog tracking (R01 §6.1) | **REJECT:** Telemetry reporting hooks enabled by default (`telemetry.py`; R02 §8.1) | **REJECT:** Telemetry phone-home and upsell notices (`telemetry.py:14`, `notices.py:127`; V03 §5) | **REJECT:** Telemetry tracking enabled by default (`graphiti.py`; R07 §A.9) | **REJECT (ADR-14):** Zero phone-home telemetry; local JSON tracing and Prometheus `/metrics` only; `09-observability.md` |
| **29. All-in-one image** | **ADOPT:** Multi-stage Dockerfile bundling backend, UI, and embedded Postgres `pg0` (`Dockerfile`; V01 §3.7) | **REJECT:** Multi-container compose required for Neo4j/Qdrant backends (R02 §8.2) | **REJECT:** Multi-container compose with pgvector and Next.js (`docker-compose.yaml`; V03 §5) | **REJECT:** Requires external Neo4j/FalkorDB container (R07 §A.1) | **ADOPT (ADR-03):** Debian slim image with `tini`, `engram` binary, and supervised `surreal`; `08-deployment-operations.md` |
| **30. MCP tool surface size** | **REJECT:** 39 registered tools over MCP causing model confusion (`mcp_tools.py:45-87`; V01 §2 F-08) | **REJECT:** 5 tools, but `improve` omitted due to missing decorator (`server.py:813`; V02 §2 F-02) | **REJECT:** Generic read/write tools without graph inspection (`docs/platform/mem0-mcp.mdx:62`; R03 §7.3) | **REJECT:** Fine-grained graph operations exposed without lifecycle abstractions (R07 §A.1) | **ADOPT (ADR-18):** Exactly 5 focused tools: `recall`, `remember`, `forget`, `entities`, `status`; `06-api-and-mcp.md` |

---

## 3. Deep-Dive Analysis of the 8 Most Consequential Learnings

### 3.1 Learning 1: Deterministic Contradiction Resolution & The Elimination of Float Confidence

#### 1. What Prior Art Does (With Primary Evidence)
In early versions of Hindsight, fact extraction assigned a floating-point score between $0.0$ and $1.0$ (`confidence_score`) to every extracted statement, including subjective user opinions. On 2026-04-02, Hindsight’s engineering team completely reversed this design in Alembic migration `g2h3i4j5k6l7_remove_opinion_fact_type.py` ([`docs/research/verification/V01-hindsight.md`](../research/verification/V01-hindsight.md) §3.1; [`alembic/versions/g2h3i4j5k6l7_...py:57-78`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/alembic/versions/g2h3i4j5k6l7_remove_opinion_fact_type.py#L57-L78)):

```python
def _pg_upgrade() -> None:
    schema = _get_schema_prefix()
    # 1. Delete any remaining opinion rows
    op.execute(f"DELETE FROM {schema}memory_units WHERE fact_type = 'opinion'")
    # 2. Drop opinion-specific indexes
    op.execute(f"DROP INDEX IF EXISTS {schema}idx_memory_units_opinion_confidence")
    op.execute(f"DROP INDEX IF EXISTS {schema}idx_memory_units_opinion_date")
    # 3. Drop confidence_score constraints and column
    op.execute(f"ALTER TABLE {schema}memory_units DROP CONSTRAINT IF EXISTS confidence_score_fact_type_check")
    op.execute(f"ALTER TABLE {schema}memory_units DROP CONSTRAINT IF EXISTS memory_units_confidence_score_check")
    op.execute(f"ALTER TABLE {schema}memory_units DROP COLUMN IF EXISTS confidence_score")
```

Graphiti addresses contradictions by prompting an LLM (`prompts/dedupe_edges.py:44-115`) with existing edges and invalidation candidates, asking the model to return duplicate and contradiction integer indices (`EdgeDuplicate`). Only after the LLM flags an edge does Python code (`edge_operations.py:748-783`) check if the new edge is strictly newer, setting `edge.invalid_at = resolved_edge.valid_at` and `edge.expired_at = utc_now()`.

#### 2. What Went Wrong or Right for Them
- **The Failure of LLM Confidence Floats:** Hindsight discovered that LLMs cannot reliably calibrate floating-point numbers. One prompt would score an opinion as $0.78$ and another as $0.62$ with identical phrasing. These ungrounded floats distorted downstream ranking algorithms and bloated B-tree indexes. Hindsight replaced them with structural **proof counts (`proof_count`)** and explicit evidence links (`source_memory_ids UUID[]`).
- **The Hazards of LLM Contradiction Judgment:** Graphiti’s use of an LLM to decide whether edge A contradicts edge B adds a full LLM completion call to every edge candidate set on the write path. Furthermore, LLMs frequently hallucinate contradictions when an entity merely updates its status or takes on an additional role (e.g. interpreting "Alice is coding in Rust" as a contradiction of "Alice is engineering manager").

#### 3. The Precise Engram Adaptation
Engram adopts Hindsight's elimination of LLM float confidence and Graphiti's soft invalidation timestamps, but executes truth maintenance entirely in **deterministic Rust code** (ADR-08; `docs/spec/04-ingestion-pipeline.md` §8):
1. **Predicate Cardinality:** Every predicate declares a strict cardinality in its schema: `functional` (single-valued, e.g. `works_at`, `written_in`, `has_role`) or `multi` (multi-valued, e.g. `uses`, `owns`, `prefers`).
2. **Deterministic Supersession:** When an incoming active fact $(s, p, o_2)$ is processed for a functional predicate:
   - If an existing active edge $(s, p, o_1)$ exists and $new.valid\_from > existing.valid\_from$ (strict inequality; equal timestamps contest per Rule 7), the old edge is automatically superseded in code.
   - The old edge receives: `valid_to = new.valid_from`, `expired_at = time::now()`, `status = superseded`, `superseded_by = new.id`.
   - The new edge receives: `supersedes = old.id`.
3. **Contested Claims (Equal Timestamps or Inverted Trust):** If an incoming functional claim has identical $valid\_from$ timestamps, unknown precision on either side, or lower trust with a strictly later timestamp, the code does **not** supersede. Both edges remain active, both receive `contested = true`, and both are linked via `conflicts_with`. If the incoming claim is strictly earlier ($new.valid\_from < existing.valid\_from$), it is treated as a historical backfill (Rule 6): inserted as active with $valid\_to = \min(new.valid\_to, existing.valid\_from)$ with zero contestation.
4. **Deterministic Confidence Formula:** Confidence is never generated by an LLM; it is computed by a deterministic formula based on source trust base and empirical proof counts:
   $$\text{confidence} = \text{clamp}\Big(\text{trust\_base}[\text{trust}] \times \big(1.0 + 0.1 \cdot \min(\text{support} - 1, 5)\big), 0.0, 1.0\Big)$$
   where $\text{trust\_base} = \{\text{user\_stated}: 0.90, \text{user\_implied}: 0.75, \text{assistant\_stated}: 0.60, \text{tool\_output}: 0.60, \text{inferred}: 0.50\}$.

---

### 3.2 Learning 2: Single-Engine Multi-Model ACID vs. Poly-Store Drift & Daemons

#### 1. What Prior Art Does (With Primary Evidence)
Cognee functions as a poly-store coordinator, managing relational tables (SQLite/PostgreSQL via SQLAlchemy), graph databases (Neo4j/Kùzu/FalkorDB), and vector databases (LanceDB/Qdrant/PGVector). In [`cognee/tasks/storage/add_data_points.py:325-336`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py#L325-L336) ([`docs/research/verification/V02-cognee.md`](../research/verification/V02-cognee.md) §2 Priority 3), Cognee’s engineers explicitly documented the lack of cross-store consistency:

```python
# GRAPH BEFORE VECTORS, never concurrently. The two stores fail
# independently, and only one of the two orders is recoverable:
#
#   graph ok, vector fails -> the artifact carries its source ref, so
#     rollback and delete can both find it. Self-healing.
#   vector ok, graph fails -> the point exists with NO ref anywhere in the
#     graph. Nothing can discover it again, while CHUNKS retrieval reads
#     the vector collection directly and happily returns it — content from
#     a run that reported failure, served to users, permanently.
#
# Concurrency bought a little latency and made the second case reachable
# on every write, so the writes are sequenced instead.
```

Furthermore, because embedded engines like SQLite and Kùzu lack concurrent multi-process write support, Cognee’s Hermes provider (`cognee_integration_hermes/server_bootstrap.py`) was forced to spawn a persistent background Uvicorn HTTP server daemon on port 8011 (`exit_watcher.py`) to serialize database access across processes.

#### 2. What Went Wrong or Right for Them
- **Data Inconsistency on Partial Failure:** Cognee commits the relational ledger first (`await session.commit()`), then writes graph nodes, then indexes vector nodes, then writes graph edges, and finally indexes vector edges. If a worker process crashes, times out, or encounters a disk error between writing graph nodes and indexing vector nodes, the graph contains nodes that can never be discovered via vector search. There is no distributed two-phase commit (2PC) or cross-store rollback.
- **Operational Sprawl & Lock Contention:** Requiring an out-of-process Uvicorn HTTP daemon on port 8011 introduced port collisions, zombie process leaks when Hermes terminated abruptly, and IPC latency on every memory turn.

#### 3. The Precise Engram Adaptation
Engram eliminates the poly-store coordinator pattern by selecting **SurrealDB 3.3.4 as its sole storage engine** (ADR-01, ADR-02, ADR-03; `docs/spec/02-architecture.md`):
1. **Single ACID Transaction Boundary:** In Engram, raw episodic text (`episode`), normalized entities (`entity`), bi-temporal graph edges (`fact`), HNSW vector embeddings, and BM25 full-text indexes live in the same records within the same engine. Every write operation is wrapped in a native SurrealQL transaction:
   ```surql
   BEGIN TRANSACTION;
   LET $ep = CREATE ONLY episode CONTENT {
     session_id: $session_id, role: $role, text: $text,
     embedding: $embedding, content_hash: $content_hash
   };
   LET $fact = RELATE $subject_id->fact->$object_id CONTENT {
     predicate: $predicate, valid_from: $valid_from,
     source_episodes: [$ep.id], trust: $trust
   };
   COMMIT TRANSACTION;
   ```
   If vector insertion fails or an entity constraint is violated, SurrealDB rolls back the entire transaction atomically. Zero orphaned graph pointers and zero phantom vector entries can exist.
2. **Supervised Local Process Model:** Engram runs as a single Rust binary that directly supervises a local `surreal start` child process bound to loopback `127.0.0.1:8000` (ADR-03). No external Uvicorn server, graph daemons, or separate vector containers are required.

---

### 3.3 Learning 3: Graph Grounding vs. Graph Abandonment (Mem0 Lessons)

#### 1. What Prior Art Does (With Primary Evidence)
In its v1 architecture (`v1.0.11`), Mem0 offered a graph memory module (`mem0/graphs/`, `graph_memory.py`) connecting to Neo4j, Kùzu, Memgraph, or Apache AGE. In their peer-reviewed LoCoMo evaluation ([arXiv:2504.19413](https://arxiv.org/abs/2504.19413), Table 1; [`docs/research/verification/V03-mem0.md`](../research/verification/V03-mem0.md) §3 Claim 4), the authors compared base Mem0 against graph-augmented Mem0g:
- On single-hop questions, Mem0 achieved 67.13% vs Mem0g’s 65.58%.
- On multi-hop questions, Mem0 achieved **51.15%** vs Mem0g’s **48.72%**.
- Context consumption for Mem0 was ~7,000 tokens vs Mem0g's ~14,000 tokens.

The authors explicitly concluded: *"Interestingly, the addition of graph memory in Mem0g does not provide performance gains here, indicating potential inefficiencies or redundancies in structured graph representations for complex integrative tasks compared to dense natural language memory alone."* Following this finding, Mem0 release v2.0.0 (PR #4805, April 2026; [`docs/changelog/sdk.mdx:398`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/docs/changelog/sdk.mdx#L398)) deleted over 4,000 lines of graph database code.

However, forensic code verification of Mem0 OSS v2.2.1 reveals a critical flaw: while `ADDITIVE_EXTRACTION_PROMPT` ([`prompts.py:468-944`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/configs/prompts.py#L468-L944)) instructs the LLM to extract `linked_memory_ids`, the persistence loop in [`mem0/memory/main.py:1017-1041`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L1017-L1041) reads only `text` and `attributed_to`, completely dropping `linked_memory_ids`. Furthermore, `uuid_mapping` at `main.py:937-941` is never referenced again, leaving it as dead code. In open-source Mem0 v2, memories never link to each other.

#### 2. What Went Wrong or Right for Them
- **Why Mem0g Failed:** Mem0g used unconstrained, open-ended triple extraction without an ontological schema or hub damping. Extracted graphs quickly degenerated into dense, noisy spiderwebs where common words ("user", "system", "task") acted as super-nodes. During multi-hop retrieval, Cypher queries expanded across these noisy hubs, stuffing prompt context with irrelevant relations that distracted the LLM judge and dragged multi-hop accuracy below the flat vector baseline.
- **Why Abandoning the Graph is Flawed:** By deleting the graph engine entirely, Mem0 reduced memory to flat, isolated textual bullet points. Without graph edges, an agent cannot traverse multi-hop chains (e.g. *User -> owns -> Service A -> depends_on -> Postgres 16*), track entity aliases, or execute soft temporal supersession.

#### 3. The Precise Engram Adaptation
Engram retains graph modeling while immunizing itself against the failure modes that crippled Mem0g (ADR-07, ADR-08, ADR-09, ADR-10; `docs/spec/03-data-model.md`):
1. **Closed Predicate Vocabulary (ADR-09):** Engram restricts factual graph edges to a closed set of 15 typed relations (`works_at`, `owns`, `depends_on`, `prefers`, `located_in`, etc.). Out-of-vocabulary extractions are mapped to `related_to` with an unindexed label or rejected.
2. **Native Graph Pointer Traversal:** SurrealDB natively traverses graph records via direct pointers (`SELECT ->fact[WHERE valid_to IS NONE]->entity.* FROM $seeds`), avoiding relational self-joins and Cypher query compilation overhead.
3. **Hub Damping on Traversal:** Edge retrieval weights are damped by $1.0 / \sqrt{\text{degree}}$, preventing high-degree hub nodes from dominating candidate selection.
4. **Fixed Persistence Logic:** Unlike Mem0 v2, Engram's Rust ingestion engine actively resolves candidate integer handles (`E1..En`) and atomically writes the resulting `fact` records into SurrealDB.

---

### 3.4 Learning 4: Extraction Ingestion Tax & Single-Call Structured Batching

#### 1. What Prior Art Does (With Primary Evidence)
Graphiti executes a highly granular, multi-stage ingestion pipeline for each ingested episode (`graphiti.py:1334-1580`; [`docs/research/verification/V07-temporal-kg-and-evals.md`](../research/verification/V07-temporal-kg-and-evals.md) §3.2):
1. `extract_nodes` $\to$ 1 LLM call
2. `resolve_extracted_nodes` $\to$ 0 to 1 batch LLM call (`dedupe_nodes.nodes`)
3. `extract_edges` $\to$ 1 LLM call (`extract_edges.edge`)
4. `_dedupe_extracted_edge` $\to$ 1 LLM call per edge candidate set (`dedupe_edges.resolve_edge`)
5. `_extract_edge_timestamps` $\to$ 1 LLM call per edge
6. `extract_attributes_from_nodes` $\to$ 1 LLM call per node
7. `update_community` $\to$ 1 LLM call per affected community cluster

For a realistic conversational episode producing 2 entities and 2 edges, Graphiti triggers between **8 and 12+ separate LLM API calls**. Similarly, Cognee’s default `cognify` pipeline incurs 2 LLM calls (graph extraction and chunk summarization) and 4 vector embedding calls per text chunk ([`estimator.py:62-75`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/cognify/estimator.py#L62-L75); [`docs/research/verification/V02-cognee.md`](../research/verification/V02-cognee.md) §2 Priority 8).

#### 2. What Went Wrong or Right for Them
- **Latency and Token Costs:** Executing 8–12 LLM completions sequentially or in parallel batches incurs estimated operational token costs of **$0.02 to $0.15 per conversational turn** [estimated] on commercial APIs, and introduces clock latencies of **3,000 ms to 8,000 ms** [estimated]. In interactive agent dialogues, running this extraction pipeline synchronously on every turn freezes the agent or exhausts API rate limits.

#### 3. The Precise Engram Adaptation
Engram compresses extraction into **a single structured LLM call per batch** (ADR-07; `docs/spec/04-ingestion-pipeline.md`):
1. **Session Turn Batching:** Rather than extracting on every turn, turns are enqueued onto a background outbox worker and batched up to `extraction.batch_max_turns` (4 turns) or `extraction.batch_idle_ms` (20,000 ms) of conversational inactivity, with immediate flushes on session boundaries or explicit `engram_remember` tool calls.
2. **Unified Extraction Schema:** A single prompt (`prompts/extract.v1.md`) with a strict JSON schema extracts entities, typed relations from the closed vocabulary, temporal validity intervals, and polarity in a single completion:
   ```json
   {
     "entities": [{"handle": "E1", "name": "Alice", "kind": "person"}],
     "facts": [
       {"subject": "E1", "predicate": "works_at", "object": "E2", "valid_from": "2026-03-01T00:00:00Z", "polarity": "positive"}
     ]
   }
   ```
3. **Two-Stage Availability:** The raw turn is committed to SurrealDB and searchable via BM25 full-text indexing within **$<20\text{ ms}$** of ingestion (Stage 1). The vector embedding and structured graph extraction follow asynchronously via the outbox worker within seconds (Stage 2).

---

### 3.5 Learning 5: Candidate Priming via Integer Handles for Graph Grounding

#### 1. What Prior Art Does (With Primary Evidence)
In Mem0 v1 (`v1.0.11:mem0/memory/main.py:585-588, 646`; [`docs/research/verification/V03-mem0.md`](../research/verification/V03-mem0.md) §3 Claim 6), the engine retrieved existing candidate memories from the vector store before invoking the update prompt. To prevent the LLM from having to parse or reproduce long UUID strings, Mem0 populated a temporary mapping dictionary:
```python
temp_uuid_mapping = {}
for idx, mem in enumerate(existing_memories):
    temp_uuid_mapping[str(idx)] = mem["id"]
```
The prompt presented memories labeled with indices `0, 1, 2...`. When the model returned update instructions referencing `"id": "0"`, the code mapped `"0"` back to `temp_uuid_mapping["0"]`. 

In contrast, Graphiti injects raw UUID strings (`"uuid": "4a7b..."`) directly into its deduplication prompts (`prompts/dedupe_edges.py:25-34`), and Hindsight passes canonical entity names as text strings (`entity_resolver.py:722`).

#### 2. What Went Wrong or Right for Them
- **The Failure of Raw UUID Prompting:** LLMs struggle with verbatim reproduction of high-entropy alphanumeric strings like 36-character UUIDs or 26-character ULIDs. Models frequently drop characters, transpose digits, or hallucinate entirely new identifiers, causing foreign key lookups to fail and corrupting the graph. Furthermore, passing dozens of raw UUIDs wastes valuable context tokens.
- **The Accidental Orphan in Mem0 v2:** When Mem0 refactored to its additive pipeline in v2.0.0, it defined `uuid_mapping = {}` in `main.py:937-941`, but deleted the second LLM call, leaving `uuid_mapping` as unused dead code and dropping cross-memory linkages.

#### 3. The Precise Engram Adaptation
Engram adopts candidate priming as a core architectural pattern for entity resolution and graph grounding (ADR-07, ADR-10; `docs/spec/04-ingestion-pipeline.md`):
1. **Pre-Call Candidate Retrieval:** Before invoking the batch extraction LLM, Engram scans the batch text for potential entity mentions and retrieves top candidate entities from SurrealDB using exact alias matching, BM25 full-text search, and name-embedding cosine similarity.
2. **Handle Injection:** The prompt header injects retrieved candidates using short integer handles:
   ```
   Candidate Entities:
   [E1] "Alice" (person, aliases: ["Alice Smith", "asmith"])
   [E2] "billing-service" (project, aliases: ["billing"])
   ```
3. **Structured Reference in Extraction:** The LLM references `E1..En` in the `subject` and `object` fields of extracted fact triples. If a fact references an entity not present in the candidate list, the LLM omits the handle and specifies a new name and kind.
4. **Rust Decoding & Guardrails:** The Rust ingest orchestrator maps `E1` back to `entity:alice` via a local array lookup. If the model hallucinates an invalid handle (e.g. `E9` when only `E1..E3` were primed), the handle is rejected and the entity name is re-resolved through Engram's entity resolution cascade.

---

### 3.6 Learning 6: Bi-Temporal Knowledge Representation & Soft Invalidation

#### 1. What Prior Art Does (With Primary Evidence)
Graphiti (`graphiti_core/edges.py:263-290`; [`docs/research/07-temporal-kg-and-evals.md`](../research/07-temporal-kg-and-evals.md) §A.1) formalizes a bi-temporal knowledge graph model on its `EntityEdge` relation:
- **Transaction Time:** `created_at` (system commit timestamp) and `expired_at` (timestamp when the database invalidated the edge).
- **Valid Time:** `valid_at` (timestamp when the fact became true in the world) and `invalid_at` (timestamp when the fact ceased being true in the world).

When a new fact invalidates an existing edge, Graphiti’s deterministic maintenance loop (`edge_operations.py:770`) sets:
```python
edge.invalid_at = resolved_edge.valid_at
edge.expired_at = edge.expired_at if edge.expired_at is not None else utc_now()
```
The invalidated edge is never deleted from the database.

In stark contrast, Mem0 v1 executed hard destructive updates (`_update_memory` / `_delete_memory` in `storage.py`), overwriting the previous text in place. Mem0 v2 moved to the opposite extreme: an additive-only log where facts are appended and never updated or invalidated, allowing contradictory statements to coexist indefinitely.

#### 2. What Went Wrong or Right for Them
- **The Catastrophe of Destructive Overwrite:** Mem0 v1's in-place overwrite destroys historical memory. If an agent learns on October 24 that "Alice moved to Berlin," overwriting the fact that she lived in London makes it impossible for the agent to answer historical questions (*"Where did Alice live during the Q2 project?"*).
- **The Catastrophe of Unconstrained Accumulation:** Mem0 v2's additive log avoids data loss but creates memory clutter. When asked *"Where does Alice live?"*, vector search returns both *"Alice lives in London"* and *"Alice lives in Berlin"* with high cosine similarity. The LLM must guess which statement is current, frequently hallucinating or blending the two.
- **Graphiti’s Proven Success:** Graphiti’s bi-temporal modeling provides clean separation between current truth and historical fact. Filtering for `expired_at IS NULL` guarantees that only currently active beliefs are retrieved for standard queries, while historical queries can traverse back in time.

#### 3. The Precise Engram Adaptation
Engram implements native bi-temporal semantics directly within SurrealDB (ADR-08, ADR-11; `docs/spec/03-data-model.md`):
1. **Schema Fields on `fact` Relation:**
   - Valid World Time: `valid_from` (`datetime`), `valid_to` (`option<datetime>`), `time_precision` (`enum: day|month|year|exact`).
   - Transaction System Time: `recorded_at` (`datetime DEFAULT time::now()`), `expired_at` (`option<datetime>`).
   - Status & Lineage: `status` (`enum: active|superseded|retracted|pending`), `supersedes` (`option<record<fact>>`), `superseded_by` (`option<record<fact>>`).
2. **Soft Invalidation Semantics:** A superseded fact is never deleted. It is updated in place within the write transaction: `valid_to = new.valid_from`, `expired_at = time::now()`, `status = superseded`, `superseded_by = new.id`.
3. **Query Filtering:** Standard recall queries filter on `WHERE valid_to IS NONE AND status = 'active'`. When Engram’s temporal parser detects explicit historical requests (*"What was X in 2024?"* or an `as_of` timestamp parameter), the filter adjusts to:
   ```surql
   WHERE valid_from <= $as_of AND (valid_to IS NONE OR valid_to > $as_of)
   ```

---

### 3.7 Learning 7: Hub and Degree Damping in Graph Retrieval and Resolution

#### 1. What Prior Art Does (With Primary Evidence)
In Hindsight, multi-hop graph expansion is handled by non-recursive CTEs with LATERAL joins in PostgreSQL (`link_expansion.py:336-344`; [`docs/research/verification/V01-hindsight.md`](../research/verification/V01-hindsight.md) §2 F-01). In production issue `#3848` ([`links.py:97-101`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/memories/pg/links.py#L97-L101)), 36,000 unconstrained temporal link candidates produced 1.3 billion tuples, causing worker out-of-memory crashes. Hindsight resolved this by applying an inverse square root damping weight in `entity_resolver.py:190-201`:
$$\text{Weight} = \frac{1.0}{\sqrt{\max(\text{degree}, 1)}}$$

Similarly, Mem0 implemented quadratic degree damping on linked memories in [`main.py:1805-1823`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L1805-L1823) ([`docs/research/verification/V03-mem0.md`](../research/verification/V03-mem0.md) §3 Claim 3):
$$\text{Memory Count Weight} = \frac{1.0}{1.0 + 0.001 \times (N - 1)^2}$$
where $N$ is the number of linked memories connected to an entity.

#### 2. What Went Wrong or Right for Them
- **The Super-Node Problem:** In real-world conversational memory, generic entities like "User", "Assistant", "Hermes", "Project", or "Company" naturally accumulate thousands of edges. Without degree damping, any search matching one of these hub entities fans out across the entire database, pulling in hundreds of unrelated facts, blowing token budgets, and causing query planner timeouts.

#### 3. The Precise Engram Adaptation
Engram adopts degree damping across both entity resolution and graph recall (ADR-10, ADR-11; `docs/spec/05-retrieval.md`):
1. **Entity Resolution Damping:** When evaluating whether a new entity mention should merge into an existing entity based on shared co-occurrence edges, the co-occurrence score contribution is scaled by $1.0 / \sqrt{\max(\text{degree}, 1)}$.
2. **Graph Expansion Damping:** During Tier-3 graph expansion from seed entities, the traversal edge weight is adjusted dynamically:
   $$\text{EdgeWeight} = \frac{\text{base\_weight}}{\sqrt{\max(\text{count}(->\text{fact}), 1)}}$$
   Highly specific entities (e.g. `billing-service` with degree 4) propagate strong relevance signals, while ultra-connected hubs (e.g. `User` with degree 850) are heavily damped, preventing combinatorial graph fan-outs.
3. **Hard Traversal Hops:** Graph traversal is strictly bounded to 1 hop by default (`retrieval.graph_hops = 1`, configurable up to 2). Multi-hop BFS loops in application memory are prohibited.

---

### 3.8 Learning 8: 4-Way Multi-Signal Fusion (RRF $k=60$) & Cross-Encoder Reranking

#### 1. What Prior Art Does (With Primary Evidence)
Hindsight executes a 4-way retrieval pipeline across dense vectors, BM25, 1-hop graph link expansion, and temporal spreading (`recall.py:310-450`; [`docs/research/verification/V01-hindsight.md`](../research/verification/V01-hindsight.md) §3.4). Candidates from all four lists are fused via Reciprocal Rank Fusion ($k = 60$; `fusion.py:29`), followed by cross-encoder reranking (`ms-marco-MiniLM-L-6-v2`) with multiplicative adjustments centered at $0.5$ ([`reranking.py:287-305`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-api-slim/hindsight_api/engine/search/reranking.py#L287-L305)):
$$\text{FinalScore} = \text{Score}_{\text{base}} \times [1 + \alpha_r (\text{recency} - 0.5)] \times [1 + \alpha_t (\text{temporal} - 0.5)] \times [1 + \alpha_p (\text{proof\_norm} - 0.5)]$$
where $\text{proof\_norm} = \min\big(1.0, \max(0.0, 0.5 + \ln(\text{proof\_count}) / 10.0)\big)$.

In contrast, Mem0 uses an additive score formula (`scoring.py:60-140`; [`docs/research/verification/V03-mem0.md`](../research/verification/V03-mem0.md) §3 Claim 3) that sums raw cosine similarity, a sigmoid-normalized BM25 score, and an entity boost, dividing the sum by an ad-hoc dynamic divisor ($1.0 \to 2.0 \to 2.5$).

#### 2. What Went Wrong or Right for Them
- **The Fragility of Additive Normalization:** Mem0’s additive scoring requires manually tuning sigmoid midpoints ($5.0 \to 7.0 \to 9.0 \to 12.0$) and steepnesses across query lengths. Scores drift unpredictably as document lengths and vocabulary sizes shift, leading to inconsistent top-$k$ cutoffs.
- **The Stability of RRF:** Hindsight’s Reciprocal Rank Fusion ($1 / (k + rank)$) requires zero calibration and is completely invariant to raw score distributions across vector cosine, BM25, and graph distances.
- **The Cost of Local Cross-Encoders:** Bundling local cross-encoder models (`ms-marco-MiniLM-L-6-v2`) via PyTorch or ONNX Runtime in Python inflates container size by $>1\text{GB}$ and increases idle RAM usage. Hindsight’s slim Docker image explicitly dropped local ML models, delegating reranking to external endpoints.

#### 3. The Precise Engram Adaptation
Engram adopts weighted RRF in pure Rust while keeping the core binary lean (ADR-11, ADR-16; `docs/spec/05-retrieval.md`):
1. **Parallel SurrealQL Query:** For each recall request, Engram issues a single multi-statement query to SurrealDB returning ranked lists across: (1) Dense Vector k-NN on `fact.statement`, `observation`, and `episode`; (2) BM25 full-text hits on statements, summaries, and names; (3) Recent episodic turns.
2. **1-Hop Live Graph Expansion:** Seed entities (extracted from query keywords and top vector hits) expand 1 hop across active, hub-damped `fact` edges (`valid_to IS NONE`).
3. **Weighted RRF in Rust:** Candidate ranks are fused in Rust using weighted RRF with constant $k = 60$:
   $$RRF(d) = \sum_{c \in Channels} w_c \cdot \frac{1}{60 + rank_c(d)}$$
   with weights: Dense Vector = $1.0$, BM25 = $1.0$, Graph Expansion = $0.8$, Recency = $0.5$.
4. **MMR Diversity & Token Packing:** Fused candidates pass through Maximal Marginal Relevance ($\lambda = 0.7$) to eliminate repetitive phrasing, and are greedily packed into the configured token budget (`token_budget = 1200`).
5. **Decoupled Cross-Encoder:** In-process ONNX Runtime (`ort`) was evaluated and rejected (V01 §3.9, V06 F-03). Cross-encoder reranking is supported via an optional external HTTP endpoint (`rerank.enabled = false` by default), maintaining Engram's lean $\le 25\text{ MB}$ binary and $\le 650\text{ MB}$ uncompressed / $\le 160\text{ MB}$ compressed image budget [ADR-16].

---

## 4. Anti-Patterns Engram Deliberately Avoids

This section catalogs the 10 most damaging architectural anti-patterns identified across prior art implementations, detailing why each was adopted upstream, how it failed in production, and Engram’s concrete engineering defense.

### 4.1 Anti-Pattern 1: Poly-Store Coordinator Architecture
- **Description:** Attempting to orchestrate independent relational, graph, and vector database engines via an application-level Python middleware layer.
- **Why Prior Art Adopted It:** Cognee adopted this approach to support arbitrary pluggable storage combinations (e.g. SQLite + LanceDB + FalkorDB) without vendor lock-in.
- **Production Failure Mode:** As acknowledged in `add_data_points.py:325-336`, the lack of cross-store two-phase commit (2PC) guarantees that partial network or disk failures leave orphaned graph pointers and phantom vector entries that cannot be reconciled.
- **Engram Defense (ADR-01, ADR-02):** Unifies documents, graph relations, HNSW vector search, and BM25 full-text indexes inside SurrealDB 3.3.4 under single ACID transactions.

### 4.2 Anti-Pattern 2: Uncalibrated LLM Floating-Point Confidence
- **Description:** Requesting that an extraction LLM assign arbitrary floating-point numbers ($0.0 \dots 1.0$) to represent the subjective confidence of extracted statements.
- **Why Prior Art Adopted It:** Hindsight v1 attempted to filter low-confidence subjective assertions by sorting on LLM-assigned floats.
- **Production Failure Mode:** As proven by Hindsight's migration `g2h3i4j5k6l7` (2026-04-02), LLM confidence floats are uncalibrated noise: models output arbitrary floats that drift across completions, distorting rank fusion and bloating database indexes.
- **Engram Defense (ADR-08):** Eliminates LLM float confidence completely. Confidence is computed deterministically in Rust from the source trust hierarchy and empirical support counts.

### 4.3 Anti-Pattern 3: Multi-Call Extraction Tax on the Turn Path
- **Description:** Decomposing turn extraction into a cascade of granular LLM calls (node extraction, node dedup, edge extraction, edge dedup, timestamp extraction, attribute extraction).
- **Why Prior Art Adopted It:** Graphiti implemented this to isolate prompt complexity and maintain small JSON schemas.
- **Production Failure Mode:** Triggers 4 to 12+ LLM calls per conversational turn, incurring an estimated $0.02 to $0.15 in API token costs [estimated] and 3,000 to 8,000 ms of clock latency [estimated], creating unbearable lag in interactive agent sessions.
- **Engram Defense (ADR-07):** Batches turns in a background outbox worker (up to 4 turns or 20s idle) and executes a single structured JSON-schema call extracting entities, facts, and temporal intervals simultaneously.

### 4.4 Anti-Pattern 4: Destructive Overwrites and Unbounded Contradictory Pile-Up
- **Description:** Either destructively updating database records in place (SQL `UPDATE` / `DELETE`) or appending all assertions into an unconstrained log without invalidation.
- **Why Prior Art Adopted It:** Mem0 v1 used in-place updates to keep storage tiny; Mem0 v2 moved to an additive-only log to prevent accidental data loss.
- **Production Failure Mode:** In-place updates permanently destroy historical truth, making time-travel queries impossible. Additive logs allow competing contradictory statements to accumulate, causing hallucinations during recall.
- **Engram Defense (ADR-08):** Implements native bi-temporal soft invalidation. Superseded edges remain in SurrealDB with `valid_to = new.valid_from`, `expired_at = now`, and `status = superseded`, preserving complete audit history while keeping active recall clean.

### 4.5 Anti-Pattern 5: The 1-Turn Prefetch Lag
- **Description:** Designing `prefetch()` to only drain an in-memory cache populated by `queue_prefetch()` at the end of the previous turn, prohibiting network calls on the prefetch path.
- **Why Prior Art Adopted It:** Cognee and early Hermes drafts attempted to guarantee $<1\text{ ms}$ prefetch execution by serving only pre-computed context.
- **Production Failure Mode:** Turn 1 suffers from total cold-start blindness (injecting empty context), and subsequent turns inject memories recalled for the *previous* turn's question rather than the current prompt.
- **Engram Defense (ADR-13):** `prefetch()` executes a live hybrid recall query against local SurrealDB under a strict 1,500 ms deadline, falling back to cached results only if the deadline expires.

### 4.6 Anti-Pattern 6: In-Process C++ ML Runtimes in Core Service
- **Description:** Statically embedding heavy C++ machine learning runtimes (ONNX Runtime, LibTorch, `ort`) into the primary service binary.
- **Why Prior Art Adopted It:** Hindsight v1 bundled local cross-encoders to eliminate external network dependencies for reranking.
- **Production Failure Mode:** Links massive shared libraries (`libonnxruntime.so` $>100\text{ MB}$), complicates cross-compilation across musl/aarch64 targets, inflates idle RSS by hundreds of megabytes, and exposes the service to C++ memory bugs.
- **Engram Defense (ADR-06, ADR-11, ADR-16):** Keeps the Rust binary lean ($\le 25\text{ MB}$, $\le 300$ crates). Embeddings and cross-encoders are queried via lightweight asynchronous HTTP calls to local endpoints (Ollama or TEI).

### 4.7 Anti-Pattern 7: Discarded LLM Extractions & Dead-Code Mappings
- **Description:** Instructing an LLM prompt to generate complex structured relationships, but failing to persist or map the returned fields in application code.
- **Why Prior Art Adopted It:** Mem0 v2 refactored its prompt to request `linked_memory_ids` and created `uuid_mapping`, intending to implement graph linking over vectors.
- **Production Failure Mode:** In `mem0/memory/main.py:1017-1041`, `linked_memory_ids` is silently ignored during persistence, and `uuid_mapping` is dead code, wasting prompt tokens while deceiving users that a graph exists.
- **Engram Defense (ADR-07, ADR-09):** The Rust ingest pipeline enforces end-to-end schema validation: every primed integer handle returned by the model is resolved back to a SurrealDB Record ID and persisted as a `fact` edge, or logged as an error.

### 4.8 Anti-Pattern 8: In-Memory Python Graph Traversal
- **Description:** Fetching raw node and edge collections from a database and reconstructing an in-memory graph data structure (`CogneeGraph`) in Python to run custom search algorithms.
- **Why Prior Art Adopted It:** Cognee implemented `brute_force_triplet_search` to avoid writing backend-specific Cypher/Gremlin graph traversal queries.
- **Production Failure Mode:** Sucks thousands of records across the network into application RAM, executes slow interpreted Python loops (`heapq.nsmallest`), and bypasses database indexes and query planners.
- **Engram Defense (ADR-11):** Bounded graph expansion is executed directly inside SurrealDB's database kernel via native edge pointer syntax (`->fact->entity`).

### 4.9 Anti-Pattern 9: Blind Character-Count Message Truncation
- **Description:** Truncating incoming user turns at hard, arbitrary character boundaries (e.g. 450 characters) to prevent embedding models from crashing.
- **Why Prior Art Adopted It:** Mem0’s Hermes integration (`_SYNC_MSG_MAX_CHARS = 450`) introduced hard truncation because small models like `bge-small-zh-v1.5` (512 token limit) threw HTTP 500 errors on long turns.
- **Production Failure Mode:** Turns over 450 characters are silently clipped, dropping complex code blocks, technical specifications, and key conversational instructions from long-term memory.
- **Engram Defense (ADR-06, ADR-07):** Ingests full turn texts without character truncation. Standard embeddings use `qwen3-embedding:0.6b` with a native 32,768-token context window.

### 4.10 Anti-Pattern 10: Silent Phone-Home Telemetry
- **Description:** Embedding telemetry tracking libraries that report usage metrics, host environments, or slow queries back to external corporate servers.
- **Why Prior Art Adopted It:** Mem0 implemented `telemetry.mem0.ai` tracking and `notices.py` alerts to gather operational telemetry and promote commercial platform features.
- **Production Failure Mode:** Leaks agent activity metadata over the network, violates offline isolation requirements, and introduces network failure points in firewalled enterprise deployments.
- **Engram Defense (ADR-14):** Enforces a strict zero-telemetry policy. Engram contains zero phone-home tracking code, publishing operational insights exclusively via local JSON tracing and Prometheus `/metrics`.

---

## 5. Ideas Parked for Post-v1

The following advanced cognitive patterns were evaluated and deliberately deferred from Engram v1 to maintain architectural focus and a lean binary footprint.

| Idea | Inspiration Source | What It Does | Concrete Trigger to Justify Implementation |
|---|---|---|---|
| **Mental Models & Directives** | Hindsight (`mental_models`, `directives`; R01 §1.1) | Synthesizes high-level behavioral axioms and operational guidelines from accumulated observations. | Bank exceeds 500 consolidated observations and user requests strategic behavioral adaptations. |
| **Autonomous Reflect Agent** | Hindsight (`reflect/tools.py`; R01 §5.1) | Autonomous multi-step tool loop exploring graph paths to answer complex reflective queries. | Primary recall fails to answer cross-session multi-hop synthesis queries across >5 sessions. |
| **Topological Community Detection** | Graphiti (`CommunityNode`, LPA; R07 §A.5) | Groups graph entities into macro-clusters via Label Propagation, maintaining hierarchical summaries. | Bank exceeds 10,000 entities and entity retrieval degrades due to semantic topic collision. |
| **Temporal Narrative Sagas** | Graphiti (`SagaNode`; R07 §A.5) | Chained episodic arcs linking sequential events across long-running project threads. | Episodic memory exceeds 1,000 turns across a single project thread requiring narrative chronological tracking. |
| **PageRank & Trace Feedback** | SurrealDB Agent Memory (Signals 5 & 7; R07 §B.5) | Evaluates graph walk centrality and historical turn utility signals to reweight recalled facts. | Candidate pools consistently exceed 100 items and standard RRF precision drops on ambiguous queries. |
| **HyDE Fallback Routing** | SurrealDB Agent Memory (Tier 4; R07 §B.5) | Generates hypothetical document completions to seed vector search on sparse queries. | Standard hybrid retrieval returns zero hits for abstract or terminology-mismatched queries. |
| **Entity-Aware Response Cache** | SurrealDB Agent Memory (Tier 2; R07 §B.5) | Caches query responses, invalidating entries when underlying entity facts are superseded. | Agent executes high-frequency repetitive tool-calling queries with measurable LLM latency cost. |
| **Embedded In-Process Embeddings** | FastEmbed / Candle (R06 §11.1) | Generates vector embeddings directly within the Rust process via ONNX/Candle without Ollama. | User explicitly demands a fully zero-dependency single-binary CLI distribution without local Ollama. |

---

## 6. Benchmark Landscape & Evaluation Rigor

Evaluating agent memory architectures requires strict separation between verified empirical performance and vendor marketing claims. The table below compiles verified scores from published papers and formal repository benchmarks.

| Framework | Benchmark Split | Headline / Mean Score | Strict Score | Answering Model | Judge Model | Context Budget & Retrieval Parameters | Verified Source |
|---|---|---|---|---|---|---|---|
| **SurrealDB Agent Memory** | BEAM 1M | **77.2%** (Kendall $\tau$) | **57.1%** | Gemini 3.8 Flash | Gemini 3.5 Flash Lite | Top 50 recalled facts; strict requires 1.0 on all rubric criteria | `benchmarks.md:119` (V07 §3.5) |
| **Exabase** | BEAM 1M | **75.0%** | **48.0%** | Gemini 3 Flash Prev | Gemini 2.5 Flash Lite | ~18,900 context tokens | Exabase Tech Report (V07 §3.5) |
| **Hindsight** | BEAM 1M | **73.9%** | **48.4%** | Gemini 3.1 Pro Prev | Gemini 2.5 Flash Lite | ~23,900 context tokens; 4-way hybrid retrieval | `agent-memory-benchmark` (V07 §3.5) |
| **Mem0** | BEAM 1M | **64.1%** | **40.1%** | GPT-5 | GPT-5 | Top-200 memories injected into context | `memory-benchmarks` (V07 §3.5) |
| **Honcho** | BEAM 1M | **63.1%** | **41.4%** | Claude Haiku 4.5 | Claude Sonnet 4.5 | Agentic tool-calling retrieval (up to 20 calls) | `honcho-benchmarks` (V07 §3.5) |
| **HydraDB** | BEAM 1M | **82.0%** (unweighted) | UNVERIFIED | Unstated | GPT-5.4 | Category average; per-question evaluation logs omitted | `benchmarks.hydradb.com` (V07 §3.5) |
| **Zep (Graphiti)** | LongMemEval | **71.2%** (Overall) | N/A | GPT-4o | GPT-4o-judge | +18.3% over raw context; 90% latency reduction | arXiv:2501.13956 Table 2 (V07 §2 F-03) |
| **Cognee** | LongMemEval-S | **64.2%** | N/A | GPT-4o-mini | GPT-4o | Graph + vector extraction pipeline | Cognee Eval Repo (V07 §3.5) |
| **Hindsight** | LongMemEval-s | **94.6%** | N/A | GPT-4o | GPT-4o | 4-way hybrid retrieval + cross-encoder reranking | `2026-03-23-benchmark.mdx` (V01 §4) |
| **Mem0** | LoCoMo | **67.00%** (Overall J) | N/A | GPT-4o-mini | GPT-4o | 51.15% multi-hop (Mem0g scored 48.72%); 1.44s p95 latency | arXiv:2504.19413 Table 1 (V03 §3 Claim 4) |

### 6.1 The 11 Benchmark Manipulation Practices
Forensic audits of agent memory benchmarks ([`docs/research/verification/V07-temporal-kg-and-evals.md`](../research/verification/V07-temporal-kg-and-evals.md) §3.6; SurrealDB `benchmarks.md:248-299`) cataloged eleven common practices that distort published memory scores:
1. **Lenient Grading:** Counting partial matches ($0.5$ marks) as full passes, which artificially inflates headline pass rates by **+15% to 28%** over strict scoring.
2. **Dropping Adversarial / Abstention Queries:** Omitting questions where the correct response is "I do not have enough information", masking hallucination rates.
3. **Category Prompt Leakage:** Providing the question's category (e.g. `[temporal-reasoning]`) directly to the answering prompt, allowing models to activate specialized reasoning modes impossible in production.
4. **Disproportionate Context Budgets:** Comparing one vendor using top-5 retrieval ($<1\text{k}$ tokens) against another using top-200 memories ($>20\text{k}$ tokens).
5. **Misconfiguring Competitors:** Running baseline competitors with unoptimized single-shot vector search while evaluating their own platform with custom multi-pass hybrid pipelines.
6. **Judge Model Drift:** Evaluating against weaker judges that fail to detect subtle chronological errors.
7. **Ad-Hoc Metric Averaging:** Averaging accuracy across unweighted task splits rather than reporting strict macro-F1.
8. **Cherry-Picked Test Splits:** Evaluating on a small subset of easy dialogue sessions while omitting long-horizon failure cases.
9. **Unreported Cost & Latency:** Reporting high accuracy while masking that each query took 30 seconds of tool calls and an estimated $0.50 in API tokens [estimated].
10. **Pre-Indexed Answers:** Indexing Q&A pairs directly into the retrieval database prior to testing.
11. **Omission of Raw Evaluation Traces:** Publishing summary percentages without releasing per-question prompt-response logs (e.g. HydraDB's unverified 82.0% score).

### 6.2 Why Engram Reports Strict Scores
Engram enforces **strict evaluation rigor** across its automated harness (ADR-19; `docs/spec/10-testing-evaluation.md`):
- **Strict Binary Scoring:** A test question passes if and only if **all** required factual assertions match the ground-truth rubric. Zero partial credit is awarded.
- **Event Ordering via Kendall's $\tau$:** Timeline reconstruction is graded strictly by relative temporal rank correlation.
- **Preserved Abstention Splits:** Test suites retain all unanswerable and adversarial questions to penalize memory hallucination.
- **Fixed Context Token Budget:** Injected recall context is strictly capped at `token_budget` (1,200 tokens), preventing context-stuffing distortions.
- **Zero-Cost Deterministic CI Gate:** Every git push runs 49 deterministic synthetic contradiction and temporal scenarios (`S01–S49`) against an in-memory SurrealDB instance (`surreal start --memory`) with mocked LLM extractions, running in $<500\text{ ms}$ at zero API dollar cost.

---

## 7. Bibliography & Primary References

### Academic Papers
1. **BEAM Benchmark:** Tavakoli, M., et al. (2025). *Beyond a Million Tokens: Benchmarking and Enhancing Long-Term Memory in LLMs.* arXiv preprint [arXiv:2510.27246](https://arxiv.org/abs/2510.27246).
2. **Zep Knowledge Graph:** Rasmussen, P., Paliychuk, P., & Chalef, D. (2025). *Zep: A Temporal Knowledge Graph Architecture for Agent Memory.* arXiv preprint [arXiv:2501.13956](https://arxiv.org/abs/2501.13956).
3. **Mem0 Architecture:** Chhikara, P., et al. (2025). *Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory.* arXiv preprint [arXiv:2504.19413](https://arxiv.org/abs/2504.19413).
4. **LongMemEval Benchmark:** Wu, D., Wang, Y., Yu, J., Zhang, Z., Chang, K. W., & Yu, M. (2024). *LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory.* ICLR 2025. arXiv preprint [arXiv:2410.10813](https://arxiv.org/abs/2410.10813).
5. **LoCoMo Benchmark:** Maharana, A., et al. (2024). *Evaluating Very Long-Term Conversational Memory of LLM Agents.* ACL 2024. arXiv preprint [arXiv:2402.17753](https://arxiv.org/abs/2402.17753).
6. **MemoryAgentBench:** Hu, Y., Wang, Y., & McAuley, J. (2025). *Evaluating Memory in LLM Agents via Incremental Multi-Turn Interactions.* arXiv preprint [arXiv:2507.05257](https://arxiv.org/abs/2507.05257).
7. **A-MEM (Zettelkasten):** Xu, W., et al. (2025). *A-MEM: Agentic Memory for LLM Agents.* arXiv preprint [arXiv:2502.12110](https://arxiv.org/abs/2502.12110).
8. **MemGPT Architecture:** Packer, C., et al. (2023). *MemGPT: Towards LLMs as Operating Systems.* arXiv preprint [arXiv:2310.08560](https://arxiv.org/abs/2310.08560).
9. **Generative Agents (Reflection):** Park, J. S., et al. (2023). *Generative Agents: Interactive Simulacra of Human Behavior.* arXiv preprint [arXiv:2304.03442](https://arxiv.org/abs/2304.03442).

### Repositories & Upstream Documentation
1. **Hindsight Repository:** Vectorize.io. Inspected local clone at `vectorize-io/hindsight`.
   - Migration `g2h3i4j5k6l7`: `hindsight-api-slim/hindsight_api/alembic/versions/g2h3i4j5k6l7_remove_opinion_fact_type.py`
   - Entity resolver & hub damping: `hindsight_api/engine/memories/pg/entity_resolver.py:122-300, 1290-1353`
   - Link expansion & LATERAL join: `hindsight_api/engine/memories/pg/link_expansion.py:336-366`
   - Standalone Dockerfile: `docker/standalone/Dockerfile:1-462`
2. **Cognee Repository:** Topoteretes. Inspected local clone at `topoteretes/cognee` (tag `v1.6.5`, commit `37f788bd287750e10d7610173e5332b3843f6ebd`).
   - Cross-store consistency comment: `cognee/tasks/storage/add_data_points.py:325-336`
   - SearchType enum: `cognee/modules/search/types/SearchType.py:5-29`
   - In-memory graph structure: `cognee/modules/graph/cognee_graph/CogneeGraph.py:22, 428-515`
   - Hermes integration: `topoteretes/cognee-integrations` (`integrations/hermes-agent`, commit `ccfb0e4e3fa8f3ce09c023d258c205ca972e48a8`)
3. **Mem0 Repository:** Mem0 AI. Inspected local clone at `mem0ai/mem0` (branch `v2.2.1` and historical tag `v1.0.11`).
   - Additive prompt: `mem0/configs/prompts.py:468-944`
   - Ingestion loop & dead code: `mem0/memory/main.py:937-941, 1017-1041`
   - Degree damping & scoring: `mem0/memory/main.py:1805-1823`, `mem0/utils/scoring.py:16-140`
   - Hermes integration: `integrations/hermes-plugin-mem0/__init__.py:30, 43, 294-304`
4. **Graphiti Repository:** Zep Software, Inc. Inspected upstream repository `github.com/getzep/graphiti`.
   - Bi-temporal edge model: `graphiti_core/edges.py:263-290`
   - Invalidation logic: `graphiti_core/utils/maintenance/edge_operations.py:748-783`
   - Contradiction prompt: `graphiti_core/prompts/dedupe_edges.py:44-115`
   - MinHash/LSH entity deduplication: `graphiti_core/utils/maintenance/dedup_helpers.py:31-381`
5. **SurrealDB Agent Memory Documentation:** SurrealDB Ltd. (2026).
   - Deep Dive: `https://surrealdb.com/agent-memory/deep-dive`
   - Temporal Model: `https://surrealdb.com/agent-memory/temporal`
   - Recall Specification: `https://surrealdb.com/agent-memory/recall`
   - Benchmarks Audit: `https://surrealdb.com/agent-memory/benchmarks`
6. **Hermes Agent Codebase:** Nous Research. Inspected local install at `~/.hermes/hermes-agent` (version `0.22.4`).
   - Provider contract: `agent/memory_provider.py:1-226`
   - Memory manager & executors: `agent/memory_manager.py:42-57, 441-489`
   - Turn execution loop: `run_agent.py:918-921`

---

## 8. Resolved Design Issues (history)

### 8.1 Verification Alignment & Technical Consensus
Historical design adjustments and audit resolutions cross-referenced against [`docs/spec/00-decisions.md`](00-decisions.md) (ADR-01 through ADR-19):

All verification audit findings from `VS1-consistency.md` (Finding F-18) and `VS5-coverage-quality.md` (Finding M-06) have been resolved:
1. **Canonical Specification Cross-References (M-06, F-18):** All obsolete draft file references throughout §2 (Pattern Matrix) and §3 (Deep Dives) have been replaced with canonical filenames matching `00-decisions.md §3.8` and the `docs/spec/` tree: `02-architecture.md`, `03-data-model.md`, `04-ingestion-pipeline.md`, `05-retrieval.md`, `06-api-and-mcp.md`, `07-hermes-plugin.md`, `08-deployment-operations.md`, `09-observability.md`, and `10-testing-evaluation.md`.
2. **Empirical Cost & Latency Estimation Labels:** All unverified operational costs and latency figures from prior art systems (such as Graphiti's multi-call extraction overhead and benchmark execution tokens) are explicitly labeled as `[estimated]`.
3. **Packaging Budget Alignment:** Reconciled container image size targets in §3.8 with ADR-16 ($\le 650\text{ MB}$ uncompressed / $\le 160\text{ MB}$ compressed pull; measured 584 MB / 140.76 MB).
4. **Architecture & Schema Compliance:** Confirmed exact agreement with ADR-01 (topology), ADR-02 (CBOR RPC client), ADR-03 (process supervision), ADR-07 (single extraction call), ADR-08 (deterministic truth maintenance & authority guard), ADR-09 (closed 15-predicate vocabulary), ADR-10 (entity resolution cascade), ADR-11 (hybrid RRF + MMR), ADR-13 (Hermes plugin contract), ADR-14 (purge endpoint and access policy), and ADR-19 (strict evaluation harness and calibrated local 8B vs frontier targets).
