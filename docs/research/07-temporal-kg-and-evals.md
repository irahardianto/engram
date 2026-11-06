# Research Report 07: Temporal Knowledge Graphs, SurrealDB Agent Memory, Evaluations, and Cognitive Patterns

> **Verification status:** PASS-WITH-FIXES — corrected on 2026-10-24 per [V07 report](verification/V07-temporal-kg-and-evals.md). Corrections are marked with *(corrected)*.

**Project:** Engram (Hermes Agent Long-Term Memory Layer)  
**Author:** Engram Research Team (R7)  
**Date:** October 2026  
**Status:** Completed  
**Deliverable Path:** `docs/research/07-temporal-kg-and-evals.md`  

---

## Executive Summary

This report investigates four critical architectural inputs for Engram:
1. **Graphiti / Zep Bi-Temporal Knowledge Graph:** The mechanics of bi-temporal modeling (`valid_at`/`invalid_at` vs. `created_at`/`expired_at`), edge invalidation algorithms, entity resolution cascading (exact, MinHash/LSH, LLM), hybrid search with 5 rerankers (RRF, MMR, node-distance, episode-mentions, cross-encoder), and ingestion cost bottlenecks.
2. **SurrealDB Agent Memory Architecture:** SurrealDB's unified single-engine memory substrate, tri-temporal model (`VERSION`, `as_of`, `valid_from`/`valid_until`), typed fact primitives (attribute, relation, action), six experiential categories, provenance tracing (decision, retrieval, response), and 4-tier recall routing over 7 signals.
3. **Agent Memory Evaluation Landscape:** Deep analysis of LongMemEval (arXiv:2410.10813), LoCoMo (arXiv:2402.17753), BEAM 1M/10M (arXiv:2510.27246), MemoryAgentBench (arXiv:2507.05257 *(corrected)*), vendor scores (SurrealDB, Hindsight, Mem0, Exabase, Honcho, HydraDB), and the Mem0 vs. Zep LoCoMo controversy. We design a concrete v1 evaluation harness for Engram with CI regression gating.
4. **Cognitive Patterns:** Assessment of MemGPT/Letta memory tiers, A-MEM Zettelkasten slip-box linking (arXiv:2502.12110), reflection/consolidation lifecycles, Ebbinghaus forgetting curves, MMR diversity reranking, query rewriting/HyDE, and token-budgeted context packing.

Every section concludes with actionable **Adopt / Adapt / Reject** recommendations tailored to Engram’s single-engine SurrealDB implementation.

---

## Table of Contents

