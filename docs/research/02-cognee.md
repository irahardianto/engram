# Deep-Dive Research: Cognee Architecture & Patterns for Engram

> **Verification status:** PASS-WITH-FIXES — corrected on 2026-10-24 per [V02 report](verification/V02-cognee.md). Corrections are marked with *(corrected)*.

**Target Project:** Engram (Unified Multi-Model Long-Term Memory System for AI Agents, Rust + SurrealDB)  
**Reference Subject:** Cognee (`topoteretes/cognee`, tag `v1.6.5`, commit `37f788b`)  
**Source Path:** `topoteretes/cognee`  
**Hermes Plugin Source:** `~/.hermes/hermes-agent/plugin-catalog/cognee.yaml` and `topoteretes/cognee-integrations/integrations/hermes-agent`  
**Date of Research:** October 2026  
**Author:** Sovereign Research Agent (R2)

---

## Executive Summary

Cognee is a widely adopted Python-based framework that structures unstructured data and agent conversation histories into a knowledge graph with vector and relational retrieval lanes. It exposes a dual-tier API: a document-processing pipeline (**V1:** `add` → `cognify` → `search`) and an agent-memory interface (**V2:** `remember` → `recall` → `improve` → `forget`). In the Hermes agent ecosystem, Cognee is featured in the official plugin catalog as a knowledge-graph memory provider (`cognee.yaml`), sharing session state and recall context across agent runs.

Despite its rich feature set—including RDF/OWL ontology grounding, post-hoc contradiction review, and graph-guided completions—Cognee represents the quintessential **poly-store memory coordinator**. Rather than storing records natively in a unified multi-model database, Cognee coordinates three independent storage engines: a relational database (PostgreSQL/SQLite via SQLAlchemy), a graph database (Neo4j, Kùzu/Ladybug, or Neptune), and a vector database (LanceDB, PGVector, or Qdrant), with Redis optionally handling session caches.

This architecture leads to critical limitations that directly validate Engram's core thesis:
1. **No cross-store ACID transactions:** Writes to relational rollback ledgers, graph nodes/edges, and vector index tables occur sequentially without two-phase commit. A crash or network fault between graph insertion and vector indexing leaves orphaned, unindexed graph nodes or phantom vector points that can never be purged by graph deletion (`cognee/tasks/storage/add_data_points.py#L325-L336`).
2. **Single-writer database lock bottlenecks:** Local embedded engines (SQLite, Kùzu/Ladybug, LanceDB) lock under concurrent writes, forcing Cognee's Hermes plugin to spin up a standalone background HTTP server daemon on port 8011 (`uvicorn`) and an out-of-process closer worker just to serialize store access.
3. **In-memory graph processing:** Graph retrieval ("brute-force triplet search") does not execute native database joins; instead, it performs vector search to find candidate nodes, projects the surrounding subgraph into an in-memory `CogneeGraph` data structure (subclassing `CogneeAbstractGraph`, not NetworkX) in Python, and calculates distances via `heapq.nsmallest` in user-space *(corrected)* (`cognee/modules/retrieval/utils/brute_force_triplet_search.py#L162-L228`).
4. **Offline fact contradiction handling:** Contradictions are not resolved or flagged inline during ingestion; competing facts are blindly inserted into the graph, and conflict resolution is deferred to an expensive, optional LLM batch pass (`improve(review_conflicts=True)`).
5. **High ingestion cost:** The default ingestion pipeline executes at least **two LLM calls and four embedding calls per text chunk**, producing significant latency (~1.5–3.5s/chunk *(unverified)*) and cost overhead.

By implementing a native, single-engine multi-model architecture in **Rust on SurrealDB**, Engram adopts Cognee's best semantic patterns (structured extraction schemas, bi-temporal fact tracking, and lifecycle hooks) while eliminating its architectural vulnerabilities.

---

## 1. Conceptual Model & Public API

Cognee organizes memory into a two-layer mental model: an underlying document and entity knowledge graph partitioned into **Datasets** and **NodeSets**, and an agent-centric conversational memory layer consisting of short-term session caches and long-term synthesized graphs (`cognee/__init__.py#L40-L100`).

```
                    ┌────────────────────────────────────────────────────────┐
                    │                   PUBLIC API SURFACE                   │
                    └────────────────────────────────────────────────────────┘
                               /                                    \
                              /                                      \
        ┌───────────────────────────────┐              ┌───────────────────────────────┐
        │        V1 Pipeline API        │              │       V2 Agent Memory API     │
        │  add() / cognify() / search() │              │ remember() / recall() /       │
        │  delete() / prune()           │              │ improve() / forget()          │
        └───────────────────────────────┘              └───────────────────────────────┘
                        │                                              │
                        ▼                                              ▼
        ┌──────────────────────────────────────────────────────────────────────────────┐
        │                         LOGICAL PARTITIONS & SCOPES                          │
        │  - Datasets: Tenancy & ACL ownership boundary (SQLAlchemy Dataset model)    │
        │  - NodeSets: Subgraph topic/layer tag (NodeSet DataPoint + belongs_to_set)   │
        │  - Sessions: Short-term cache (SessionRecord in SQLite/Postgres/Redis)       │
        └──────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 V1 Document & Graph Pipeline API

The V1 API (`cognee/api/v1/`) treats Cognee as an ingestion and querying engine:
- `cognee.add(data, dataset_name, ...)` (`cognee/api/v1/add/add.py#L40-L60`): Ingests raw text, files, URLs, or binary streams into a dataset. It wraps data into `DataItem` objects, persists metadata into the relational database, computes content hashes, and stages files for transformation.
- `cognee.cognify(datasets, graph_model, ...)` (`cognee/api/v1/cognify/cognify.py#L133-L157`): The core graph construction pipeline. It classifies documents, chunks text, extracts entities and relations using an LLM or local model, generates chunk summaries, and stores results across graph and vector databases.
- `cognee.search(query_text, query_type, ...)` (`cognee/api/v1/search/search.py#L42-L73` *(corrected)*): Queries processed data using one of 21 search strategies (e.g. `GRAPH_COMPLETION`, `CHUNKS`, `SUMMARIES`, `CYPHER`).
- `cognee.delete(...)` / `cognee.prune(...)` (`cognee/api/v1/delete/`, `cognee/api/v1/prune/`): Lower-level cleanup functions. `prune` clears databases, while `delete` removes individual items or datasets.
- `cognee.run_custom_pipeline(tasks, ...)` (`cognee/modules/run_custom_pipeline.py`): Allows developers to execute custom DAGs of `Task` objects.
- `cognee.memify(...)` (`cognee/api/v1/memify/memify.py`): **Deprecated** in release SDK-1115 (`FutureWarning`); replaced by `cognee.improve()` and `run_custom_pipeline`.

### 1.2 V2 Agent Memory API

The V2 API (`cognee/api/v1/` and `cognee/__init__.py#L65-L85`) provides an agent-oriented mental model:
- `cognee.remember(data, dataset_name, session_id, ...)` (`cognee/api/v1/remember/remember.py#L1010-L1036`):
  - **Without `session_id` (Permanent Memory):** Ingests raw data by executing `add()` followed by `cognify()`. If `self_improvement=True` (the default), it automatically enqueues `improve()` to refine the graph.
  - **With `session_id` (Session Memory):** Writes data into the fast session cache (`SessionManager`, backed by relational DB or Redis) as a `QAEntry`, `TraceEntry`, or `MemoryEntry`. It avoids immediate expensive graph extraction. A background task debounces and bridges session turns into the permanent graph via `improve()` (`remember.py#L1039-L1053`).
