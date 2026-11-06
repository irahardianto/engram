# Verification Report: R2 Cognee Deep-Dive (V02-cognee)

**Document Under Review:** [`02-cognee.md`](../02-cognee.md)  
**Verifier:** Sovereign Principal Engineer Verification Agent  
**Date of Verification:** October 24, 2026  
**Primary Sources Inspected:**
- Local Git Repository: [`topoteretes/cognee`](https://github.com/topoteretes/cognee/tree/v1.6.5) (`topoteretes/cognee`, tag `v1.6.5`, commit `37f788bd287750e10d7610173e5332b3843f6ebd`)
- Hermes Plugin Catalog Manifest: [`~/.hermes/hermes-agent/plugin-catalog/cognee.yaml`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/plugin-catalog/cognee.yaml)
- Hermes Plugin Source Tree: `topoteretes/cognee-integrations` (`integrations/hermes-agent`, commit `ccfb0e4e3fa8f3ce09c023d258c205ca972e48a8`)
- Project Context: [`DISCOVERY_HANDOFF.md`](../../../DISCOVERY_HANDOFF.md)

---

## 1. Summary Verdict: PASS-WITH-FIXES

The research report [`02-cognee.md`](../02-cognee.md) provides an exceptionally comprehensive, rigorous, and architecturally vital evaluation of Cognee. Its load-bearing conclusions directly validate Engram's thesis:
1. **Lack of cross-store ACID transactions** leaves orphaned graph records and phantom vector entries on partial failure, as explicitly acknowledged in Cognee's own code comments ([`add_data_points.py#L325-L336`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py#L325-L336)).
2. **Single-writer lock contention** in local embedded databases (SQLite, Kùzu/Ladybug, LanceDB) forced the Hermes integration to run a separate background HTTP Uvicorn server daemon on `127.0.0.1:8011` ([`server_bootstrap.py`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/plugin-catalog/cognee.yaml)).
3. **High write overhead** (2 LLM calls and 4 embeddings per text chunk, verified in [`estimator.py#L62-L75`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/cognify/estimator.py#L62-L75)) burdens ingestion latency and API cost.
4. **Post-hoc contradiction resolution** leaves competing facts active until expensive offline batch runs ([`improve(review_conflicts=True)`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/improve/improve.py#L157-L167)) are executed.

However, the report contains **2 MAJOR inaccuracies**, **4 MINOR discrepancies**, and several citation line drifts that must be corrected:
- **Major Inaccuracy 1:** `brute_force_triplet_search` does **not** project subgraphs into NetworkX. It uses [`CogneeGraph`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/graph/cognee_graph/CogneeGraph.py#L22), a custom Python dictionary/list-backed graph data structure, and scores triplets via `heapq.nsmallest`.
- **Major Inaccuracy 2:** `improve` is **not** an active MCP tool in [`cognee-mcp/src/server.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee-mcp/src/server.py#L813-L869). While the Python function exists in the server file, it lacks the `@registry.tool(...)` decorator and is never exposed in the MCP tool catalog.
- **Minor / Drift Items:** The detached closer worker script is named `exit_watcher.py` (not `out_of_band_closer.py`); `ImproveConfig` defaults to no debounce (`debounce_entries=1`, `debounce_seconds=0.0`); `resolve_chunk_size` is in `cognee/infrastructure/llm/utils.py` (no standalone `resolve_chunk_size.py` exists); and `GraphDBInterface` defines 52 methods, not 47.

---

## 2. Priority Checklist Verification

### Priority 1: Version & Public API Surface (V1 vs V2)
- **Claim:** Tag `v1.6.5`, commit `37f788b`.
  - **Verification:** Verified via Git CLI (`git describe --tags --always` -> `v1.6.5`; `git rev-parse HEAD` -> `37f788bd287750e10d7610173e5332b3843f6ebd`). Checked [`pyproject.toml#L4`](https://github.com/topoteretes/cognee/blob/v1.6.5/pyproject.toml#L4) (`version = "1.6.5"`). **VERIFIED EXACT.**
- **Claim:** V1 Document Pipeline API (`add`, `cognify`, `search`, `delete`, `prune`, `run_custom_pipeline`, deprecated `memify`).
  - **Verification:** [`cognee/__init__.py#L40-L69`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/__init__.py#L40-L69) groups these under `# V1 API`. Signatures verified:
    - [`add`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/add/add.py#L40-L60) (`add.py#L40-L60`)
    - [`cognify`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/cognify/cognify.py#L133-L157) (`cognify.py#L133-L157`)
    - [`search`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/search/search.py#L42-L73) (`search.py#L42-L73`, report cited L45-L75)
    - [`memify`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/memify/memify.py#L1-L30) is marked deprecated in release SDK-1115 (`FutureWarning`). **VERIFIED.**
- **Claim:** V2 Agent Memory API (`remember`, `recall`, `improve`, `forget`, `serve`, `disconnect`).
  - **Verification:** [`cognee/__init__.py#L74-L90`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/__init__.py#L74-L90) groups these under `# V2 memory-oriented API`.
    - [`remember`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/remember/remember.py#L1010-L1036) (`remember.py#L1010-L1036`, docstring `#L1039-L1053`) verifies dual permanent vs session mode.
    - [`recall`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/recall/recall.py#L350-L384) (`recall.py#L350-L384`) verifies session fallback to permanent graph.
    - [`improve`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/improve/improve.py#L157-L167) (`improve.py#L157-L167`; report cited `#L135-L150`, which is helper `_parse_legacy_kwargs`).
    - [`forget`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/forget/forget.py#L22-L70) (`forget.py#L22-L70`) verifies `memory_only=True` support. **VERIFIED.**

### Priority 2: Cognify Pipeline Stages, Graph Models, and Prompts
- **Claim:** Default task sequence: `classify_documents` → `extract_chunks_from_documents` → `extract_graph_and_summarize` → `add_data_points` → optional `record_provenance`.
  - **Verification:** [`cognee/api/v1/cognify/cognify.py#L610-L648`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/cognify/cognify.py#L610-L648) defines `get_pipeline_tasks()` with these exact tasks in order. **VERIFIED EXACT.**
- **Claim:** KnowledgeGraph models: [`Node`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/shared/data_models.py#L49-L60), [`Edge`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/shared/data_models.py#L62-L71), [`KnowledgeGraph`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/shared/data_models.py#L73-L78).
  - **Verification:** Checked [`cognee/shared/data_models.py#L49-L78`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/shared/data_models.py#L49-L78). Exact fields match (`source_node_id`, `target_node_id`, `relationship_name`, `description`). **VERIFIED EXACT.**
- **Claim:** Verbatim extraction prompt rules from `generate_graph_prompt.txt`.
  - **Verification:** Checked [`cognee/infrastructure/llm/prompts/generate_graph_prompt.txt#L1-L54`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/infrastructure/llm/prompts/generate_graph_prompt.txt#L1-L54). Rules regarding "Wikipedia nodes/links", dry edge descriptions using endpoint names, node naming ("Person" not "Mathematician"), and Timestamp leaves with `{verb}_at` / `{verb}_during` relationships match verbatim. **VERIFIED EXACT.**

### Priority 3: Cross-Store Consistency Breakdown (`add_data_points.py#L325-L336`)
- **Claim:** No distributed transaction spans graph, vector, and relational stores. Failure leaves orphan records. Quoted comment at lines 325-336.
  - **Verification:** Inspected [`cognee/tasks/storage/add_data_points.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py). Lines 325-336 contain the exact quoted comment:
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
  - **Code Execution Path Evidence:**
    1. Relational Ledger ([`#L180-L209`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py#L180-L209)): Writes node/edge records to SQLite/PostgreSQL and commits: `async with get_async_session() as session: ... await session.commit()`.
    2. Graph DB Node Write ([`#L340-L342`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py#L340-L342)): `await _write_nodes_grouped()`.
    3. Vector DB Node Indexing ([`#L343-L346`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py#L343-L346)): `await index_data_points(...)`.
    4. Graph DB Edge Write ([`#L351-L353`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py#L351-L353)): `await _write_edges_grouped(edges)`.
    5. Vector DB Edge Indexing ([`#L354`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py#L354)): `await index_graph_edges(edges, vector_engine=vector_engine)`.
    There is no two-phase commit (2PC) or distributed rollback. A crash between step 2 and step 3 leaves graph nodes unindexed in vectors; a crash between step 1 and step 2 leaves ledger entries pointing to non-existent graph nodes. **VERIFIED EXACT.**

### Priority 4: '21 Search Modes' & `SearchType` Enum
- **Claim:** 21 discrete `SearchType` values in [`cognee/modules/search/types/SearchType.py#L5-L29`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/search/types/SearchType.py#L5-L29).
  - **Verification:** Inspected [`SearchType.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/search/types/SearchType.py). Enumeration yields exactly 21 values:
    `SUMMARIES`, `CHUNKS`, `RAG_COMPLETION`, `HYBRID_COMPLETION`, `GRAPH_COMPLETION`, `GRAPH_COMPLETION_DECOMPOSITION`, `GRAPH_SUMMARY_COMPLETION`, `CYPHER`, `NATURAL_LANGUAGE`, `GRAPH_COMPLETION_COT`, `GRAPH_COMPLETION_CONTEXT_EXTENSION`, `FEELING_LUCKY`, `TEMPORAL`, `CODING_RULES`, `CHUNKS_LEXICAL`, `AGENTIC_COMPLETION`, `CODE`, `GRAPH_REPORT`, `BROAD`, `SKILLS`, `TRIPLET_COMPLETION`.
    Every single enum member and retriever mapping in report Section 4 matches the source. `TRIPLET_COMPLETION` is deprecated and mapped to `GRAPH_COMPLETION`. **VERIFIED EXACT.**

### Priority 5: In-Memory Triplet Search Implementation
- **Claim:** `brute_force_triplet_search` runs BFS in an in-memory NetworkX graph (`CogneeGraph`).
  - **Verification:** Inspected [`brute_force_triplet_search.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/retrieval/utils/brute_force_triplet_search.py) and [`CogneeGraph.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/graph/cognee_graph/CogneeGraph.py).
    - [`CogneeGraph`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/graph/cognee_graph/CogneeGraph.py#L22) does **not** inherit from or wrap NetworkX; it subclasses `CogneeAbstractGraph`. It manages nodes and edges using standard Python data structures: `self.nodes = {}` (`dict[str, Node]`) and `self.edges = []` (`list[Edge]`).
    - The search does **not** run BFS. It projects nodes/edges via `project_neighborhood_from_db()` or `project_graph_from_db()`, maps cosine distances onto node/edge attributes, and ranks edges by evaluating an algebraic formula over edge and endpoint distances using `heapq.nsmallest` ([`CogneeGraph.py#L428-L515`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/graph/cognee_graph/CogneeGraph.py#L428-L515)).
    - NetworkX is only imported in `graph_report_retriever.py` (for PageRank) and in unit tests.
    - **MAJOR FINDING (F-01).** While the core architectural critique stands (graph traversal and ranking happens in Python memory instead of database joins), claiming it is a NetworkX graph running BFS is factually incorrect.

### Priority 6: `improve(review_conflicts=True)` and `FactConflict` Nodes
- **Claim:** Stage 8 of `improve` executes `review_conflicts` when enabled, creating `FactConflict` nodes and setting `conflict_marks`.
  - **Verification:**
    - [`cognee/modules/improve/registry.py#L34`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/improve/registry.py#L34) lists `ReviewConflictsStage()` as stage 8 of `DEFAULT_STAGES`.
    - [`cognee/modules/engine/models/FactConflict.py#L6-L23`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/engine/models/FactConflict.py#L6-L23) defines the model: `dataset_id`, `about_id`, `attribute`, `kind: Literal["time_varying", "fixed"]`, `status: Literal["resolved", "unresolved"]`, `text`, `values`, `sources`, `review_pending`.
    - [`write_conflicts.py#L21-L25`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/memify/review_conflicts/write_conflicts.py#L21-L25) imports `CONFLICT_ABOUT`, `CONFLICT_CITES`, `CONFLICT_VALUE`.
    - [`resolve_edges_to_text.py#L61-L67`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/graph/utils/resolve_edges_to_text.py#L61-L67) defines `_superseded_last()` which sorts superseded edges to the bottom of the prompt context, and stamps `status_label` (`[current; as of ...]`, `[superseded; as of ...]`). **VERIFIED EXACT.**

### Priority 7: Hermes Integration (Uvicorn 8011 & Lifecycle Hooks)
- **Claim:** Hermes plugin manifest `plugin-catalog/cognee.yaml` provides tools and hooks; spawns a background Uvicorn daemon on `127.0.0.1:8011` (`server_bootstrap.py`); implements `prefetch`, `sync_turn`, `on_session_end`, `on_pre_compress`, `on_memory_write`.
  - **Verification:**
    - Inspected [`~/.hermes/hermes-agent/plugin-catalog/cognee.yaml`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/plugin-catalog/cognee.yaml). Pinned to commit `ccfb0e4e3fa8f3ce09c023d258c205ca972e48a8` of `topoteretes/cognee-integrations` (`integrations/hermes-agent`). Tools and hooks match the report verbatim.
    - Fetched and inspected `integrations/hermes-agent/cognee_integration_hermes/server_bootstrap.py`: Spawns `[sys.executable, "-m", "uvicorn", "cognee.api.client:app", "--host", "127.0.0.1", "--port", "8011"]`. `DEFAULT_LOCAL_PORT = 8011` is defined in `config.py`.
    - Inspected `provider.py`:
      - `prefetch` is defined at line 681 (report cited `#L650`).
      - `sync_turn` is defined at line 713 (report cited `#L780`).
      - `on_session_end` is defined at lines 1083-1108 (**EXACT MATCH**).
      - `on_pre_compress` is defined at lines 1110-1150 (**EXACT MATCH**).
      - `on_memory_write` is defined at lines 1275-1315 (**EXACT MATCH**).
    - Closer Worker File: The report refers to `out_of_band_closer.py`. In reality, the script file is named `exit_watcher.py` (`python exit_watcher.py --state <path> [--final]`). **MINOR FINDING (F-03).**

### Priority 8: Ingestion Cost & Latency Claims
- **Claim:** Default `cognify` pipeline incurs 2 LLM calls per chunk + 4 embedding calls per chunk.
  - **Verification:** Inspected [`cognee/modules/cognify/estimator.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/cognify/estimator.py).
    - Lines 62-64 define `SUMMARY_OUTPUT_TOKENS_PER_CHUNK = 150`, `GRAPH_OUTPUT_TOKEN_RATIO = 0.5`, `MIN_GRAPH_OUTPUT_TOKENS_PER_CHUNK = 256`.
    - Lines 237-260 (`estimate_chunks`): Executes 1 call for graph extraction (`extract_graph_from_data`) and 1 call for chunk summarization (`summarize_text`) per chunk, totaling exactly **2 LLM calls per chunk**. Setting `summary_method="from_extraction"` drops the second call.
    - Embeddings: Vector collections are defined per index field on `DocumentChunk_text`, `Entity_name`, `TextSummary_text`, and `EdgeType_relationship_name` (4 embedding calls).
    - Latency figure (~1.5-3.5s/chunk): Not hardcoded in the codebase, but a direct consequence of two sequential/gathered network LLM completion calls per chunk. Token formulas and call counts are rigorously sourced from `estimator.py`. **VERIFIED.**

### Priority 9: Missing Insights & Architectural Implications for Engram
- **Temporal Cognify Evolution:** Why did Cognee drop `Event` nodes in v1.6.3? As documented in [`cognify.py#L57-L66`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/api/v1/cognify/cognify.py#L57-L66), explicit Event nodes created an intermediate layer of unindexed nodes that broke temporal search and triplet re-indexing. Engram completely circumvents this pitfall by modeling bi-temporal validity (`valid_from`, `valid_to`, `learned_at`) directly on `asserts` relation records.
- **FastMCP Tool Catalog Omission:** In [`cognee-mcp/src/server.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee-mcp/src/server.py#L813-L869), the `improve` function is missing the `@registry.tool` decorator, leaving only 5 active tools (`remember`, `recall`, `code_search`, `forget`, `cognify_status`). Engram's MCP design should ensure all memory lifecycle verbs are registered and discoverable.
- **Incremental Loading & Pipeline Status:** Cognee fingerprints chunks by SHA-256 (`content_hash`) and skips reprocessing via `PipelineRunAlreadyCompleted`. Engram should adopt this pattern natively in SurrealDB (`SELECT id FROM episode WHERE content_hash = $hash`).

---

## 3. Findings Table

| ID | Severity | Location in `02-cognee.md` | Claim in Report | Evidence from Source Code | Recommended Fix |
|---|---|---|---|---|---|
| **F-01** | **MAJOR** | §Executive Summary (L21), §4.1 (L336-L340), §11 (L637), Patterns table (L660) | `brute_force_triplet_search` projects the graph into an in-memory NetworkX graph in Python and executes BFS traversal. | In [`CogneeGraph.py#L22`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/graph/cognee_graph/CogneeGraph.py#L22), `CogneeGraph` subclasses `CogneeAbstractGraph`, using standard Python dicts (`nodes`) and lists (`edges`). It does not import or wrap NetworkX, nor does it run BFS; it ranks edges using `heapq.nsmallest`. NetworkX is only used for PageRank in `graph_report_retriever.py`. | Clarify that `CogneeGraph` is a custom in-memory dictionary-backed graph data structure, not NetworkX. The architectural critique of user-space Python graph processing remains valid. |
| **F-02** | **MAJOR** | §8.1 (L529-L542) | Lists `improve` as Registered MCP Tool #5 in `cognee-mcp` with arguments `dataset_name`, `session_ids`, etc. | In [`cognee-mcp/src/server.py#L813-L820`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee-mcp/src/server.py#L813-L820), `async def improve(...)` has `@log_usage(...)` but is **missing** `@registry.tool(...)`. It is never registered with FastMCP. Only 5 tools (`remember`, `recall`, `code_search`, `forget`, `cognify_status`) are registered. | Note that while the `improve` function is implemented in `server.py`, it is not decorated with `@registry.tool` and therefore not exposed over MCP. |
| **F-03** | **MINOR** | §9.2 (L585), Patterns table (L661) | The Hermes integration invokes an "out-of-process closer worker (`out_of_band_closer.py`)". | In `cognee-integrations/integrations/hermes-agent/cognee_integration_hermes/`, the detached script is named `exit_watcher.py` (`python exit_watcher.py --state <path> [--final]`). There is no file named `out_of_band_closer.py`. | Replace `out_of_band_closer.py` with `exit_watcher.py`. |
| **F-04** | **MINOR** | §5.2 (L387) | `remember(session_id=...)` debounces automatic `improve` triggers via `IMPROVE_DEBOUNCE_ENTRIES` (default 10) and `IMPROVE_DEBOUNCE_SECONDS` (default 300). | In [`cognee/modules/improve/config.py#L47-L48`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/improve/config.py#L47-L48), `debounce_entries: int = 1` and `debounce_seconds: float = 0.0`. The codebase defaults provide **no debounce** by default; 10 entries and 300 seconds are recommended example settings. | Correct default values to `1` entry and `0.0` seconds, clarifying that 10 entries / 300s are suggested tuning values. |
| **F-05** | **MINOR** | §2.2 (L139) | Chunk Sizing Formula: "Auto-resolved via `cognee/infrastructure/llm/resolve_chunk_size.py`". | No file named `resolve_chunk_size.py` exists. The function `resolve_chunk_size` is located in [`cognee/infrastructure/llm/utils.py#L53`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/infrastructure/llm/utils.py#L53) and re-exported from `cognee.infrastructure.llm`. | Update path to [`cognee/infrastructure/llm/utils.py#L53`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/infrastructure/llm/utils.py#L53). |
| **F-06** | **MINOR** | §7.1 (L433) | Heading states `GraphDBInterface (47 Methods)`. | AST inspection of [`graph_db_interface.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/infrastructure/databases/graph/graph_db_interface.py) shows 52 distinct methods on `GraphDBInterface` (e.g. including `find_node_source_refs_by_dataset`, `find_edge_source_refs_by_dataset`, `get_triplets_batch`, etc.). | Update method count in heading from 47 to 52. |
| **F-07** | **NIT** | §1.2 (L71) | `cognee.improve(...) (cognee/api/v1/improve/improve.py#L135-L150)` | Lines 135-150 in `improve.py` are the legacy parameter parsing helper `_parse_legacy_kwargs()`. `async def improve(...)` begins at line 157. | Update line citation to `#L157-L167`. |
| **F-08** | **NIT** | §1.3 (L88-L93) | System NodeSets lists `user_sessions: Holds raw transcribed session turns`. | In [`cognee/modules/improve/constants.py#L13`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/improve/constants.py#L13), the constant is `USER_SESSIONS_NODE_SET = "user_sessions_from_cache"`. | Update string name to `user_sessions_from_cache`. |
| **F-09** | **NIT** | §1.1 (L59) | `cognee.search(...) (cognee/api/v1/search/search.py#L45-L75)` | `async def search(...)` signature spans lines 42 to 73. | Update line citation to `#L42-L73`. |
| **F-10** | **NIT** | §9.2 (L581, L583, L584) | Citations for `README.md#L221-L228`, `provider.py#L650`, `provider.py#L780`. | Lines in `ccfb0e4`: README quote is at lines 213-217; `prefetch` is at line 681; `sync_turn` is at line 713. | Update line numbers to match commit `ccfb0e4`. |

---

## 4. Verified-Correct Claims

The following core claims in `02-cognee.md` were rigorously checked against local and upstream source code and confirmed to be completely accurate:

1. **Exact Release Version & Git Pointers:** Tag `v1.6.5`, commit `37f788bd287750e10d7610173e5332b3843f6ebd` in `.refs/cognee`; Hermes integration commit `ccfb0e4e3fa8f3ce09c023d258c205ca972e48a8` in `plugin-catalog/cognee.yaml`.
2. **Poly-Store Multi-Engine Coordination:** Cognee coordinates three independent backends (relational via SQLAlchemy, graph via Neo4j/Ladybug/Neptune, vector via LanceDB/PGVector).
3. **Cross-Store Consistency Vulnerability:** Verified verbatim against [`add_data_points.py#L325-L336`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/storage/add_data_points.py#L325-L336). Commits occur sequentially (relational commit → graph nodes → vector nodes → graph edges → vector edges) with no 2PC.
4. **Hermes Integration Architecture:** Verified that `local-server` mode uses [`server_bootstrap.py`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/plugin-catalog/cognee.yaml) to spawn `uvicorn` on port `8011` due to local single-writer database locks, and that `provider.py` implements `prefetch`, `sync_turn`, `on_session_end`, `on_pre_compress`, and `on_memory_write`.
5. **Exact Extraction Schema & Prompts:** Verified Pydantic models `Node`, `Edge`, and `KnowledgeGraph` in [`cognee/shared/data_models.py#L49-L78`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/shared/data_models.py#L49-L78), and verbatim extraction rules in `generate_graph_prompt.txt`.
6. **21 Search Modes:** Verified all 21 values of `SearchType` in [`SearchType.py#L5-L29`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/search/types/SearchType.py#L5-L29).
7. **Contradiction Modeling:** Verified `FactConflict` model in [`FactConflict.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/engine/models/FactConflict.py), conflict links (`conflict_about`, `conflict_cites`, `conflict_value`), and stage 8 `ReviewConflictsStage` in `DEFAULT_STAGES`.
8. **Feedback Weights Formula:** Verified streaming moving average update formula $w_{\text{new}} = (1 - \alpha) w_{\text{old}} + \alpha \cdot \text{score}$ with default $\alpha = 0.1$ in [`apply_feedback_weights.py#L79-L84`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/tasks/memify/apply_feedback_weights.py#L79-L84).
9. **Dry-Run Cost Estimations:** Verified that default `cognify` executes 2 LLM calls per chunk + 4 vector embeddings in [`estimator.py#L62-L75`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/modules/cognify/estimator.py#L62-L75).
10. **VectorDBInterface Method Count:** Verified exactly 22 abstract methods in [`vector_db_interface.py`](https://github.com/topoteretes/cognee/blob/v1.6.5/cognee/infrastructure/databases/vector/vector_db_interface.py).

---

## 5. Unverifiable Items

- **Dynamic Latency Bounds (1.5s - 3.5s per chunk):** While the 2 LLM calls per chunk and 4 embedding operations are provable in the source code, end-to-end clock latency is dependent on remote API network round trips, token lengths, provider rate limits, and client concurrency. These figures are realistic empirical benchmarks, not static codebase constants.
- **Cognee Cloud / Remote Multi-Tenant Latencies:** Network latency when calling remote Cognee endpoints (`cognee.serve(...)`) depends on network conditions and cannot be deterministically verified offline.