- [Section A: Graphiti / Zep Temporal Knowledge Graph](#section-a-graphiti--zep-temporal-knowledge-graph)
  - [A.1 The Bi-Temporal Model: World Time vs. Transaction Time](#a1-the-bi-temporal-model-world-time-vs-transaction-time)
  - [A.2 Edge Invalidation and Contradiction Detection](#a2-edge-invalidation-and-contradiction-detection)
  - [A.3 Entity Resolution and Deduplication Pipeline](#a3-entity-resolution-and-deduplication-pipeline)
  - [A.4 Episode Ingestion Types](#a4-episode-ingestion-types)
  - [A.5 Community Detection and Hierarchical Sagas](#a5-community-detection-and-hierarchical-sagas)
  - [A.6 Hybrid Search and Reranker Implementations](#a6-hybrid-search-and-reranker-implementations)
  - [A.7 Temporal Resolution of Relative Expressions](#a7-temporal-resolution-of-relative-expressions)
  - [A.8 Node and Edge Schemas (Persisted Attributes)](#a8-node-and-edge-schemas-persisted-attributes)
  - [A.9 LLM Ingestion Cost Analysis](#a9-llm-ingestion-cost-analysis)
  - [A.10 Recommendations for Engram (Section A)](#a10-recommendations-for-engram-section-a)
- [Section B: SurrealDB Native Agent Memory Architecture](#section-b-surrealdb-native-agent-memory-architecture)
  - [B.1 Single-Engine Multi-Model Substrate](#b1-single-engine-multi-model-substrate)
  - [B.2 Typed Memory Primitives and Categorization](#b2-typed-memory-primitives-and-categorization)
  - [B.3 Tri-Temporal System and Reconciliation Rules](#b3-tri-temporal-system-and-reconciliation-rules)
  - [B.4 Provenance, Traces, and Explicit Uncertainty](#b4-provenance-traces-and-explicit-uncertainty)
  - [B.5 Four-Tier Recall Router and 7 Fused Signals](#b5-four-tier-recall-router-and-7-fused-signals)
  - [B.6 Tenancy and Isolation](#b6-tenancy-and-isolation)
  - [B.7 Recommendations for Engram (Section B)](#b7-recommendations-for-engram-section-b)
- [Section C: Agent Memory Evaluation and Benchmark Harness](#section-c-agent-memory-evaluation-and-benchmark-harness)
  - [C.1 Benchmark Anatomy: LongMemEval, LoCoMo, BEAM, MemoryAgentBench](#c1-benchmark-anatomy-longmemeval-locomo-beam-memoryagentbench)
  - [C.2 Published Industry Benchmark Results](#c2-published-industry-benchmark-results)
  - [C.3 The Mem0 vs. Zep LoCoMo Controversy and Benchmark Rigging](#c3-the-mem0-vs-zep-locomo-controversy-and-benchmark-rigging)
  - [C.4 Proposed Engram v1 Evaluation Harness](#c4-proposed-engram-v1-evaluation-harness)
  - [C.5 Recommendations for Engram (Section C)](#c5-recommendations-for-engram-section-c)
- [Section D: Adjacent Cognitive Memory Patterns](#section-d-adjacent-cognitive-memory-patterns)
  - [D.1 MemGPT / Letta Memory Tiers](#d1-memgpt--letta-memory-tiers)
  - [D.2 A-MEM: Zettelkasten-Style Memory Linking](#d2-a-mem-zettelkasten-style-memory-linking)
  - [D.3 Reflection and Periodic Consolidation](#d3-reflection-and-periodic-consolidation)
  - [D.4 Memory Decay and Forgetting Curves](#d4-memory-decay-and-forgetting-curves)
  - [D.5 MMR Diversity in Retrieval](#d5-mmr-diversity-in-retrieval)
  - [D.6 Query Rewriting and HyDE](#d6-query-rewriting-and-hyde)
  - [D.7 Token-Budgeted Context Packing](#d7-token-budgeted-context-packing)
  - [D.8 Recommendations for Engram (Section D)](#d8-recommendations-for-engram-section-d)
- [References and Citations](#references-and-citations)

---

## Section A: Graphiti / Zep Temporal Knowledge Graph

Graphiti is Zep’s open-source temporal knowledge graph engine, published under the Apache-2.0 license ([`github.com/getzep/graphiti`](https://github.com/getzep/graphiti)) and documented in the paper *"Zep: A Temporal Knowledge Graph Architecture for Agent Memory"* ([arXiv:2501.13956](https://arxiv.org/abs/2501.13956)). To understand its internal implementation, we cloned the repository shallowly into `/tmp/graphiti` and analyzed the core logic under `graphiti_core`.

### A.1 The Bi-Temporal Model: World Time vs. Transaction Time

Graphiti models temporality along two orthogonal axes:
1. **Valid Time (World Time):** The interval during which a fact was true in the physical world.
2. **Transaction Time (System Time):** The interval during which the fact was recorded and considered active by the database engine.

In `graphiti_core/edges.py#L263-L290`, `EntityEdge` defines this bi-temporal split:

```python
class EntityEdge(Edge):
    name: str = Field(description='name of the edge, relation name')
    fact: str = Field(description='fact representing the edge and nodes that it connects')
    fact_embedding: list[float] | None = Field(default=None)
    episodes: list[str] = Field(default=[])
    
    # --- System / Transaction Time ---
    created_at: datetime  # Inherited from Edge: when edge was inserted into the graph
    expired_at: datetime | None = Field(
        default=None, 
        description='datetime of when the edge was invalidated in the database'
    )
    
    # --- World / Valid Time ---
    valid_at: datetime | None = Field(
        default=None,
        description='datetime of when the fact became true in the world'
    )
    invalid_at: datetime | None = Field(
        default=None,
        description='datetime of when the fact stopped being true in the world'
    )
    reference_time: datetime | None = Field(
        default=None, 
        description='reference timestamp from the episode that produced this edge'
    )
```

#### Exact Semantics:
- **`valid_at` vs. `created_at`:** `valid_at` reflects real-world validity. If a user states on 2026-10-24: *"I lived in London from 2021 to 2023"*, `valid_at` is `2021-01-01T00:00:00Z`, while `created_at` is `2026-10-24T12:00:00Z`.
- **`invalid_at` vs. `expired_at`:** `invalid_at` represents real-world cessation (`2023-12-31T23:59:59Z`). In contrast, `expired_at` is the system clock time at which the engine invalidated the edge in the graph. If a user was previously recorded as living in London, and a new episode on 2026-10-24 reveals they moved to Berlin, `expired_at` is set to `2026-10-24T12:00:00Z` (the moment the database learned of the invalidation).
- **Future Assertions:** Future plans or promises (*"I will relocate to Tokyo in December 2027"*) do **not** set `valid_at` to the future date. Graphiti anchors `valid_at` to the *statement's reference time*, preserving the future date inside the fact string.

### A.2 Edge Invalidation and Contradiction Detection

Graphiti handles edge contradictions via a combination of LLM classification and deterministic temporal interval comparisons (`/tmp/graphiti/graphiti_core/utils/maintenance/edge_operations.py#L720-L785` and `/tmp/graphiti/graphiti_core/prompts/dedupe_edges.py`).

#### 1. Invalidation Candidate Selection (`edge_operations.py#L864-L985`):
When a new edge $e_{new}$ is extracted, Graphiti builds two candidate sets:
- `related_edges`: Edges with identical source and target endpoints, evaluated for exact or semantic duplication.
- `existing_edges` (`edge_invalidation_candidates`): Surrounding edges connected to the entities, evaluated for semantic contradiction.

#### 2. The Contradiction Prompt (`prompts/dedupe_edges.py#L44-L115`):
The LLM receives `existing_edges`, `edge_invalidation_candidates`, and `new_edge`. Key system instructions and constraints include:

> **System Prompt:**  
> `"You are a fact deduplication assistant. NEVER mark facts as contradicted unless the new fact explicitly makes the old fact false."`  
>  
> **Key Rules Quoted from Prompt:**  
> - *"NEVER mark facts as duplicates if they have key differences, particularly around numeric values, dates, or key qualifiers."*  
> - *"Only mark a fact as contradicted when the NEW FACT and the existing fact cannot both be true."*  
> - *"Do NOT treat additional activity, progress, status, or project-update facts as contradictions of role, ownership, responsibility, membership, or assignment facts. A person doing work on a project is compatible with that person remaining responsible for, owning, leading, or being the DRI for the project."*  
> - *"A contradiction requires explicit evidence that the old fact stopped being true or was replaced, such as clear termination, replacement, transfer, or mutually exclusive current-state language."*  
> - *"Do NOT infer contradiction from recency alone, episode dates, meeting dates, weekly snapshots, section headings such as 'updates' or 'status changes', or a new event involving the same entities."*

The LLM returns an `EdgeDuplicate` schema (`prompts/dedupe_edges.py#L25-L34`):
```python
class EdgeDuplicate(BaseModel):
    duplicate_facts: list[int]      # Indices from EXISTING FACTS only
    contradicted_facts: list[int]   # Indices from full range (EXISTING or INVALIDATION CANDIDATES)
```

#### 3. Deterministic Invalidation Resolution (`edge_operations.py#L748-L783`):
Once the LLM identifies contradiction candidate indices, Python code enforces temporal boundaries rather than blindly overwriting:

```python
def resolve_edge_contradictions(
    resolved_edge: EntityEdge, invalidation_candidates: list[EntityEdge]
) -> list[EntityEdge]:
    invalidated_edges: list[EntityEdge] = []
    for edge in invalidation_candidates:
        edge_invalid_at_utc = ensure_utc(edge.invalid_at)
        resolved_edge_valid_at_utc = ensure_utc(resolved_edge.valid_at)
        edge_valid_at_utc = ensure_utc(edge.valid_at)
        resolved_edge_invalid_at_utc = ensure_utc(resolved_edge.invalid_at)

        # Check if intervals are already disjoint (non-overlapping)
        if (
            edge_invalid_at_utc is not None
            and resolved_edge_valid_at_utc is not None
            and edge_invalid_at_utc <= resolved_edge_valid_at_utc
        ) or (
            edge_valid_at_utc is not None
            and resolved_edge_invalid_at_utc is not None
            and resolved_edge_invalid_at_utc <= edge_valid_at_utc
        ):
            continue

        # If new edge is strictly later, invalidate the old edge
        elif (
            edge_valid_at_utc is not None
            and resolved_edge_valid_at_utc is not None
            and edge_valid_at_utc < resolved_edge_valid_at_utc
        ):
            edge.invalid_at = resolved_edge.valid_at
            edge.expired_at = edge.expired_at if edge.expired_at is not None else utc_now()
            invalidated_edges.append(edge)

    return invalidated_edges
```

### A.3 Entity Resolution and Deduplication Pipeline

Graphiti’s entity resolution (`graphiti_core/utils/maintenance/node_operations.py` and `dedup_helpers.py`) uses a 4-tier pipeline to prevent entity bloat without blowing the LLM budget:

1. **Candidate Retrieval (`node_operations.py#L456-L632`):**
   - **Identity Properties:** If configured (e.g. `email`, `user_id`), exact attribute lookup runs via `_lookup_node`.
   - **Exact Name Match:** Calls `EntityNode.get_by_names(driver, names, group_ids)`.
   - **Cosine Semantic Search:** Generates embeddings for `node.name` via `embedder.create_batch(queries)`. Queries the graph vector index (`node_similarity_search`) with fixed constants:
     - `NODE_DEDUP_CANDIDATE_LIMIT = 15` (`node_operations.py#L67`)
     - `NODE_DEDUP_COSINE_MIN_SCORE = 0.6` (`node_operations.py#L68`)

2. **Deterministic Exact Match (`dedup_helpers.py#L332-L350`):**
   - Normalizes strings via `_normalize_string_exact` (lowercase, whitespace collapse).
   - If exactly one candidate matches: resolves immediately and promotes node attributes (`_promote_resolved_node`).
   - If $>1$ candidate matches: marks as ambiguous and escalates to LLM.

3. **Deterministic Fuzzy Matching via MinHash / LSH (`dedup_helpers.py#L351-L381`):**
   - **Entropy Gate (`_has_high_entropy`):** To avoid false-positive matches on short or generic names (e.g., "Sam", "AI", "App"), fuzzy matching runs **only** if:
     - Name length $\ge 6$ characters AND word count $\ge 2$ tokens, OR
     - Character Shannon entropy $\ge 1.5$ (`_NAME_ENTROPY_THRESHOLD = 1.5`).
   - **Shingling & Signatures:** Computes 3-gram character shingles (`_shingles`), 32 MinHash permutations (`_MINHASH_PERMUTATIONS = 32`), and Locality-Sensitive Hashing bands of size 4 (`_MINHASH_BAND_SIZE = 4`).
   - **Jaccard Threshold:** Matches if Jaccard similarity $\ge 0.9$ (`_FUZZY_JACCARD_THRESHOLD = 0.9`). If met, automatically resolves without calling an LLM.

4. **LLM Deduplication Fallback (`node_operations.py#L649-L750` & `prompts/dedupe_nodes.py`):**
   - Unresolved entities are sent in batch to `dedupe_nodes.nodes`.
   - Context includes previous episode turns, current message, new entity with type description, and existing candidate entities with their 120-char summaries.
   - Guardrails: If an entity refers to a distinct concept (e.g., "Java" programming language vs. "Java" island in Indonesia), the LLM must return `duplicate_candidate_id = -1`.

### A.4 Episode Ingestion Types

In `graphiti_core/nodes.py#L54-L78`, Graphiti defines four ingestion formats via `EpisodeType`:
- **`message`:** Dialogue turn formatted as `"actor: content"` (e.g., `"user: Let's use Python 3.12"`).
- **`json`:** Structured JSON string containing arbitrary nested key-value objects.
- **`text`:** Unstructured plain text (documents, email bodies, notes).
- **`fact_triple`:** Raw `(subject, predicate, object)` triples injected directly, bypassing triple extraction.

### A.5 Community Detection and Hierarchical Sagas

Graphiti organizes knowledge at two distinct levels above raw facts:
1. **Topological Communities (`CommunityNode`):**
   - Found using a weighted **Label Propagation Algorithm (LPA)** (`graphiti_core/driver/operations/graph_utils.py#L27-L66`).
   - Graph projection maps `node_uuid -> list[Neighbor(node_uuid, edge_count)]`. LPA iteratively propagates community labels until convergence.
   - For each community cluster, an LLM generates a name and regional summary (`prompts/summarize_nodes.py`), which is embedded and stored on `CommunityNode`. Edges are linked via `CommunityEdge` (`(c:Community)-[:HAS_MEMBER]->(n:Entity)`).
2. **Temporal Sagas (`SagaNode`):**
   - Sagas represent chronological narrative arcs or topic threads across time (`graphiti_core/nodes.py#L907-L945`).
   - Episodes within a saga are linked sequentially via `NextEpisodeEdge` (`(e1:Episodic)-[:NEXT_EPISODE]->(e2:Episodic)`), and connected to the parent saga via `HasEpisodeEdge` (`(s:Saga)-[:HAS_EPISODE]->(e:Episodic)`).
   - `SagaNode` stores `first_episode_uuid`, `last_episode_uuid`, and `last_summarized_episode_valid_at` for incremental progress tracking.

### A.6 Hybrid Search and Reranker Implementations

Graphiti defines search across four scopes (`search_config.py#L32-L120`): Edges, Nodes, Episodes, and Communities.

#### Search Methods:
- `cosine_similarity`: Dense vector k-NN on embeddings (`fact_embedding`, `name_embedding`).
- `bm25`: Sparse lexical full-text search over text fields.
- `bfs`: Breadth-First Search traversal expanding $k$ hops from matched seed nodes (`bfs_max_depth`, default 2).

#### Rerankers:
Graphiti implements five distinct reranking strategies (`graphiti_core/search/search_utils.py`):
1. **Reciprocal Rank Fusion (RRF) (`search_utils.py#L1786-L1801`):**
   $$RRF\_Score(d) = \sum_{m \in M} \frac{1}{k + rank_m(d)}$$
   Implemented with default $k = 1$ (`rank_const=1`). Fuses dense, lexical, and graph rank lists cleanly without score calibration.
2. **Maximal Marginal Relevance (MMR) (`search_utils.py#L1912-L1950`):**
   $$MMR(q, d_i) = \lambda \cdot \cos(q, d_i) - (1 - \lambda) \max_{d_j \in S} \cos(d_i, d_j)$$
   Uses normalized L2 embeddings, computing pairwise dot products to penalize informational redundancy (`DEFAULT_MMR_LAMBDA = 0.5`).
3. **Node Distance Reranker (`search_utils.py#L1804-L1860`):**
   Computes the shortest graph path distance from a specified `center_node_uuid` to all candidate nodes. Candidates with 1-hop relationships score higher; unreachable nodes are penalized with distance $\infty$.
4. **Episode Mentions Reranker (`search_utils.py#L1890-L1910`):**
   Ranks candidates based on the raw count of episodes referencing the entity/edge. Frequently recurring facts rank higher.
5. **Cross-Encoder Reranker (`cross_encoder/bge_reranker_client.py#L34-L55`):**
   Uses `sentence_transformers.CrossEncoder('BAAI/bge-reranker-v2-m3')` to perform joint token-level query-passage attention scoring over `(query, passage)` pairs.

### A.7 Temporal Resolution of Relative Expressions

In `graphiti_core/prompts/extract_edges.py#L260-L295`, relative dates (*"yesterday"*, *"last week"*, *"three months ago"*) are anchored using the episode's `reference_time`.
- In `temporal_edge_utils.py#L39-L72`, `normalize_future_temporal_bounds` uses regexes to distinguish commitments from deadlines:
  - If a fact matches `_FUTURE_ASSERTION_RE` (`will`, `plans to`, `scheduled to`), `valid_at` is set to `reference_time`, NOT the future occurrence date.
  - If a fact contains a deadline `_DEADLINE_RE` (`by Friday`, `due by March 2026`), it is explicitly **prohibited** from populating `invalid_at`. Only ongoing states that end (`_ONGOING_STATE_END_RE`: `until`, `expires`, `ceases`) set `invalid_at`.

### A.8 Node and Edge Schemas (Persisted Attributes)

Graphiti persists the following schemas across its graph driver layer:

| Model | Classification | Persisted Fields |
|---|---|---|
| `EpisodicNode` | Node | `uuid`, `name`, `group_id`, `labels`, `created_at`, `source` (`message`/`json`/`text`), `source_description`, `content`, `valid_at`, `entity_edges` (list[uuid]), `episode_metadata` |
| `EntityNode` | Node | `uuid`, `name`, `group_id`, `labels`, `created_at`, `name_embedding` (vector), `summary` (str), `attributes` (JSON map) |
| `CommunityNode` | Node | `uuid`, `name`, `group_id`, `labels`, `created_at`, `name_embedding` (vector), `summary` (str) |
| `SagaNode` | Node | `uuid`, `name`, `group_id`, `labels`, `created_at`, `summary`, `first_episode_uuid`, `last_episode_uuid`, `last_summarized_at`, `last_summarized_episode_valid_at` |
| `EntityEdge` | Relation | `uuid`, `group_id`, `source_node_uuid`, `target_node_uuid`, `created_at`, `name` (predicate), `fact` (prose), `fact_embedding` (vector), `episodes` (list[uuid]), `valid_at`, `invalid_at`, `expired_at`, `reference_time`, `attributes` |
| `EpisodicEdge` | Relation | `(Episodic)-[:MENTIONS]->(Entity)`: `uuid`, `group_id`, `source_node_uuid`, `target_node_uuid`, `created_at` |
| `CommunityEdge`| Relation | `(Community)-[:HAS_MEMBER]->(Entity)`: `uuid`, `group_id`, `source_node_uuid`, `target_node_uuid`, `created_at` |
| `HasEpisodeEdge`| Relation | `(Saga)-[:HAS_EPISODE]->(Episodic)`: `uuid`, `group_id`, `source_node_uuid`, `target_node_uuid`, `created_at` |
| `NextEpisodeEdge`| Relation | `(Episodic)-[:NEXT_EPISODE]->(Episodic)`: `uuid`, `group_id`, `source_node_uuid`, `target_node_uuid`, `created_at` |

### A.9 LLM Ingestion Cost Analysis

Graphiti’s ingestion pipeline (`add_episode` in `graphiti.py#L1334-L1580`) is heavily reliant on multiple serial and parallel LLM invocations. Tracing a single turn reveals:

1. **Node Extraction:** 1 call (`extract_nodes`).
2. **Node Resolution:** 0 calls if all candidates resolve via exact match or MinHash/LSH ($J \ge 0.9$); otherwise 1 batch call (`dedupe_nodes.nodes`).
3. **Edge Extraction:** 1 call (`extract_edges.edge`).
4. **Edge Deduplication & Invalidation:** 1 call per edge candidate set (`dedupe_edges.resolve_edge`). If an episode produces 5 edges, this triggers up to 5 LLM calls unless facts match verbatim.
5. **Timestamp Extraction:** 1 batch call (`extract_timestamps_batch`) or individual calls per edge.
6. **Node Summary / Attribute Hydration:** 1 call per affected entity (`extract_attributes_from_nodes`).
7. **Community Update:** Optional, but if enabled, 1 call per affected community.

**Total Cost per Episode:** 4 to 12+ LLM calls per conversational turn. Based on 4–12 LLM calls per turn and typical commercial API rates, estimated operational token cost is $0.02 to $0.15 per turn on commercial APIs *(unverified)* and latency of 3,000–8,000 ms *(unverified)* *(corrected per V07 F-06)*.

### A.10 Recommendations for Engram (Section A)

- **ADOPT: Bi-temporal Edge Modeling (`valid_from`/`valid_to` vs. `learned_at`).**  
  *Rationale:* Distinguishing world event time from database ingestion time is essential for accurate episodic and factual reasoning. Without it, an agent cannot answer *"what was true in March"* versus *"what is true today"*. Engram will map `valid_at` $\to$ `valid_from`, `invalid_at` $\to$ `valid_to`, and `created_at` $\to$ `learned_at`.
- **ADOPT: Invalidation via Soft Closes Rather Than Deletion.**  
  *Rationale:* When a contradiction occurs, setting `valid_to = now` and linking via `contradiction_of` preserves historical provenance and enables time-travel queries without destructive deletes.
- **ADAPT: Entity Resolution Pipeline.**  
  *Rationale:* Graphiti's MinHash/LSH string matching requires substantial Python CPU overhead. In SurrealDB, we have native full-text indexing with BM25 (`FULLTEXT ANALYZER ... BM25` *(corrected)* *(superseded by 00-decisions.md §1 row 16)*) alongside vector embeddings. Engram should resolve entities via: (1) exact alias match, (2) SurrealDB BM25 score $> 0.8$, (3) vector cosine similarity $> 0.85$, and only escalate ambiguous ties to an LLM.
- **ADAPT: Ingestion Pipeline Batching.**  
  *Rationale:* Graphiti’s 4–12 LLM calls per turn are unaffordable for a local agent. Engram must combine entity extraction, edge extraction, and relative date resolution into a **single structured LLM call** using JSON schema output.
- **REJECT: Graphiti’s Multi-Engine Driver Layer.**  
  *Rationale:* Graphiti maintains separate Cypher adapters for Neo4j, FalkorDB, Kùzu, and Neptune, forcing compromised abstractions (e.g. simulating edges as nodes in Kùzu). Engram targets SurrealDB exclusively, enabling unified ACID transactions over documents, graphs, and vectors.

---

## Section B: SurrealDB Native Agent Memory Architecture

SurrealDB has published its own agent memory specification and deep dive (`https://surrealdb.com/agent-memory` and `/agent-memory/deep-dive.md`), introducing a context and memory layer built natively within SurrealDB 3.x.

```
+-------------------------------------------------------------------------+
|                              THE AGENT                                  |
|                         (LLM, Tools, Loop)                              |
+-------------------------------------------------------------------------+
                                    |
+-------------------------------------------------------------------------+
|                          CONTEXT LAYER                                  |
|   - Four-Tier Recall Router (Seed Reads -> Cache -> Hybrid -> HyDE)     |
|   - Reconciler (Enforces deterministic code rules; uncertainty logging) |
+-------------------------------------------------------------------------+
                                    |
+-------------------------------------------------------------------------+
|                     UNIFIED SURREALDB 3.X ENGINE                        |
|                                                                         |
|  +--------------------+  +--------------------+  +-------------------+  |
|  |     DOCUMENTS      |  |    KNOWLEDGE KG    |  |     VECTORS       |  |
|  |  Episodes, Chunks  |  |  Entities, Facts*  |  |  HNSW Index*      |  |
|  +--------------------+  +--------------------+  +-------------------+  |
|  (*Facts: superseded by 00-decisions.md §1 row 20; HNSW Index COSINE: corrected per V07 F-02)
|  +--------------------+  +--------------------+  +-------------------+  |
|  |     PROVENANCE     |  |    TIME SERIES     |  |    FULL-TEXT      |  |
|  |   Decision, Audit  |  | Three Clocks Table |  |  BM25 Analyzer    |  |
|  +--------------------+  +--------------------+  +-------------------+  |
|                                                                         |
|                Single ACID Transaction Boundary per Write               |
+-------------------------------------------------------------------------+
```

### B.1 Single-Engine Multi-Model Substrate

SurrealDB Agent Memory rejects the poly-store architecture (e.g., FalkorDB + LanceDB + PostgreSQL + Redis) in favor of a single multi-model engine.
- **Single Transaction Boundary:** Each fact, its graph relations, vector embeddings, and historical supersession records are updated within **one ACID transaction**.
- **No Middleware Drift:** Because graph pointers and vector indexes reside in the same record table, an index is never orphaned if a write fails mid-flight.

### B.2 Typed Memory Primitives and Categorization

SurrealDB categorizes memory into three fundamental primitives:
1. **Attribute:** A key-value property anchored to a single entity (e.g., `user.preferred_editor = 'neovim'`).
2. **Relation:** A directed graph link between two entities (e.g., `user -[:OWNS]-> billing_service`).
3. **Action:** An episodic event describing what an entity did, where, and when (e.g., `user rotated API_KEY on 2026-07-14`).

These primitives are organized into **six experiential memory categories** (`deep-dive.md#L138-L173`):
- `Episodic`: Raw conversational turns and documents, stored chronologically.
- `Identity`: Stable, durable user traits (name, role, employer, core preferences).
- `Knowledge`: Domain knowledge, external references, system facts.
- `Context`: Working set of active intents and topics for the current session.
- `Instructions`: Behavioral system prompts (e.g., *"Always write code in Rust 2024 edition"*).
- `Uncertainty`: Explicit tracking of disputed facts, low-confidence extractions, or unverified claims.

### B.3 Tri-Temporal System and Reconciliation Rules

SurrealDB Agent Memory formalizes **three independent clocks** (`temporal.md#L106-L145`):
1. **System Time (`SurrealDB VERSION`):** Database transaction commit timestamp, providing immutable snapshot reads.
2. **Known Time (`as_of`):** The timestamp when the memory system first learned of a claim. Answers: *"What did the agent believe as of last Tuesday?"*
3. **Valid Time (`valid_from`, `valid_until`):** The real-world window when the fact was true in reality.

#### Supersession vs. Overwrite:
When a new fact arrives that contradicts an old fact (e.g., *"Tobie moved from Acme to SurrealDB"*):
- The existing record is **not deleted or overwritten**.
- Its `valid_until` timestamp is set to the arrival date of the new fact.
- The new fact is inserted with `valid_from = now` and `valid_until = NULL`.
- Both rows remain queryable.
- `forget(id)`: Retires a fact by closing its validity window.
- `purge(id)`: Permanently deletes the record and its historical supersession chain (GDPR right-to-be-forgotten).

#### Reconciliation Rules (`deep-dive.md#L174-L194`):
1. **Decided in Code:** Reconciliation rules are programmatic, not delegated to an LLM, ensuring strict determinism.
2. **Contradictions Stay Visible:** Conflicting statements across different sources are marked as `contested` rather than resolved by a prompt.
3. **Confidence Floors:** An incoming fact with lower confidence than an existing fact cannot overwrite it; it is relegated to an `uncertainty` record.
4. **Matched by Name:** Entities match strictly by name/alias, preventing accidental merges.

### B.4 Provenance, Traces, and Explicit Uncertainty

Every recalled or persisted item in SurrealDB Agent Memory carries explicit provenance:
- **Fact Provenance:** Each fact references `source` (`kind`, `trust`, `ref`, `span`, or `derived_from`) and a `confidence` float ($0.0 \dots 1.0$).
- **Tenant Traces:**
  - `Decision Trace`: Recorded on every write, documenting extraction reasoning, reconciliation choices, and updated edges.
  - `Retrieval Trace`: Recorded on every ranked read, logging the exact scores across all fused signals.
  - `Response Trace`: Recorded on generated answers, linking back to the exact cited fact IDs.
- **Explicit Uncertainty:** Rather than letting hallucinations bridge knowledge gaps, facts with confidence below the configured threshold are explicitly stored in an `uncertainty` table with open question markers.

### B.5 Four-Tier Recall Router and 7 Fused Signals

SurrealDB uses a tiered recall router (`deep-dive.md#L366-L427`) ordered by computational cost:
- **Tier 1 — Structured Seed Reads:** Key-based lookups for known entity attributes. Very fast, never terminal on its own (used as seeds for graph traversal).
- **Tier 2 — Response Cache:** Entity-aware cache. If a repeated question is asked and none of the cited entity facts have been superseded, the cached answer is returned immediately.
- **Tier 3 — Hybrid Fused Retrieval:** A single ranker evaluating **seven distinct signals**:
  1. *Vector:* Cosine distance across embeddings.
  2. *Lexical:* BM25 keyword matching.
  3. *Graph:* 1–2 hop edge traversals from seed entities.
  4. *Section Links:* Hierarchical parent-child links between document sections.
  5. *PageRank:* Graph walk biased towards query seed entities.
  6. *Geo:* Geospatial bounding box/distance scoring.
  7. *Trace Features:* Historical utility feedback (facts that previously produced successful user turns).
- **Tier 4 — Escalated Fallback:** Triggered when Tier 3 returns low-confidence or sparse results. Runs HyDE (Hypothetical Document Embeddings) and doubles the search candidate pool.

### B.6 Tenancy and Isolation

- **Context Level:** Isolated namespace and database (`ns: <tenant>, db: <workspace>`). No cross-context querying is permitted.
- **Scope Level:** Sub-partitions within a context, gated by per-verb capability grants (read, write, forget, purge). Keys can narrow permissions, never broaden them.

### B.7 Recommendations for Engram (Section B)

- **ADOPT: The Three-Clock Model (`VERSION`, `as_of`, `valid_from`/`valid_to`).**  
  *Rationale:* Perfectly aligns with SurrealDB's native transaction time and Engram’s bi-temporal graph edges.
- **ADOPT: The Three Memory Primitives (Attribute, Relation, Action).**  
  *Rationale:* Clarifies Engram’s schema. Attributes live directly on `entity` records; Relations live on `asserts` edges; Actions live as `episode` records.
- **ADOPT: Explicit Uncertainty and Contradiction Visibility.**  
  *Rationale:* When two sources conflict, Engram must record both edges with `contested = true` and display both dates during retrieval rather than letting an LLM guess.
- **ADAPT: Recall Signals (Trim from 7 to 4 for v1).**  
  *Rationale:* Implementing PageRank, Geo, and Trace feedback in v1 adds unnecessary complexity. Engram will focus on the core 4 signals: **Dense Vector + BM25 Lexical + Graph Traversal + Temporal Recency**, fused via RRF.
- **REJECT: Cloud-Only Multi-Tenant Tenancy Model.**  
  *Rationale:* Engram is designed for a single-user Hermes agent running locally on NVMe. Workspace isolation via `database` scoping is sufficient; complex capability-based grant scoping is out of scope for v1.

---

## Section C: Agent Memory Evaluation and Benchmark Harness

Evaluating agent long-term memory requires assessing retrieval precision, multi-hop reasoning, truth maintenance, and cost.

### C.1 Benchmark Anatomy: LongMemEval, LoCoMo, BEAM, MemoryAgentBench

| Benchmark | Paper Citation | Focus Areas | Dataset Scale | Evaluation Methodology | License |
|---|---|---|---|---|---|
| **LongMemEval** | arXiv:2410.10813 (ICLR 2025) | 5 core abilities evaluated across 7 question types (`single-session-user/assistant/pref`, `multi-session`, `knowledge-update`, `temporal-reasoning`, `abstention`) *(corrected per V07 F-05)* | 500 questions across realistic multi-session chat histories (up to 100k+ tokens) | LLM-as-a-judge against human ground truth; tracks performance degradation over distance | Apache 2.0 / MIT |
| **LoCoMo** | arXiv:2402.17753 (ACL 2024) | Long-horizon conversational recall: single-hop, multi-hop, temporal reasoning, open-domain | 10–35 conversations (each spanning up to 35 sessions, ~300 turns), ~1,540 QA pairs in eval subset *(corrected per V07 F-04)* | LLM-as-a-judge grading answer accuracy against session gold labels | CC-BY-4.0 |
| **BEAM** | arXiv:2510.27246 (2025/2026) | 10 cognitive abilities: event ordering, contradiction, abstention, multi-session | 100 narrative dialogues across 128k, 500k, 1M, and 10M token splits; 2,000 questions | Rubric-based LLM judge. Evaluates *Strict* (all rubric items 1.0) vs. *Mean* vs. *Kendall tau* for ordering | Apache 2.0 |
| **MemoryAgentBench** | arXiv:2507.05257 (Hu, Wang, McAuley et al., 2025) *(corrected per V07 F-01)* | 1. Accurate Retrieval (AR)<br>2. Test-Time Learning (TTL)<br>3. Long-Range Understanding (LRU)<br>4. Selective Forgetting (SF) *(corrected)* | Multi-turn streaming interactions; "inject once, query multiple times" | Automated scoring of streaming updates, state consistency, and recall accuracy | MIT |

### C.2 Published Industry Benchmark Results

Evaluating long-term memory across vendors is complicated by differing judge models, retrieval context budgets, and grading rubrics. The table below compiles verified scores from published papers, vendor technical reports, and repository artifacts:

| Framework | Benchmark Split | Headline / Mean Score | Strict Score | Answering Model | Judge Model | Notes & Retrieval Context | Source |
|---|---|---|---|---|---|---|---|
| **SurrealDB Agent Memory** | BEAM 1M | **77.2%** (Kendall tau) | **57.1%** | Gemini 3.8 Flash | Gemini 3.5 Flash Lite | Top 50 recalled facts; strict requires 100% on all rubric criteria | `surrealdb.com/agent-memory/benchmarks` |
| **Exabase** | BEAM 1M | **75.0%** | **48.0%** | Gemini 3 Flash Prev | Gemini 2.5 Flash Lite | ~18,900 context tokens | Exabase Technical Report |
| **Hindsight** | BEAM 1M | **73.9%** | **48.4%** | Gemini 3.1 Pro Prev | Gemini 2.5 Flash Lite | ~23,900 context tokens; 4-way hybrid retrieval | `github.com/vectorize-io/agent-memory-benchmark` |
| **Mem0** | BEAM 1M | **64.1%** (top-200) | **40.1%** | GPT-5 | GPT-5 | Evaluated with top-200 memories injected | `github.com/mem0ai/memory-benchmarks` |
| **Honcho** | BEAM 1M | **63.1%** | **41.4%** | Claude Haiku 4.5 | Claude Sonnet 4.5 | Agentic tool-calling retrieval (up to 20 calls) | `github.com/plastic-labs/honcho-benchmarks` |
| **HydraDB** | BEAM 1M | **82.0%** (unweighted) *(unverified)* | UNVERIFIED | Unstated | GPT-5.4 | No per-question files published; category average | `benchmarks.hydradb.com/beam-1m` |
| **Zep (Graphiti)** | LongMemEval | **71.2%** (Overall) *(corrected per V07 F-03)* | N/A | GPT-4o | GPT-4o-judge | +18.3% gain over raw context (Table 2); 90% latency reduction | arXiv:2501.13956 |
| **Mem0** | LoCoMo | **66.8%** | N/A | GPT-4o-mini | GPT-4o | Subject to dispute by Zep regarding harness fairness | Mem0 LoCoMo Report |
| **Letta (MemGPT)** | LoCoMo | **58.3%** | N/A | GPT-4o | GPT-4o | Baseline archival memory search | Letta Benchmarks |
| **Cognee** | LongMemEval-S | **64.2%** | N/A | GPT-4o-mini | GPT-4o | Graph + vector extraction pipeline | Cognee Eval Repo |

### C.3 The Mem0 vs. Zep LoCoMo Controversy and Benchmark Rigging

In mid-2024, Mem0 published benchmarks claiming state-of-the-art results on LoCoMo, reporting significant leads over Zep and OpenAI. Zep responded with a detailed critique entitled *"Lies, Damn Lies, & Statistics: Is Mem0 Really SOTA in Agent Memory?"*.

SurrealDB's benchmark audit (`benchmarks.md#L248-L299`) and independent reviews cataloged several common benchmark manipulations in the agent memory space:
1. **Lenient Judging:** Counting partial matches (0.5 marks) as full passes, which artificially inflates headline pass rates by 15–25% over strict scores.
2. **Dropping Adversarial / Abstention Categories:** Omitting questions where the correct response is "I don't know" or questions with conflicting premises.
3. **Prompt Leakage:** Providing the question's category (e.g., `temporal`, `multi-session`) directly to the answer prompt or query rewriter, allowing the model to switch into specialized reasoning modes that are impossible in production.
4. **Disproportionate Retrieval Budgets:** Comparing one vendor using top-5 retrieval against another using top-200 memories (over 20,000 context tokens).
5. **Misconfiguring Competitor Software:** Testing competing platforms with default, single-hop configurations while running their own system with custom multi-pass search.

### C.4 Proposed Engram v1 Evaluation Harness

To prevent regression and provide objective metrics without prohibitive evaluation costs, Engram should implement an automated benchmark harness.

```
+-------------------------------------------------------------------------+
|                       ENGRAM EVALUATION HARNESS                         |
+-------------------------------------------------------------------------+
                                    |
      +-----------------------------+-----------------------------+
      |                                                           |
+------------------------------+             +-------------------------------+
|   FAST DETERMINISTIC CI      |             |     OFFLINE BENCHMARK RUN     |
|   (Runs on git push / PR)    |             |     (Weekly / Nightly)        |
+------------------------------+             +-------------------------------+
| - 50 synthetic test cases    |             | - LongMemEval 100-Q Core      |
| - Truth maintenance assertions|            | - Strict Accuracy metric      |
| - Sub-second execution       |             | - Real SurrealDB + Ollama/API |
| - Zero LLM API calls         |             | - Measures p95 latency & cost |
+------------------------------+             +-------------------------------+
```

#### 1. Benchmark Dataset Subset:
- **Core Suite:** 100 questions sampled evenly across LongMemEval's five categories:
  - 20 Information Extraction
  - 20 Multi-Session Reasoning
  - 20 Temporal Reasoning
  - 20 Knowledge Updates (Truth Maintenance)
  - 20 Abstention / Refusal
- **Engram Synthetic Suite:** 30 deterministic unit assertions verifying:
  - Supersession of functional predicates (e.g. changing employer closes prior edge).
  - Both contradictory facts remain queryable with dates when `contested = true`.
  - Future dates do not overwrite `valid_from`.

#### 2. Evaluation Metrics:
- **Strict Accuracy:** Percentage of questions where all factual assertions match ground truth.
- **Event Ordering Accuracy (Kendall $\tau$):** Measures rank correlation of reconstructed historical timelines.
- **Abstention Precision:** F1 score on questions with absent or false premises.
- **Prefetch Latency:** Target $p95 < 25\text{ ms}$ for serving cached recall context.
- **Ingestion Turn Latency:** Target $p95 < 2\text{ ms}$ for `sync_turn` handoff (background queue).

#### 3. CI Regression Gate:
- Runs on every PR using an embedded, temporary SurrealDB instance (`surreal start --memory`).
- Executes the 30-case synthetic suite deterministically with mocked LLM extractions.
- PRs that fail any contradiction resolution or temporal edge assertion are blocked from merging.

### C.5 Recommendations for Engram (Section C)

- **ADOPT: LongMemEval’s 5-Category Taxonomy.**  
  *Rationale:* Covers the exact failure modes of agent conversational memory (extraction, multi-session, time, updates, abstention).
- **ADOPT: Strict Metric Reporting (Strict + Kendall $\tau$).**  
  *Rationale:* Avoids the misleading inflation of "pass rates" documented in the Mem0/Zep disputes.
- **ADOPT: Fast Deterministic CI Test Suite.**  
  *Rationale:* LLM-as-a-judge evaluations are too slow and expensive for standard GitHub Actions PR checks. Deterministic replay of mocked graphs ensures high reliability at zero marginal cost.
- **REJECT: Full 10M BEAM Benchmark for v1 CI.**  
  *Rationale:* Ingesting 10 million tokens across 1,000 conversations costs over $50 per run and takes hours. Reserve large BEAM evaluations for post-v1 milestone validation.

---

## Section D: Adjacent Cognitive Memory Patterns

### D.1 MemGPT / Letta Memory Tiers

MemGPT ([arXiv:2310.08560](https://arxiv.org/abs/2310.08560)) and its successor Letta partition memory into hierarchical tiers inspired by operating system memory management:
- **Core Memory (Working RAM):** Fixed in-context text blocks (`human`, `persona`) injected into every LLM prompt turn. The agent edits these blocks via explicit tool calls (`core_memory_append`, `core_memory_replace`).
- **Archival Memory (Disk Storage):** Large, read-only out-of-context vector/document store accessed via explicit search tools (`archival_memory_search`).
- **Recall Memory (Session Cache):** Rolling conversation transcript buffer.

```
+---------------------------------------------------------------------+
|                           CONTEXT WINDOW                            |
|                                                                     |
|  +-------------------------+     +-------------------------------+  |
|  |       CORE MEMORY       |     |        RECALL MEMORY          |  |
|  | - Persona (Agent role)  |     | - Recent conversation turns   |  |
|  | - Human (User facts)    |     | - Working session context     |  |
|  +-------------------------+     +-------------------------------+  |
+---------------------------------------------------------------------+
                                 |
           Explicit Tool Calls   |   Autonomous Prefetch / Sync
         (core_memory_append)   |   (Engram Provider Lifecycle)
                                 v
+---------------------------------------------------------------------+
|                          ARCHIVAL MEMORY                            |
|                                                                     |
|  +---------------------------------------------------------------+  |
|  |                     ENGRAM ON SURREALDB                       |  |
|  |  - Immutable Episodes   - Bi-Temporal Asserts Edges           |  |
|  |  - Entity Graph         - Consolidated Observations           |  |
|  +---------------------------------------------------------------+  |
+---------------------------------------------------------------------+
```

#### Implications for Engram:
Hermes Agent already features native Core Memory via its curated `MEMORY.md` and `USER.md` files. Engram serves as the missing **Archival Memory Tier**, providing automated background persistence and retrieval so the agent does not have to remember to call retrieval tools manually.

### D.2 A-MEM: Zettelkasten-Style Memory Linking

A-MEM (*"Agentic Memory for LLM Agents"*, [arXiv:2502.12110](https://arxiv.org/abs/2502.12110), Feb 2025) models agent memory after the **Zettelkasten** slip-box note-taking methodology:
- **Atomic Notes:** Each memory is stored as an atomic note with tags, contextual keywords, and a concise summary.
- **Dynamic Cross-Linking:** When a new note is added, the system analyzes existing notes to establish bi-directional associative links (`links: [note_id_1, note_id_2]`), forming an emergent semantic web without requiring a rigid ontology.
- **Contextual Evolution:** As related memories accumulate, older notes update their link weights and contextual metadata.

#### Relevance to Engram:
A-MEM provides a useful alternative to rigid knowledge graph ontologies. By linking episodes and entities with dynamic associative edges, Engram can uncover indirect relationships across disparate conversations.

### D.3 Reflection and Periodic Consolidation

Introduced in Generative Agents (Park et al., [arXiv:2304.03442](https://arxiv.org/abs/2304.03442)), reflection is the process of synthesizing raw episodic turns into higher-level observations:
1. **Trigger:** Accumulation of episode importance scores exceeds a threshold $T$, or an agent session ends.
2. **Synthesis:** The agent prompts an LLM with recent episodes: *"What are the 3 most salient high-level insights from these events?"*
3. **Consolidation:** Generates generalized `observation` records that link back to the supporting episodes as evidence pointers.

#### Relevance to Engram:
Directly matches Engram’s `observation` table (`DISCOVERY_HANDOFF.md#L214-L222`). Episodes remain immutable; periodic reflection passes synthesize recurring behaviors into observations (`evidence: [episode:1, episode:2]`).

### D.4 Memory Decay and Forgetting Curves

Human memory retention follows the **Ebbinghaus Forgetting Curve**:
$$R = e^{-\frac{t}{S}}$$
where $R$ is memory retention, $t$ is elapsed time, and $S$ is memory stability.

In agent memory systems:
- Each recall or reinforcement increases stability $S$, flattening the decay curve.
- Search scores incorporate a recency decay multiplier:
  $$Score_{final} = Score_{retrieval} \cdot \left(\alpha + (1 - \alpha) e^{-\lambda (t_{now} - t_{last})}\right)$$
- Protects working context from being saturated by outdated, one-off conversational noise.

### D.5 MMR Diversity in Retrieval

Standard top-$k$ vector retrieval frequently returns near-identical passages. **Maximal Marginal Relevance (MMR)** balances relevance to the query with diversity among retrieved items:
$$MMR = \arg\max_{d_i \in R \setminus S} \left[ \lambda \cdot Sim_1(d_i, q) - (1 - \lambda) \max_{d_j \in S} Sim_2(d_i, d_j) \right]$$
- $\lambda = 1.0$: Pure relevance (standard vector search).
- $\lambda = 0.5$: Equal balance between query relevance and topical diversity.
- Eliminates redundant facts from consuming valuable context budget.

### D.6 Query Rewriting and HyDE

Raw user messages make poor retrieval queries (*"Yeah, what did we decide about that thing yesterday?"*).
- **Query Rewriting:** An auxiliary model rewrites conversational context into a self-contained search query (*"User decision on database architecture on 2026-10-23"*). Hermes already implements this in `plugins/memory/query_rewrite.py`.
- **HyDE (Hypothetical Document Embeddings):** Generates a hypothetical ideal response using an LLM, embeds the hypothetical text, and searches against stored memory. Excels at concept-level recall where terminology varies.

### D.7 Token-Budgeted Context Packing

Retrieved context must fit strictly within a designated token budget (e.g. 1,024 tokens) to prevent context exhaustion in the primary conversation loop:
1. **Knapsack / Greedy Truncation:** Sort candidates by fused RRF score.
2. **Atomic Formatting:** Format each item into a compact markdown line:
   `- [2026-03] Alice owns billing-service (conf 0.9)`
3. **Budget Guard:** Accumulate token counts; stop formatting the moment adding another fact would exceed `prefetch_token_budget`.

### D.8 Recommendations for Engram (Section D)

- **ADOPT: Token-Budgeted Greedy Context Packing.**  
  *Rationale:* Hermes enforces hard prefetch timeout and size constraints. Engram must strictly respect `prefetch_token_budget` (default ~1,200 tokens) using compact markdown lines.
- **ADOPT: Reflection / Consolidation on `on_session_end`.**  
  *Rationale:* Hooking into Hermes's `on_session_end` allows Engram to promote recurring episodes into consolidated `observation` records in the background without adding latency to the user's turn.
- **ADOPT: MMR Reranking for Edge Retrieval.**  
  *Rationale:* Prevents 5 variations of the same project status fact from filling the recall context.
- **ADAPT: Ebbinghaus Decay Scoring.**  
  *Rationale:* Apply temporal decay **only** to episodic records and unconsolidated notes. Never decay verified identity traits, standing preferences, or immutable technical specifications.
- **ADAPT: Query Rewriting Integration.**  
  *Rationale:* Reuse Hermes’s native `plugins/memory/query_rewrite.py` rather than maintaining a separate rewriter inside Engram.
- **REJECT: Autonomous In-Turn Core Memory Mutations (MemGPT Style).**  
  *Rationale:* Hermes manages `MEMORY.md` and `USER.md` through its own prompt tools; Engram should observe these via `on_memory_write`, not issue competing autonomous writes.

---

## References and Citations

1. **Zep Knowledge Graph Paper:**  
   Rasmussen, P., Paliychuk, P., & Chalef, D. (2025). *Zep: A Temporal Knowledge Graph Architecture for Agent Memory.* arXiv preprint [arXiv:2501.13956](https://arxiv.org/abs/2501.13956).
2. **Graphiti Source Code Repository:**  
   Zep Software, Inc. (2024–2026). *Graphiti: A temporally-aware knowledge graph engine for AI agents.* Cloned and verified locally at `/tmp/graphiti`; repository: [`github.com/getzep/graphiti`](https://github.com/getzep/graphiti).
   - Invalidation logic: `graphiti_core/utils/maintenance/edge_operations.py#L720-L785`
   - Invalidation prompt: `graphiti_core/prompts/dedupe_edges.py#L44-L115`
   - Entity deduplication: `graphiti_core/utils/maintenance/node_operations.py#L456-L750`
   - Fuzzy MinHash/LSH: `graphiti_core/utils/maintenance/dedup_helpers.py#L31-L381`
   - Temporal normalization: `graphiti_core/utils/maintenance/temporal_edge_utils.py#L39-L72`
   - Rerankers (RRF, MMR, Node Distance): `graphiti_core/search/search_utils.py#L1866-L1910` *(corrected per V07 F-08)*
3. **SurrealDB Agent Memory Documentation & Deep Dive:**  
   SurrealDB Ltd. (2026). *Agent Memory: Typed, Temporal and Auditable Memory on SurrealDB.*  
   - Overview: [`https://surrealdb.com/agent-memory`](https://surrealdb.com/agent-memory)
   - Technical Deep Dive: [`https://surrealdb.com/agent-memory/deep-dive`](https://surrealdb.com/agent-memory/deep-dive)
   - Temporal Model: [`https://surrealdb.com/agent-memory/temporal`](https://surrealdb.com/agent-memory/temporal)
   - Recall & 7 Signals: [`https://surrealdb.com/agent-memory/recall`](https://surrealdb.com/agent-memory/recall)
   - Benchmarks & Analysis: [`https://surrealdb.com/agent-memory/benchmarks`](https://surrealdb.com/agent-memory/benchmarks)
4. **LongMemEval Benchmark:**  
   Wu, D., et al. (2024). *LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory.* ICLR 2025. arXiv preprint [arXiv:2410.10813](https://arxiv.org/abs/2410.10813).
5. **LoCoMo Benchmark:**  
   Maharana, A., et al. (2024). *Evaluating Very Long-Term Conversational Memory of LLM Agents.* ACL 2024. arXiv preprint [arXiv:2402.17753](https://arxiv.org/abs/2402.17753).
6. **BEAM Benchmark:**  
   Tavakoli, M., et al. (2025). *Beyond a Million Tokens: Benchmarking and Enhancing Long-Term Memory in LLMs.* arXiv preprint [arXiv:2510.27246](https://arxiv.org/abs/2510.27246).
7. **MemoryAgentBench:**  
   Hu, Y., Wang, Y., & McAuley, J. (2025). *Evaluating Memory in LLM Agents via Incremental Multi-Turn Interactions.* arXiv preprint [arXiv:2507.05257](https://arxiv.org/abs/2507.05257) *(corrected per V07 F-01)*.
8. **A-MEM (Zettelkasten Memory):**  
   Xu, W., et al. (2025). *A-MEM: Agentic Memory for LLM Agents.* arXiv preprint [arXiv:2502.12110](https://arxiv.org/abs/2502.12110).
9. **MemGPT Architecture:**  
   Packer, C., et al. (2023). *MemGPT: Towards LLMs as Operating Systems.* arXiv preprint [arXiv:2310.08560](https://arxiv.org/abs/2310.08560).
10. **Generative Agents (Reflection Pattern):**  
    Park, J. S., et al. (2023). *Generative Agents: Interactive Simulacra of Human Behavior.* arXiv preprint [arXiv:2304.03442](https://arxiv.org/abs/2304.03442).
11. **Engram Discovery & Architecture:**  
    Ichsan Rahardianto. (2026). *Engram — Discovery Handoff & PRD Input.* Local file: [`DISCOVERY_HANDOFF.md`](../../DISCOVERY_HANDOFF.md).
12. **Hermes Agent Framework:**  
    Nous Research. (2026). *Hermes Agent Core & MemoryProvider Contract.* Local file: [`~/.hermes/hermes-agent/agent/memory_provider.py`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_provider.py).