- `cognee.recall(query_text, query_type, session_id, ...)` (`cognee/api/v1/recall/recall.py#L350-L384`): Retrieves context for an incoming prompt. When `session_id` is supplied without explicit datasets, it first searches the session cache; if no matches are found, it falls back to the knowledge graph. It tags each result item with `source="session"` or `source="graph"`.
- `cognee.improve(dataset, session_ids, ...)` (`cognee/api/v1/improve/improve.py#L157-L167` *(corrected)*): The self-improvement orchestrator. It processes session Q&A, agent execution traces, and user feedback, bridging them into the permanent knowledge graph through 9 sequential stages.
- `cognee.forget(data_id, dataset, everything, memory_only, ...)` (`cognee/api/v1/forget/forget.py#L22-L70`): Unified deletion interface. It supports deleting specific data items, entire datasets, or everything. When `memory_only=True`, it deletes the extracted graph nodes, edges, and vector embeddings while keeping the raw documents intact for re-cognification.
- `cognee.serve(...)` / `cognee.disconnect()` (`cognee/api/v1/serve/`): Connects the local Python client to a remote Cognee server or Cognee Cloud tenant over HTTP.

### 1.3 Datasets, NodeSets, Tenancy, and Permissions

#### Datasets
A **Dataset** is the primary administrative and authorization boundary (`cognee/modules/data/models/Dataset.py#L9-L39`):
- Relational schema in SQLAlchemy: `id (Uuid, PK)`, `name (Text)`, `owner_id (Uuid, index)`, `tenant_id (Uuid, index)`, `created_at`, `updated_at`.
- Relationships: One-to-many with `ACL` and `Data` records.
- Graph and vector isolation: Each dataset can map to a discrete database, namespace, or graph collection (`cognee/modules/users/models/DatasetDatabase.py`).

#### NodeSets
A **NodeSet** represents a semantic subgraph tag rather than a separate database (`cognee/modules/engine/models/node_set.py#L11-L32`):
- Modeled as a `DataPoint` node: `NodeSet(name=...)` with deterministic ID derived via `generate_node_id(f"NodeSet:{name}")`.
- Graph structure: Other nodes link to a NodeSet via `belongs_to_set` edges.
- Use cases: Filtering graph searches (`recall(node_name=["my_set"])`) without creating separate physical databases.
- System NodeSets (`cognee/modules/improve/constants.py#L20-L27`):
  - `session_learnings`: Holds distilled lessons from conversations.
  - `agent_trace_feedbacks`: Holds tool-call execution feedback.
  - `skills`: Holds procedural agent capabilities.
  - `user_preferences`: Holds user-specific `prefers` relationships.
  - `user_sessions_from_cache`: Holds raw transcribed session turns *(corrected)* (`USER_SESSIONS_NODE_SET = "user_sessions_from_cache"` in `cognee/modules/improve/constants.py#L13`).
- **Session Pinning:** Sessions can pin a `node_set` on the first write (`cognee/infrastructure/session/session_node_set.py#L1-L41`). Subsequent writes must agree with the pinned set, or raise `SessionNodeSetConflictError` (HTTP 409).

#### Users, Tenancy, and Access Control
- Authentication is built on `fastapi_users` (`cognee/modules/users/models/User.py#L15-L57`).
- Hierarchy: `Principal` → inherited by `User` and `Role`.
- Tenancy: `Tenant` model with many-to-many mappings via `UserTenant`.
- Permissions: `ACL` table links `principal_id` to `dataset_id` with discrete permission grants (`read`, `write`, `admin`).
- Agent Hierarchy: The `User` model defines an optional `parent_user_id` foreign key (`User.py#L25`). When an autonomous agent or subagent user creates datasets, the parent human user automatically inherits full read/write permissions.

---

## 2. The Cognify Pipeline Step by Step

The `cognify` pipeline transforms unstructured data into an indexed multi-model knowledge graph. In `cognee/api/v1/cognify/cognify.py#L616-L654`, the default task sequence is defined:

```
[Raw Ingested Data]
        │
        ▼
Task 1: classify_documents (classify Data into typed Document subclasses)
        │
        ▼
Task 2: extract_chunks_from_documents (split Document into DocumentChunk items)
        │
        ▼
Task 3: extract_graph_and_summarize (parallel: LLM graph extraction + summarization)
        │
        ▼
Task 4: add_data_points (fan-out write: relational ledger → graph DB → vector DB)
        │
        ▼ (optional)
Task 5: record_provenance (stamp pipeline and task metadata)
```

### 2.1 Step 1: Document Classification
- **Source:** `cognee/tasks/documents/classify_documents.py#L24-L66`
- **Logic:** Inspects file extensions and MIME types, mapping them via `EXTENSION_TO_DOCUMENT_CLASS` to specialized `Document` subclasses (`PdfDocument`, `TextDocument`, `CsvDocument`, `ImageDocument`, `AudioDocument`, `CodeFileDocument`, `DltSourceDocument`).
- **Metadata:** Extracts any `node_set` tags from `external_metadata` and attaches them to `document.belongs_to_set`.

### 2.2 Step 2: Chunking & Sizing
- **Source:** `cognee/tasks/documents/extract_chunks_from_documents.py#L33-L71`
- **Chunkers:**
  - `TextChunker` (default, `cognee/modules/chunking/TextChunker.py`): Paragraph-based chunker using `chunk_by_paragraph`. If a paragraph fits within `max_chunk_size`, it batches paragraphs together; if a single paragraph exceeds the budget, it cuts cleanly.
  - `LangchainChunker` (`cognee/modules/chunking/LangchainChunker.py`): Recursive character text splitting with configurable overlap.
  - `CsvChunker` / `JsonListChunker`: Row- and record-level chunking.
- **Chunk Sizing Formula:** Auto-resolved via `cognee/infrastructure/llm/utils.py#L53` (`resolve_chunk_size` *(corrected)*):
  $$\text{chunk\_size} = \min(\text{embedding\_token\_limit}, \lfloor\text{llm\_max\_completion\_tokens} / 2\rfloor)$$
  Typical default: 512 to 2048 tokens depending on the active embedding model.
- **Chunk Identity:** Content-addressed hash via `content_chunk_id(document_id, content_hash, occurrence)` (`TextChunker.py#L24-L28`).
- **Temporal Hint Propagation:** In `extract_chunks_from_documents.py#L65-L67`, each chunk runs through `hint_lines(chunk.text, temporal_base)` to extract date normalization context.

### 2.3 Step 3: Graph Extraction & Prompts
- **Source:** `cognee/tasks/graph/extract_graph_and_summarize.py#L15-L64` and `cognee/tasks/graph/extract_graph_from_data.py#L115-L220`
- **Output Models:** Defined in `cognee/shared/data_models.py#L49-L78`:
  ```python
  class Node(BaseModel):
      id: str
      name: str = ""
      type: str
      description: str

  class Edge(BaseModel):
      source_node_id: str
      target_node_id: str
      relationship_name: str
      description: str | None = Field(
          None,
          description="Concrete one-sentence fact expressed by this edge, using endpoint names."
      )

  class KnowledgeGraph(BaseModel):
      nodes: list[Node] = Field(..., default_factory=list)
      edges: list[Edge] = Field(..., default_factory=list)
  ```
- **Prompt:** `cognee/infrastructure/llm/prompts/generate_graph_prompt.txt`
  - Key instructions verbatim:
    > "Nodes represent entities and concepts. They're akin to Wikipedia nodes."  
    > "Edges represent relationships between concepts. They're akin to Wikipedia links."  
    > "Every edge should include a description when the text supports relevant information about the endpoints. The description must use the endpoint names, stay dry and efficient, and may include useful qualifiers from the source text. Do not add outside knowledge."  
    > "1. Labeling Nodes: Consistency: Ensure you use basic or elementary types for node labels (e.g. 'Person', not 'Mathematician' or 'Scientist'). Node IDs: Never utilize integers as node IDs. Node IDs should be names or human-readable identifiers found in the text. Every node MUST include a 'name' field."  
    > "2. Timestamps: A point in time is a node of type 'Timestamp'. Do not use type 'Date'. Its name and id are the normalized time string: `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, or `YYYY-MM-DD HH:MM:SS`. Link a time: use a `{verb}_at` relationship whose target is the Timestamp (e.g. `born_at`, `founded_at`, `launched_at`). Link a period Timestamp with `{verb}_during`."  
    > "4. Coreference Resolution: If an entity is mentioned multiple times in the text but is referred to by different names or pronouns, always use the most complete identifier for that entity throughout the knowledge graph."

### 2.4 Step 4: Ontology Support (RDF/OWL)
- **Source:** `cognee/modules/ontology/` and `cognee/modules/ontology/rdf_xml/RDFLibOntologyResolver.py#L37-L80`
- **Parser:** Uses `rdflib` to parse OWL, RDFS, Turtle, N3, or JSON-LD ontologies.
- **Matching Strategies:** `FuzzyMatchingStrategy` (`difflib.get_close_matches`) resolves extracted entity types to ontology classes.
- **Integration Modes:**
  - `"annotate"`: Adds ontology URIs as properties (`ontology_uri`) while preserving the LLM's natural types.
  - `"strict"`: Replaces natural types entirely with canonical ontology classes and rejects unknown relationships.
- In `construct_data_points_and_edges_with_ontology.py`, entities matching ontology nodes are instantiated with `ontology_valid=True` and stamped with `ontology_uri`.

### 2.5 Step 5: Entity Deduplication & Resolution
- **Intra-Batch Graph Deduplication:** `cognee/modules/graph/utils/deduplicate_nodes_and_edges.py#L4-L20` removes duplicate nodes by `str(node.id)` and edges by `str(edge[0]) + str(edge[2]) + str(edge[1])`.
- **Extraction-Level Node Deduplication:** `extract_graph_from_data.py#L44-L63` drops subsequent nodes with duplicate IDs:
  ```python
  # NOTE: This is a lossy strategy; duplicate IDs may deserve more careful handling.
  logger.warning("Ignoring duplicate extracted node ID: %s", node.id)
  ```
- **Deterministic Entity Identity:** `cognee/modules/graph/utils/expand_with_nodes_and_edges.py#L112-L152`:
  - Entities are mapped to deterministic UUID5s via `Entity.id_for(node.name)`.
  - When multiple distinct entities share a name in one chunk, it scopes them by chunk and ordinal: `Entity.id_for(node.name, data_chunk.id, ordinal)`.
  - Otherwise, exact string normalization produces identical UUID5s across chunks, merging nodes in graph storage. Cross-string coreference resolution across documents is not performed unless triggered in post-hoc consolidation.

### 2.6 Step 6: Summarization
- In `extract_graph_and_summarize.py#L26-L60`, chunk summaries are produced either:
  1. `summary_method="llm"` (default): Executes `summarize_text()` concurrently with graph extraction using `summarize_content.txt`. Output model is `SummarizedContent` (`summary: str`, bulleted facts).
  2. `summary_method="from_extraction"`: Bypasses the extra LLM call by concatenating extracted entity names and edge descriptions into a synthetic summary string (`build_summary_from_extraction.py`).

### 2.7 Step 7: What Fields Are Embedded?
Embeddings are computed on discrete fields declared in `DataPoint.metadata["index_fields"]`:
1. `DocumentChunk`: `metadata = {"index_fields": ["text"]}` → stored in vector collection `DocumentChunk_text`.
2. `Entity`: `metadata = {"index_fields": ["name"], "identity_fields": ["name"]}` → stored in `Entity_name`.
3. `TextSummary`: `metadata = {"index_fields": ["text"]}` → stored in `TextSummary_text`.
4. `EdgeType`: `metadata = {"index_fields": ["relationship_name"]}` → stored in `EdgeType_relationship_name` (used for triplet search).

### 2.8 Step 8: The DataPoint Model & Store Fan-Out
The base class for all persistent nodes is `DataPoint` (`cognee/infrastructure/engine/models/DataPoint.py#L28-L90`):
- Fields: `id: UUID`, `created_at: int (ms)`, `updated_at: int (ms)`, `version: int`, `topological_rank: int`, `feedback_weight: float = 0.5`, `importance_weight: float = 0.5`, `belongs_to_set: list`, `ontology_uri: str | None`.
- Storage metadata contract:
  - `index_fields`: list of string fields that must be embedded and written to vector storage.
  - `identity_fields`: list of fields whose values determine the deterministic `uuid5(NAMESPACE_OID, f"{cls.__name__}:{value}")`.

#### Store Fan-Out Execution
In `cognee/tasks/storage/add_data_points.py#L160-L360`, saving a batch of `DataPoint`s executes as follows:
1. **Relational Ledger Write (`add_data_points.py#L176-L210`):** An asynchronous SQLAlchemy session writes node and edge provenance records into PostgreSQL/SQLite (`upsert_nodes`, `upsert_edges`) and issues `await session.commit()`.
2. **Graph DB Node Write (`#L258-L271`):** Calls `graph_engine.add_nodes(group, source_ref_key=...)`.
3. **Vector DB Node Indexing (`#L343-L346`):** Calls `await index_data_points(nodes, vector_engine=vector_engine)`.
4. **Graph DB Edge Write (`#L283-L299`):** Calls `graph_engine.add_edges(group, source_ref_key=...)`.
5. **Vector DB Edge Indexing (`#L351-L360`):** Calls `index_graph_edges(edges, vector_engine=vector_engine)`.

### 2.9 Cross-Store Consistency Breakdown (Evidence for Engram Thesis)

In Cognee, there is **no distributed transaction or two-phase commit (2PC)** spanning the relational database, graph database, and vector database. The authors explicitly document this vulnerability in `cognee/tasks/storage/add_data_points.py#L325-L336`:

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

#### Exact Points of Inconsistency Failure:
1. **Graph write succeeds, Vector write fails:** Graph nodes exist in Neo4j/Kùzu, but their embeddings were never indexed in LanceDB/PGVector. A subsequent hybrid search or vector search will never retrieve these nodes. While Cognee attempts a rollback sweep using the relational ledger, if the worker process crashes before rollback completes, the graph remains silently unindexed.
2. **Relational commit succeeds, Graph write crashes:** The rollback ledger records the nodes as written, but the graph database has no corresponding records. Subsequent incremental loading and provenance lookups will query non-existent graph elements.
3. **Partial Edge Failure:** Nodes are written and indexed, but edge insertion in the graph fails due to constraint violations. The vector database now holds orphan embeddings for nodes that have no structural links in the knowledge graph.
4. **No cross-engine rollbacks:** A failure in LanceDB cannot trigger a transaction rollback in Neo4j or Kùzu. The system relies entirely on best-effort compensating cleanup loops in Python.

---

## 3. Temporal Modeling & Contradiction Handling

### 3.1 Deprecation of `temporal_cognify`
In earlier versions (≤1.6.2), Cognee had a dedicated `temporal_cognify=True` mode that generated explicit `Event` graph structures. This was **deprecated and disabled** in version 1.6.3 (`cognee/api/v1/cognify/cognify.py#L57-L82`):
```python
TEMPORAL_COGNIFY_DEPRECATED = (
    "temporal_cognify is deprecated and ignored, and will be removed in the next release: "
    "cognee 1.6.2 was the last release in which temporal_cognify=True built the event "
    "graph; since 1.6.3 the flag has no effect. cognify() now extracts dates as Timestamp nodes by default, "
    "and SearchType.TEMPORAL reranks by them..."
)
```

### 3.2 Current Temporal Architecture: Timestamp Nodes & Normalization Hints
Rather than maintaining bi-temporal intervals on edge records, Cognee models time as first-class graph nodes:
1. **Timestamp Nodes:** Every date or time expression is extracted as a `Timestamp` node (`cognee/modules/engine/models/Timestamp.py`).
   - Normalization: String format `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, or `YYYY-MM-DD HH:MM:SS`. Time ranges become `<start>/<end>` (e.g. `2024-03/2024-06`).
   - Leaf Property: Timestamp nodes have no outgoing relationships.
   - Directed Temporal Edges: Entities link to Timestamp nodes using `{verb}_at` (e.g. `born_at`, `founded_at`, `launched_at`, `begins_at`, `ends_at`) or `{verb}_during` for periods (`generate_graph_prompt.txt#L31-L36`).
   - Reversal Rule: In `expand_with_nodes_and_edges.py#L177-L200`, if an LLM draws an edge from a Timestamp to an entity (e.g. `1998 -discovery_of-> radium`), Cognee reverses the direction so the timestamp is always the target.
2. **Temporal Normalization Hints:** In `cognee/modules/engine/utils/temporal_hints.py`, relative expressions ("yesterday", "last July") are resolved against document timestamps or rolling bases into absolute hints passed to the extraction prompt (`TEMPORAL_NORMALIZATION_HINTS`).
3. **Record Timestamps:** `DataPoint.created_at` and `updated_at` record system transaction time in epoch milliseconds (`DataPoint.py#L65-L70`).

### 3.3 Fact Updates, Contradictions, and Truth Maintenance

Cognee does **not** perform transactional contradiction resolution or edge retirement during ingestion. In `cognify.py#L341-L345`:
```python
if "functional_relationships" in kwargs:
    raise TypeError(
        "cognify() no longer accepts functional_relationships; "
        "use improve(review_conflicts=True)"
    )
```

Instead, when contradicting facts are ingested (e.g., "Alice works at Stripe" followed by "Alice works at OpenAI"), both edges are inserted into the graph database. Contradiction handling is deferred to an offline, post-hoc self-improvement stage:

#### The `review_conflicts` Stage
- **Source:** `cognee/modules/improve/stages.py#L525-L580` and `cognee/tasks/memify/review_conflicts/`
- **Execution:** Runs only when `improve(review_conflicts=True)` is called.
- **LLM Review Prompt:** `cognee/infrastructure/llm/prompts/review_conflicts.txt`
  - Classifies attributes as `kind="time_varying"` (values can change over time) or `kind="fixed"` (only one value was ever true; discrepancy indicates an error).
  - Categorizes facts into `current`, `superseded`, or `conflicting`.
- **Graph Storage of Conflicts:** `cognee/tasks/memify/review_conflicts/write_conflicts.py`
  - Creates a `FactConflict` node in the graph.
  - Links the conflict node to the subject entity via `conflict_about` edge.
  - Links the conflict node to conflicting values via `conflict_value` edges.
  - Links to cited edges via `conflict_cites` edges.
  - Updates edge properties with `conflict_marks` JSON containing status (`"current"`, `"superseded"`, or `"conflicting"`) and `effective_date`.
- **Retrieval Rendering:** In `resolve_edges_to_text.py#L45-L67`, edges with conflict marks display status labels (`[current; as of 2026-03]` or `[superseded; as of 2024-01]`), and superseded edges are sorted last in the prompt context.

#### Truth Subspace
In `cognee/modules/truth_subspace/build.py`, distilled conversation learnings are projected onto $k$ centroid vectors with an `epoch` counter. Chunks carry `truth_alignment` vector coordinates. During retrieval, the hybrid reranker penalizes chunks whose epoch does not match the active centroid epoch.

---

## 4. Search Types & Retrieval Mechanics

Cognee supports 21 discrete `SearchType` values (`cognee/modules/search/types/SearchType.py#L5-L29`), dispatched to specialized retriever classes in `cognee/modules/retrieval/` (`cognee/modules/retrieval/README.md`):

| SearchType | Retriever Class | Underlying Mechanism | Output Format |
|---|---|---|---|
| `HYBRID_COMPLETION` | `HybridRetriever` | Parallel vector lanes (chunks, entities, global summaries) merged; defers to `GRAPH_COMPLETION` for custom node types or feedback | LLM Completion |
| `GRAPH_COMPLETION` | `GraphCompletionRetriever` | Brute-force triplet search + k-hop neighborhood expansion | LLM Completion |
| `GRAPH_COMPLETION_COT` | `GraphCompletionCotRetriever` | Multi-round Chain-of-Thought graph exploration | LLM Completion |
| `GRAPH_COMPLETION_CONTEXT_EXTENSION` | `GraphCompletionContextExtensionRetriever` | Iteratively expands graph context window across hops | LLM Completion |
| `GRAPH_COMPLETION_DECOMPOSITION` | `GraphCompletionDecompositionRetriever` | Decomposes query into sub-questions, executes graph search per sub-question | LLM Completion |
| `GRAPH_SUMMARY_COMPLETION` | `GraphSummaryCompletionRetriever` | Graph traversal using node/chunk summary embeddings | LLM Completion |
| `TEMPORAL` | `TemporalHybridRetriever` | LLM extracts time window; `get_timestamps_in_range` finds Timestamp nodes; chunks/entities anchored to them move to top | LLM Completion |
| `RAG_COMPLETION` | `CompletionRetriever` | Standard dense vector search over `DocumentChunk_text` + LLM generation | LLM Completion |
| `BROAD` | `BroadRetriever` | Dataset-wide questions (aggregations, counts); small datasets shown whole, large datasets loaded into SQLite (`broad_store.py`) | LLM Completion |
| `TRIPLET_COMPLETION` | `GraphCompletionRetriever` | **Deprecated** (SDK-1115); triplet vector collection was removed; alias for `GRAPH_COMPLETION` | LLM Completion |
| `AGENTIC_COMPLETION` | `AgenticRetriever` | Multi-turn agent loop executing skills and tool calls | LLM Completion |
| `CHUNKS` | `ChunksRetriever` | Dense vector k-NN search over `DocumentChunk_text` | List of `DocumentChunk` |
| `CHUNKS_LEXICAL` | `BM25ChunksRetriever` | In-memory BM25 lexical keyword search over chunks | List of `DocumentChunk` |
| `SUMMARIES` | `SummariesRetriever` | Dense vector k-NN search over `TextSummary_text` | List of `TextSummary` |
| `SKILLS` | `SkillsRetriever` | Metadata-only discovery of skill definitions | List of Skills |
| `CODE` | `CodeRetriever` | Deterministic code-graph operations (`explore`, `impact_analysis`) | Structural Code Context |
| `CODING_RULES` | `CodingRulesRetriever` | Retrieves stored coding conventions and rules | Coding Rule Text |
| `CYPHER` | `CypherSearchRetriever` | Executes raw OpenCypher query directly against graph DB (guarded by `ALLOW_CYPHER_QUERY=true`) | Raw Graph Records |
| `NATURAL_LANGUAGE` | `NaturalLanguageRetriever` | LLM translates natural language into Cypher query, executes it, formats results | LLM Completion |
| `GRAPH_REPORT` | `GraphReportRetriever` | Computes graph metrics (hubs, degree distribution, cross-nodeset edges, suggested queries) | Markdown Graph Report |
| `FEELING_LUCKY` | `select_search_type.py` | LLM classifier selects the optimal `SearchType`, then runs that retriever | Dynamic |

### 4.1 Triplet Search Implementation (`brute_force_triplet_search`)
Unlike systems that perform graph traversal inside the database engine, Cognee's primary graph search (`cognee/modules/retrieval/utils/brute_force_triplet_search.py#L231-L280`) is executed in Python memory:
1. **Vector Seed Search:** Queries `Entity_name` and `EdgeType_relationship_name` vector collections using the query embedding to retrieve the top `wide_search_top_k` candidate IDs.
2. **In-Memory Graph Projection:** Calls `get_memory_fragment()` (`#L50-L100`), which fetches nodes and edges matching those IDs from the graph database and instantiates an in-memory `CogneeGraph` (subclassing `CogneeAbstractGraph`, backed by Python dictionaries and lists, not NetworkX) *(corrected)*.
3. **Distance Mapping:** Maps vector cosine distances onto graph nodes (`map_vector_distances_to_graph_nodes`) and edges (`map_vector_distances_to_graph_edges`), ranking them via `heapq.nsmallest` *(corrected)*.
4. **Scoring Formula:** Calculates triplet importance in Python memory:
   $$\text{Score}(e) = \text{Dist}(u) + \text{Dist}(v) + \text{Dist}(e) + \text{Penalty} \times (1 - \text{FeedbackWeight})$$
   Applies `triplet_distance_penalty` (default 6.5) and returns the top-$k$ edges.

### 4.2 Context Formatting for LLMs
In `cognee/modules/graph/utils/resolve_edges_to_text.py#L69-L115`, retrieved graph triplets are formatted into a human-readable text block:
```
Node: Albert Einstein... [physicist, relativity]
__node_content_start__
Theoretical physicist who developed the theory of relativity.
__node_content_end__

Node: Institute for Advanced Study... [princeton, research]
__node_content_start__
Theoretical research institute in Princeton, New Jersey.
__node_content_end__

Albert Einstein --[joined]--> Institute for Advanced Study [current; as of 1933]
```
If chunk conflicts exist, they are appended as a trailing block (`format_conflicts`). This formatted text is injected into the user prompt template (`graph_context_for_question.txt` or `hybrid_context_for_question.txt`).

---

## 5. Self-Improvement Loop (`improve`) & Feedback

The `improve()` API (`cognee/api/v1/improve/improve.py#L135-L185`) orchestrates offline graph enrichment across 9 sequential stages defined in `cognee/modules/improve/registry.py#L26-L36`:

```
Stage 1: FeedbackWeightsStage       ──> Updates node/edge feedback_weight via alpha learning rate
Stage 2: PersistSessionQAStage      ──> Cognifies raw session Q&A into permanent graph (FATAL stage)
Stage 3: PersistAgentTracesStage    ──> Cognifies tool execution traces into agent_trace_feedbacks
Stage 4: ExtractAgentContextStage   ──> Flushes trace windows into agent profile lessons
Stage 5: DistillSessionsStage       ──> LLM distills session guidance into session_learnings NodeSet
Stage 6: UpdateUserPreferencesStage ──> Folds turn ratings into prefers subgraph
Stage 7: BuildTruthSubspaceStage    ──> Projects session_learnings into truth centroid coordinates
Stage 8: ReviewConflictsStage       ──> Reconciles fact changes into FactConflict nodes
Stage 9: GlobalContextIndexStage    ──> Builds hierarchical root/bucket summaries for broad search
```

### 5.1 Feedback Weight Mechanics
- **Source:** `cognee/modules/improve/stages.py#L132-L160` and `cognee/memify_pipelines/apply_feedback_weights.py`
- When users score turns via `FeedbackEntry`, Stage 1 computes an exponential moving average update on the graph elements that generated that answer:
  $$w_{\text{new}} = (1 - \alpha) \cdot w_{\text{old}} + \alpha \cdot \text{feedback\_score}$$
  where $\alpha = \text{DEFAULT\_FEEDBACK\_ALPHA} = 0.1$.
- Updated `feedback_weight` values are written to graph nodes/edges and used during subsequent triplet search scoring.

### 5.2 Debouncing & Concurrency
- `remember(session_id=...)` debounces automatic `improve` triggers via `ImproveConfig` where defaults are `debounce_entries: int = 1` and `debounce_seconds: float = 0.0` (no debounce by default; 10 entries and 300 seconds are suggested tuning values, `cognee/modules/improve/config.py#L47-L48` *(corrected)*).
- Lock coordination uses session-scoped locks (`try_acquire_improve_lock_many`). When a session loses a lock claim to a concurrent run, it requests a rerun (`rerun_requested`), allowing the active worker to execute an extra pass (`IMPROVE_MAX_RERUN_PASSES = 3`) before releasing (`improve.py#L35-L42`).

---

## 6. Pipelines & Tasks Framework

Cognee includes a custom task execution framework (`cognee/modules/pipelines/`):

### 6.1 Task Abstraction
- Defined in `cognee/modules/pipelines/tasks/task.py#L188-L250`:
  ```python
  class Task:
      executable: Callable
      task_config: dict = {"batch_size": 1}
      default_params: dict = {}
      enriches: bool = False
      needs_llm: bool = True
  ```
- Uses decorator `@task(batch_size=20, needs_llm=False)` returning a `TaskSpec`. Calling `TaskSpec(kwarg=val)` returns a `BoundTask` that captures arguments for deferred execution in `run_pipeline` (`task.py#L8-L33`).

### 6.2 Execution, Batching, and Async Streaming
- `run_pipeline(steps, data, user, ...)` (`cognee/modules/pipelines/operations/run_pipeline.py#L37-L100`) delegates to `run_tasks_base.py`.
- Execution is fully asynchronous using `AsyncGenerator`. Step outputs stream directly as inputs to subsequent steps. If a task produces items one-by-one, downstream tasks batch them up to `task_config["batch_size"]` before invoking the next executable.

### 6.3 Pipeline Run Status & Tracking
- Pipeline state is tracked in the relational database using SQLAlchemy models `PipelineRun` and `TaskRun` (`cognee/modules/pipelines/models/PipelineRun.py`).
- State representations (`PipelineRunInfo.py#L9-L61`):
  - `PipelineRunStarted`
  - `PipelineRunYield`
  - `PipelineRunCompleted`
  - `PipelineRunAlreadyCompleted` (emitted on incremental no-op)
  - `PipelineRunErrored` (carries scrubbed `error_class` and `error_message`)
  - `PipelineRunProgress` (tracks `completed_items`, `total_items`, `current_stage`).

### 6.4 Incremental Loading & Idempotency
- When `incremental_loading=True` (default in `cognify`), data items are fingerprinted by SHA-256 hash (`content_hash`).
- If an ingested file's hash already matches a completed `PipelineRun` for that dataset, the item is skipped (`refuse_changed_existing_documents.py`).
- For DLT manifests, `purge_stale_dlt_source_artifacts` drops previously derived graph edges before re-emission to prevent accretion.

---

## 7. Storage Adapter Interfaces

Cognee abstracts storage behind formal abstract base classes. These define the minimal set of database operations required by any memory engine:

### 7.1 GraphDBInterface (52 Methods *(corrected)*)
Source: `cognee/infrastructure/databases/graph/graph_db_interface.py#L110-L450`

```python
class GraphDBInterface(ABC):
    # Graph Lifecycle & Queries
    async def is_empty(self) -> bool: ...
    async def query(self, query: str, params: dict) -> list[Any]: ...
    async def delete_graph(self) -> None: ...
    async def get_graph_data(self) -> tuple[list[Node], list[EdgeData]]: ...
    async def get_graph_counts(self) -> tuple[int, int]: ...
    async def get_graph_metrics(self, include_optional: bool = False) -> dict[str, Any]: ...

    # Node Operations
    async def add_node(self, node: NodeData) -> None: ...
    async def add_nodes(self, nodes: list[NodeData], source_ref_key=None, pipeline_run_id=None) -> None: ...
    async def get_node(self, node_id: str) -> NodeData | None: ...
    async def get_nodes(self, node_ids: list[str]) -> list[NodeData]: ...
    async def update_node(self, node_id: str, values: dict[str, Any]) -> bool: ...
    async def delete_node(self, node_id: str) -> None: ...
    async def delete_nodes(self, node_ids: list[str]) -> None: ...

    # Edge Operations
    async def add_edge(self, edge: EdgeData) -> None: ...
    async def add_edges(self, edges: list[EdgeData], source_ref_key=None, pipeline_run_id=None) -> None: ...
    async def has_edge(self, source_id: str, target_id: str, relationship_name: str) -> bool: ...
    async def has_edges(self, edges: list[EdgeData]) -> list[EdgeData]: ...
    async def get_edges(self, node_id: str) -> list[EdgeData]: ...
    async def delete_edge_triples(self, triples: list[tuple[str, str, str]]) -> None: ...

    # Traversal & Neighborhoods
    async def get_neighbors(self, node_id: str) -> list[NodeData]: ...
    async def get_neighborhood(self, node_id: str, depth: int = 1) -> tuple[list[NodeData], list[EdgeData]]: ...
    async def iter_bounded_neighborhood(self, seed_ids: list[str], max_depth: int, max_nodes: int): ...
    async def get_top_degree_node_ids(self, top_k: int) -> list[str]: ...
    async def get_nodeset_subgraph(self, node_set_names: list[str]) -> tuple[list[NodeData], list[EdgeData]]: ...
    async def get_connections(self, node_ids: list[str]) -> list[EdgeData]: ...

    # Temporal Traversal
    async def get_timestamps_in_range(self, start: int | None, end: int | None) -> list[NodeData]: ...
    async def get_temporal_anchors(self, start: int | None, end: int | None) -> dict[str, list[str]]: ...

    # Provenance Source References (for scoped deletion)
    async def attach_node_source_refs(self, node_ids: list[str], source_ref_keys: list[str], pipeline_run_id=None): ...
    async def attach_edge_source_refs(self, edge_identities: list[EdgeIdentity], source_ref_keys: list[str], pipeline_run_id=None): ...
    async def remove_node_source_refs(self, node_ids: list[str], source_ref_keys: list[str]): ...
    async def remove_edge_source_refs(self, edge_identities: list[EdgeIdentity], source_ref_keys: list[str]): ...
    async def find_nodes_by_source_ref(self, source_ref_key: str) -> list[str]: ...
    async def find_edges_by_source_ref(self, source_ref_key: str) -> list[EdgeIdentity]: ...

    # Feedback & Truth Weights
    async def get_node_feedback_weights(self, node_ids: list[str]) -> dict[str, float]: ...
    async def set_node_feedback_weights(self, weights: dict[str, float]) -> None: ...
    async def get_edge_feedback_weights(self, edge_object_ids: list[str]) -> dict[str, float]: ...
    async def set_edge_feedback_weights(self, weights: dict[str, float]) -> None: ...
    async def get_node_truth_state(self, node_ids: list[str]) -> dict[str, dict[str, Any]]: ...
    async def set_node_truth_state(self, states: dict[str, dict[str, Any]]) -> None: ...
```

- **Implemented Backends:** Neo4j (`Neo4jAdapter`, `Neo4jCommunityAdapter`), Kùzu/Ladybug in-process (`LadybugAdapter`), Kùzu/Ladybug subprocess (`LadybugSubprocess`), Remote Ladybug, AWS Neptune (`NeptuneGraphDB`), Neptune Analytics (`NeptuneAnalyticsAdapter`), Turso local (`TursoAdapter`), and PostgreSQL demo (`PostgresDemoAdapter`).

### 7.2 VectorDBInterface (22 Methods)
Source: `cognee/infrastructure/databases/vector/vector_db_interface.py#L30-L150`

```python
class VectorDBInterface(ABC):
    async def has_collection(self, collection_name: str) -> bool: ...
    async def create_collection(self, collection_name: str, payload_schema: type | None = None) -> None: ...
    async def get_collection(self, collection_name: str): ...
    async def create_vector_index(self, index_name: str, index_property_name: str): ...
    async def create_data_points(self, collection_name: str, data_points: list[DataPoint]): ...
    async def index_data_points(self, collection_name: str, data_points: list[DataPoint]): ...
    async def upsert_raw_vectors(self, collection_name: str, vectors: list[list[float]], ids: list[str], payloads: list[dict]): ...
    async def retrieve(self, collection_name: str, data_point_ids: list[str]): ...
    async def score_by_ids(self, collection_name: str, data_point_ids: list[str], query_vector: list[float]): ...
    async def search(self, collection_name: str, query_vector: list[float], limit: int = 10, with_vector: bool = False): ...
    async def batch_search(self, collection_name: str, query_vectors: list[list[float]], limit: int = 10): ...
    async def update_payload(self, collection_name: str, filter_dict: dict, payload: dict): ...
    async def delete_data_points(self, collection_name: str, data_point_ids: list[UUID]): ...
    async def remove_belongs_to_set_tags(self, collection_name: str, data_point_ids: list[str], tags: list[str]): ...
    async def compact(self, collection_name: str | None = None): ...
    async def prune(self): ...
    async def embed_data(self, data: list[str]) -> list[list[float]]: ...
    async def create_dataset(cls, dataset_id: UUID | None, user: User | None) -> dict: ...
    async def delete_dataset(self, dataset_id: UUID, user: User) -> None: ...
```

- **Implemented Backends:** LanceDB (`LanceDBAdapter` and subprocess), PGVector (`PGVectorAdapter`), Neptune Analytics, Turso Vector, and community integrations (Qdrant, Weaviate, Milvus).

---

## 8. MCP Server (`cognee-mcp`)

Cognee ships a standalone Model Context Protocol server package (`cognee-mcp/`, `cognee-mcp/src/server.py`):

### 8.1 Registered MCP Tools
Registered via FastMCP (`cognee-mcp/src/server.py#L356-L925`):
1. `remember`: Stores information into memory.
   - Parameters: `data (str)`, `filename (str)`, `content_base64 (str)`, `dataset_name (str)`, `background (bool)`, `ontology (str)`, `node_set (str)`.
2. `recall`: Queries memory.
   - Parameters: `query (str)`, `search_type (str, default "HYBRID_COMPLETION")`, `datasets (str)`, `top_k (int, default 15)`, `scope (str: "auto"|"all"|"tools"|"code"|"skills")`, `session_id (str)`, `node_name (str)`, `include_summary (bool)`, `code_query (dict)`, `auto_route (bool)`.
3. `code_search`: Runs code graph operations.
   - Parameters: `operation ("query_facts"|"explore"|"impact_analysis"|"ask")`, `query (str)`, `file_path (str)`, `repo_name (str)`, `max_results (int)`.
4. `forget`: Deletes data from memory.
   - Parameters: `dataset (str)`, `everything (bool)`, `data_id (str)`, `dataset_id (str)`.
5. `cognify_status`: Monitors asynchronous background ingestion progress.
   - Parameters: `dataset_name (str)`, `pipelines (list[str])`.

*(Note on `improve`: While `async def improve(...)` is defined in `cognee-mcp/src/server.py#L813-L820`, it lacks the `@registry.tool(...)` decorator and is never exposed in the MCP tool catalog. Only 5 tools are actively registered: `remember`, `recall`, `code_search`, `forget`, `cognify_status` *(corrected)*.)*
   - Parameters: `dataset_name (str)`, `pipelines (list[str])`.

### 8.2 Transports & Modes
Configured in `cognee-mcp/src/server.py#L1228-L1244`:
- **Transports:** `stdio` (default for CLI agent integrations like Claude Desktop or Cursor), `sse` (Server-Sent Events), and `http` (Streamable HTTP via Starlette).
- **Tool Modes:** Controlled via `--tool-mode` or `COGNEE_MCP_TOOL_MODE`:
  - `default`: Advertises standard tools.
  - `minimal`: Pins tool catalog strictly to core memory tools tagged with `MEMORY_TAG` (`remember`, `recall`, `forget`).

---

## 9. Hermes Agent Integration

The Hermes Agent integration is maintained in `topoteretes/cognee-integrations/integrations/hermes-agent` and published in Hermes catalog manifest `~/.hermes/hermes-agent/plugin-catalog/cognee.yaml`:

### 9.1 Catalog Capabilities
From `plugin-catalog/cognee.yaml#L12-L24`:
```yaml
capabilities:
  provides_tools:
    - cognee_recall
    - cognee_remember
    - cognee_forget
    - cognee_switch_dataset
    - cognee_code_search
    - cognee_recap
  provides_hooks:
    - on_session_end
    - on_pre_compress
    - on_memory_write
  provides_middleware: []
  requires_env: []
```

### 9.2 Architecture & Lifecycle Mapping (`provider.py`)
`CogneeMemoryProvider` subclasses Hermes's `MemoryProvider` base class:
- **Connection Modes:**
  - `local-server` (default): Spawns a local background Uvicorn daemon on `127.0.0.1:8011` (`server_bootstrap.py`). The provider communicates via HTTP requests using Python standard library `urllib`.
  - `remote`: Connects to Cognee Cloud or a managed Cognee server via `COGNEE_BASE_URL`.
  - `embedded`: Runs Cognee in-process. Explicitly warned against:
    > "cognee's local stores (SQLite, Kuzu/Ladybug, LanceDB) are single-writer. Driving them in-process from the agent's background threads... risks database is locked errors and corruption." (`integrations/hermes-agent/README.md#L213-L217` *(corrected)*)
- **Lifecycle Hooks:**
  1. `prefetch(query, session_id)` (`provider.py#L681` *(corrected)*): Retrieves memory context for the upcoming turn. Formats graph triplets and session guidance into a markdown block with a plain-text hit counter.
  2. `sync_turn(user_content, assistant_content, session_id, ...)` (`provider.py#L713` *(corrected)*): Enqueues conversation turn and tool-execution traces to the background writer thread. Turns are stored in Cognee's session cache (`QAEntry` and `TraceEntry`). If the server is offline, turns are buffered in `~/.cognee-plugin/` and drained when reconnected.
  3. `on_session_end(messages)` (`provider.py#L1083-L1108`): Drains pending write buffers, then invokes an **out-of-process closer worker** (`exit_watcher.py`, `python exit_watcher.py --state <path> [--final]` *(corrected)*). This detached process triggers `cognee.improve()` to bridge session cache turns into the permanent knowledge graph, ensuring Hermes exit is never delayed by graph construction.
  4. `on_pre_compress(messages)` (`provider.py#L1110-L1150`): Implements Hermes pre-compress checkpoint API v1. Runs `improve()` in the background before conversation history is summarized away, guaranteeing that compressed turns reach the graph.
  5. `on_memory_write(action, target, content, metadata)` (`provider.py#L1275-L1315`): Intercepts explicit Hermes writes to built-in `MEMORY.md` or `USER.md` (`add` / `replace`), redacts sensitive data, and mirrors them into permanent Cognee memory (`_remember_permanent`).

---

## 10. Observability, Deployment Footprint & Costs

### 10.1 Observability
- **OpenTelemetry & Langfuse:** Fully integrated via `cognee/modules/observability/get_observe.py` and `tracing.py`.
- **GenAI Semantic Conventions:** Emits standard OTel span attributes:
  - `gen_ai.system` (e.g. `"openai"`), `gen_ai.request.model` (`"gpt-4o"`).
  - `gen_ai.operation.name = "embeddings"`, `gen_ai.embeddings.dimension.count`.
  - `langfuse.observation.type = "generation"`.
  - Captures sanitized prompt payloads in `langfuse.observation.input` and model completions in `langfuse.observation.output` (capped at 8,000 characters).
- **Distributed Tracing:** Spans link pipelines, tasks, and database queries (`cognee.pipeline.task.<name>`) with trace context propagation.

### 10.2 Configuration & Environment Variables
Over 100 configuration keys are templated in `.env.template`:
- **LLM/Embeddings:** `LLM_PROVIDER`, `LLM_MODEL`, `LLM_ENDPOINT`, `LLM_API_KEY`, `EMBEDDING_PROVIDER`, `EMBEDDING_MODEL`, `EMBEDDING_DIMENSIONS`, `HUGGINGFACE_TOKENIZER`.
- **Databases:** `DB_PROVIDER` (`"postgres"`|`"sqlite"`), `DB_HOST`, `DB_PORT`, `GRAPH_DATABASE_PROVIDER` (`"ladybug"`|`"neo4j"`|`"kuzu"`|`"turso"`), `VECTOR_DB_PROVIDER` (`"lancedb"`|`"pgvector"`|`"turso"`).
- **Tuning:** `LLM_RATE_LIMIT_ENABLED`, `CHUNK_SIZE`, `CHUNKS_PER_BATCH`, `SUMMARY_METHOD` (`"llm"`|`"from_extraction"`), `GRAPH_EXTRACTOR` (`"llm"`|`"gliner_demo"`), `ALLOW_CYPHER_QUERY`.

### 10.3 Deployment Footprint
- **Container Architecture (`docker-compose.yml`):**
  - `cognee`: Backend FastAPI API server.
  - `cognee-mcp`: FastMCP service.
  - `frontend`: Next.js web UI.
  - `neo4j`: Graph database daemon.
  - `postgres`: Relational database daemon.
  - `redis`: Session cache daemon.
- **Image Overhead (`Dockerfile`):** Base image `python:3.12-bookworm-slim` with `build-essential`, `clang`, `cmake`, and `libpq-dev` required for native C extension compilation (Kùzu, LanceDB). Virtualenv lockfile (`uv.lock`) exceeds 2.3 MB with hundreds of dependencies.

### 10.4 Ingestion LLM Call Count & Cost per Document
According to Cognee's dry-run cost estimator (`cognee/modules/cognify/estimator.py#L62-L75`), the default `cognify` pipeline incurs:
1. **Graph Extraction:** 1 structured output LLM call per chunk (`extract_graph_from_data`). Output tokens estimate: $\max(256, 0.5 \times \text{chunk\_tokens})$.
2. **Chunk Summarization:** 1 text summarization LLM call per chunk (`summarize_text`). Output tokens estimate: ~150 tokens.
3. **Total LLM Calls:** Exactly **2 LLM calls per chunk** (or 20 LLM calls for a typical 10-chunk document). Setting `summary_method="from_extraction"` reduces this to 1 LLM call per chunk.
4. **Vector Embeddings:** 4 embedding calls per chunk (`DocumentChunk_text`, `Entity_name`, `TextSummary_text`, `EdgeType_relationship_name`).
5. **Reasoning Multiplier:** For reasoning models (o1/o3/gpt-5), hidden reasoning tokens scale cost by an estimated $20\times$ (`REASONING_OUTPUT_MULTIPLIER = 20`).

---

## 11. Weaknesses & Limitations Observed

1. **Poly-Store Drift & Broken Consistency:**
   No atomic commit spans relational metadata, graph edges, and vector indices. Network or process failure mid-pipeline leaves dangling nodes, unindexed chunks, and permanent drift between stores.
2. **Operational Complexity:**
   Self-hosting a complete Cognee stack requires managing four separate database engines (Postgres, Neo4j, LanceDB, Redis) alongside FastAPI and MCP services.
3. **Single-Writer Embedded Concurrency Failures:**
   In local embedded deployments, SQLite, Kùzu/Ladybug, and LanceDB crash with lock errors under concurrent threads. This forced the Hermes integration to run an external Uvicorn server daemon on port 8011.
4. **Inefficient In-Memory Graph Querying:**
   `brute_force_triplet_search` pulls graph subgraphs into an in-memory `CogneeGraph` Python structure instead of executing graph joins inside the database engine, limiting graph scalability *(corrected)*.
5. **Post-Hoc / Non-Transactional Contradictions:**
   Ingestion blind-writes contradictory claims to the graph. Facts are only reconciled if an expensive offline batch stage (`review_conflicts`) is explicitly scheduled.
6. **High Token & LLM Latency Overhead:**
   Generating both structured entity graphs and free-form summaries requires 2 LLM round trips per chunk, significantly slowing down write pipelines.
7. **Lossy Entity Resolution:**
   Cross-document entity merging relies strictly on exact normalized name strings (`Entity.id_for(name)`). Duplicate extracted IDs in chunks are arbitrarily discarded.

---

## Patterns for Engram

The table below contrasts Cognee's implementation patterns with Engram's concrete Rust + SurrealDB design:

| Pattern | How Cognee Does It (Source Citation) | Verdict for Engram | Concrete Adaptation for Rust + SurrealDB |
|---|---|---|---|
| **Storage Architecture** | Multi-store coordinator spanning SQLAlchemy, Neo4j/Kùzu, and LanceDB (`cognee/tasks/storage/add_data_points.py#L143-L360`). | **Reject** | **Single Multi-Model Engine:** Store entities, episodes, bi-temporal graph edges (`RELATE ->fact->`), vector embeddings (`array<float>`), and BM25 full-text indexes inside SurrealDB under a single ACID transaction (`BEGIN TRANSACTION ... COMMIT TRANSACTION`). Zero drift, zero glue code *(superseded by 00-decisions.md §1 row 20: relation table renamed to fact)*. |
| **Write Consistency** | Best-effort sequential writes (relational → graph → vector) with compensating rollback ledger (`cognee/tasks/storage/add_data_points.py#L325-L336`). | **Reject** | **Single-Statement Atomic Writes:** Persist episode raw text, upserted entities, graph relations, and vector embeddings in one SurrealQL transaction. If any part fails, the entire transaction aborts cleanly with no orphan data. |
| **Bi-Temporal Edge Schema** | Timestamps modeled as discrete `Timestamp` nodes with `{verb}_at` edges (`generate_graph_prompt.txt#L22-L42`). Integer ms timestamps on `DataPoint` (`DataPoint.py#L65-L70`). | **Adapt** | **Bi-Temporal Edge Fields:** Model time natively on `fact` relation records: `valid_from` (world time start), `valid_to` (world time end; `NONE` if current), and `learned_at` (system transaction time). Enables time-travel queries (`WHERE valid_from <= $t AND (valid_to = NONE OR valid_to > $t)`) *(superseded by 00-decisions.md §1 row 20: relation table renamed to fact)*. |
| **Fact Contradiction & Updates** | Competing facts inserted blindly; offline batch LLM pass (`improve(review_conflicts=True)`) creates `FactConflict` nodes and `conflict_marks` (`write_conflicts.py#L1-L60`). | **Adapt & Upgrade** | **Inline Functional Reconciliation:** Reconcile facts during the write-path pipeline. If an incoming fact asserts a new object for a functional predicate, close the prior edge (`SET valid_to = time::now()`), insert the new edge, mark `contested = true` if disputed, and link via `contradiction_of = <record<asserts>>`. |
| **Graph Extraction Models** | Pydantic models `KnowledgeGraph`, `Node`, `Edge` (`cognee/shared/data_models.py#L49-L78`) with extraction prompts (`generate_graph_prompt.txt`). | **Adopt & Adapt** | **Serde-Structured Extraction:** Adopt the structured entity-edge extraction schema in Rust using `serde` models. Restrict relationships to a closed vocabulary (~10 domain predicates: `works_at`, `owns`, `prefers`, `depends_on`, `located_at`, `uses`, etc.) to prevent prompt drift. |
| **DataPoint Index Specifications** | `DataPoint.metadata["index_fields"]` defining separate vector collections per field (`cognee/infrastructure/engine/models/DataPoint.py#L36-L55`). | **Adapt** | **SurrealQL Schema Definition:** Declare vector search indexes directly on table columns in `schema.surql` (`DEFINE INDEX entity_vec ON entity FIELDS embedding HNSW DIMENSION 1024 DIST COSINE` *(corrected)*). Embeddings reside directly in the record row *(superseded by 00-decisions.md ADR-16 and §1 row 16: MTREE removed)*. |
| **Subgraph Partitioning (NodeSets)** | `NodeSet` nodes linked via `belongs_to_set` edges (`cognee/modules/engine/models/node_set.py#L11-L32`). | **Adapt** | **Tag / Relation Sets:** Store partition tags on `entity` and `asserts` records (`tags = ["session_learnings", "user_preferences"]`), queryable with native SurrealQL operators (`WHERE "user_preferences" IN tags`). |
| **Retrieval Execution** | `brute_force_triplet_search`: vector search seed → project graph into Python `CogneeGraph` → score triplets in memory (`brute_force_triplet_search.py#L231-L280` *(corrected)*). | **Reject** | **In-Engine Native Traversal:** Execute dense vector search, BM25 full-text search, and 1–2 hop graph traversal (`SELECT ->fact->entity.* FROM $seed_entities WHERE valid_to = NONE`) natively inside SurrealDB. Fuse candidate ranks in Rust using Reciprocal Rank Fusion (RRF) *(superseded by 00-decisions.md §1 row 20: relation table renamed to fact)*. |
| **Session-to-Graph Promotion** | Session Q&A stored in cache; promoted to graph during `on_session_end` or `on_pre_compress` via detached closer worker (`exit_watcher.py` *(corrected)*, `integrations/hermes-agent/provider.py#L1083-L1150`). | **Adapt** | **Non-Blocking Write-Behind:** `sync_turn` enqueues `{user, assistant, session_id}` onto a single-writer background thread via `spawn_context_thread`. Writes raw `episode` immediately; asynchronously runs entity/edge extraction and reconciliation. |
| **Daemon Process Requirements** | Runs external Uvicorn server on port 8011 (`server_bootstrap.py`) to bypass embedded single-writer database locks (`README.md#L213-L217` *(corrected)*). | **Reject** | **Single Daemon / Embedded Mode:** All-in-one image runs `engram` supervising the official `surreal` process bound to `127.0.0.1:8000` over HTTP RPC *(superseded by 00-decisions.md ADR-01, ADR-02, ADR-03: in-process embedded surrealdb-core rejected)*. No external Python HTTP daemons or multi-container orchestrations. |
| **Observability** | OpenTelemetry spans with GenAI attributes (`gen_ai.request.model`) and Langfuse integration (`cognee/modules/observability/get_observe.py#L15-L50`). | **Adopt** | **Native Rust Tracing:** Implement `tracing` crate with OpenTelemetry OTLP subscriber, emitting standardized GenAI spans for embeddings, extractions, and queries. |

---

## 12. Verification Citations

All findings in this report were verified against the local source trees:
- Cognee Core: `topoteretes/cognee` (version 1.6.5, commit `37f788b`).
- Hermes Plugin Manifest: `~/.hermes/hermes-agent/plugin-catalog/cognee.yaml`.
- Hermes Cognee Integration: `topoteretes/cognee-integrations/integrations/hermes-agent` (`__init__.py`, `provider.py`, `README.md`).
- SurrealDB & Engram PRD Input: `DISCOVERY_HANDOFF.md`.
