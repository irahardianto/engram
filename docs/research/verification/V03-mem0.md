# Verification Report V03: Mem0 Architecture, Pipelines, and Lessons for Engram

**Target Document Under Review:** [`docs/research/03-mem0.md`](../03-mem0.md)  
**Verifier:** Independent Principal Engineer / Skeptical Auditor  
**Date of Verification:** October 24, 2026  
**Primary Sources Checked:**
1. Reference Repository: `mem0ai/mem0` (checked active branch at `v2.2.1` and historical tag `v1.0.11`)
2. Integration Source: `~/.hermes/hermes-agent/plugin-catalog/mem0.yaml` & `mem0ai/mem0/integrations/hermes-plugin-mem0/`
3. Official Documentation & Changelog: `docs/changelog/sdk.mdx` (PR #4805, PR #4843, PR #4836, PR #5270), `docs/platform/mem0-mcp.mdx`
4. Academic Paper: arXiv:2504.19413 (*Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory*)

---

## 1. Summary Verdict

### **Verdict: PASS-WITH-FIXES**

The research document `03-mem0.md` represents an exceptionally comprehensive, rigorous, and architecturally sophisticated analysis of the Mem0 codebase, the academic benchmark literature, and the Hermes agent memory plugin. All six highest-priority claims were confirmed through source code inspection and paper cross-checking. The mathematical formulas (sigmoid BM25, quadratic degree damping, threshold gating), pipeline phase structures, SQL schemas, and benchmark statistics were verified against primary sources with high fidelity.

However, two **MAJOR** architectural discrepancies and several minor line-citation drifts were discovered during executable verification:
1. **MAJOR (Dead Code & Discarded LLM Extractions in OSS v2):** While `03-mem0.md` correctly notes that `ADDITIVE_EXTRACTION_PROMPT` extracts `linked_memory_ids` and that `uuid_mapping` was conceived for anti-hallucination mapping, source verification reveals that the OSS v2.x ingestion engine (`mem0/memory/main.py:1017-1041`) **completely discards the LLM's `linked_memory_ids` output during vector store persistence**. Furthermore, `uuid_mapping` at `main.py:937-941` is **dead code** (never read or mapped back).
2. **MAJOR (`Memory.search()` Return Type Inconsistency):** Section 5 and Section 5.5 claim `search()` returns a dictionary `{"results": [...]}`. In the core OSS v2.x SDK (`mem0/memory/main.py:1745`), `Memory.search()` directly returns a flat Python `List[Dict[str, Any]]` (`original_memories`), not a dictionary wrapper.
3. **MINOR Citations & Omissions:** Inverted line numbers in v1.0.11 graph tools, shifted line numbers for `reset()` in `main.py`, and omission of Mem0's asynchronous Memory Export feature (`create_memory_export`).

The document is sound to serve as the foundational specification for Engram once these corrections are applied.

---

## 2. Findings Table

| ID | Severity | Location in `03-mem0.md` | Claim / Assertion | Evidence from Primary Sources | Recommended Fix |
|---|---|---|---|---|---|
| **FIND-01** | **MAJOR** | §2.2 (lines 160, 180-190) & §12 (lines 711-712) | Single-pass additive extraction connects newly added facts to existing memories via `linked_memory_ids`, and `uuid_mapping` resolves integer IDs back to UUIDs. | In [`mem0/memory/main.py:937-941`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L937-L941), `uuid_mapping` is populated but **never accessed again** anywhere in `main.py`. In Phase 6 vector insertion ([`main.py:1017-1041`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L1017-L1041)), only `text` and `attributed_to` are read from the LLM's output; `mem.get("linked_memory_ids")` is **completely ignored and dropped**. In OSS v2, cross-memory links exist *only* inside `{collection}_entities` constructed by spaCy, not in memory payloads. In v1, mapping back used `temp_uuid_mapping` ([`v1.0.11:main.py:585, 646`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L585)), which was deleted in v2. | Document in §2.2 and §12 that while the LLM prompt asks for `linked_memory_ids`, the OSS SDK silently discards this field and `uuid_mapping` is leftover dead code. Warn Engram developers not to emulate this broken pattern. |
| **FIND-02** | **MAJOR** | §5 (line 363) & §5.5 (lines 406-438) | `Memory.search()` returns a dictionary envelope: `{"results": [...]}`. | In [`mem0/memory/main.py:1745`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L1745), `Memory.search()` returns a flat list: `return original_memories`. The dictionary envelope `{"results": ...}` existed in v1 ([`v1.0.11:main.py:965`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L965)) and is used by the FastAPI REST server and Platform client, but NOT by the core OSS `Memory.search()` method. | Update the diagram in §5 and the return signature in §5.5 to show `search() -> List[Dict[str, Any]]`. |
| **FIND-03** | **MINOR** | §4.1 (lines 279-281) | `EXTRACT_ENTITIES_STRUCT_TOOL` cited at `mem0/graphs/tools.py:166-194`; `RELATIONS_STRUCT_TOOL` cited at `mem0/graphs/tools.py:133-164`. | In `v1.0.11:mem0/graphs/tools.py`, `RELATIONS_STRUCT_TOOL` is at lines 238–278; `EXTRACT_ENTITIES_STRUCT_TOOL` is at lines 281–308. Lines 130–200 contain `UPDATE_MEMORY_STRUCT_TOOL_GRAPH` and `ADD_MEMORY_STRUCT_TOOL_GRAPH`. | Update line citations in §4.1 and Summary Citations to point to `mem0/graphs/tools.py:238-308`. |
| **FIND-04** | **MINOR** | §5.6 (line 445) | `reset()` cited at `mem0/memory/main.py:2310-2345`. | In [`mem0/memory/main.py:2310-2345`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L2310-L2345), the code is `AsyncMemory._upsert_entity_async` and `_bulk_clear_entity_store`. `Memory.reset()` is defined at line 2144 (`lines 2144-2172`), and `AsyncMemory.reset()` is at line 3865 (`lines 3865-3894`). | Correct citation to [`mem0/memory/main.py:2144-2172`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L2144-L2172). |
| **FIND-05** | **MINOR** | §1.1 (line 23) | `app_id` cited at `mem0/client/main.py:85-115`. | In [`mem0/client/main.py:41`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/client/main.py#L41), `ENTITY_PARAMS = frozenset({"user_id", "agent_id", "app_id", "run_id"})`. Lines 85–115 contain `_reject_blank_entity_ids` and query trimming utilities. | Update citation in §1.1 to [`mem0/client/main.py:41`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/client/main.py#L41). |
| **FIND-06** | **MINOR** | §1.2 & Missing Features | Section 1.2 snippet shows `MemoryType` with only `PROCEDURAL`; report omits Memory Export feature. | [`mem0/configs/enums.py:4-8`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/configs/enums.py#L4-L8) defines `SEMANTIC`, `EPISODIC`, and `PROCEDURAL`. Furthermore, [`mem0/client/main.py:769-825`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/client/main.py#L769-L825) implements structured JSON-schema-based memory export (`create_memory_export`, `get_memory_export`). | Restore the full `MemoryType` enum definition in §1.2 and add a brief subsection on Mem0's asynchronous Memory Export capabilities. |
| **FIND-07** | **NIT** | §6.2 (line 507) | "Mem0 implements 30 vector backends". | [`mem0/utils/factory.py:181-207`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/utils/factory.py#L181-L207) registers exactly 26 vector backends in `VectorStoreFactory.provider_to_class`, and there are 25 adapter files in `mem0/vector_stores/`. | Change "30 vector backends" to "26 vector backends". |

---

## 3. High-Priority Claims: Confirmed or Refuted with Evidence

### Claim 1: Mem0 v2.0.0 (April 2026, PR #4805) Additive Pipeline (`ADDITIVE_EXTRACTION_PROMPT`)
- **Status:** **CONFIRMED (with nuance regarding discarded outputs)**
- **Evidence:**
  - `docs/changelog/sdk.mdx:373-378`: Label `2026-04-14` (v2.0.0) documents: *"Single-Pass Extraction: Replaced 2-LLM-call pipeline with additive extraction using `ADDITIVE_EXTRACTION_PROMPT`. Memories accumulate via `linked_memory_ids`: no more UPDATE/DELETE events ([#4805])"*.
  - Prompt Definition: [`mem0/configs/prompts.py:468-944`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/configs/prompts.py#L468-L944) contains the exact system prompt `ADDITIVE_EXTRACTION_PROMPT`. Key instructions quoted in R3 (lines 472, 535, 608–615, 634–636) match verbatim:
    - Line 472: *"Your sole operation is ADD: identify every piece of memorable information and produce self-contained, contextually rich factual statements."*
    - Line 535: *"CRITICAL: 'User went to Paris last week' is useless 6 months later. 'User went to Paris the week of May 15, 2023' is meaningful forever."*
    - Line 608: *"Contextually Rich, Not Atomic: Capture the full picture — fact AND surrounding context — in a single unified memory, not scattered fragments."*
  - Pipeline Phases in [`mem0/memory/main.py:918-1220`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L918-L1220):
    - **Phase 0 (Context Gathering):** Line 920: `session_scope = _build_session_scope(filters)`, `self.db.get_last_messages(session_scope, limit=10)`.
    - **Phase 1 (Existing Memory Retrieval):** Line 925: `query_embedding = self.embedding_model.embed(parsed_messages, "search")`, `self.vector_store.search(..., top_k=10)`.
    - **Phase 2 (LLM Extraction):** Line 942: Single call with `system_prompt = ADDITIVE_EXTRACTION_PROMPT`.
    - **Phase 3 (Batch Embed):** Line 993: `self.embedding_model.embed_batch(mem_texts, "add")`.
    - **Phase 4 & 5 (CPU Lemmatization & MD5 Dedup):** Lines 1007–1026: `hashlib.md5(text.encode()).hexdigest()` matched against `existing_hashes` and `seen_hashes`; `lemmatize_for_bm25(text)`.
    - **Phase 6 (Batch Persist):** Line 1047: `self.vector_store.insert()` and `self.db.batch_add_history()`.
    - **Phase 7 (Batch Entity Linking):** Line 1100: `extract_entities_batch()`, single batch embed, `entity_store.search_batch()`, update (`score >= 0.95`) or insert into entity collection.
    - **Phase 8 (Audit & Return):** Line 1206: `self.db.save_messages(messages, session_scope)`, return ADD-only events.
  - **Critical Nuance Discovered (FIND-01):** Although the prompt instructs the LLM to output `linked_memory_ids`, lines 1017–1041 of `main.py` never save or inspect `m.get("linked_memory_ids")`. In the OSS codebase, memories never point to each other; links are only maintained in the separate entity store.

### Claim 2: Deletion of External Graph Store and Replacement by spaCy NER Entity Linking
- **Status:** **CONFIRMED**
- **Evidence:**
  - Release notes in `docs/changelog/sdk.mdx:398`: *"External Graph Store Removed (OSS): `mem0/memory/graph_memory.py`, `memgraph_memory.py`, `kuzu_memory.py`, `apache_age_memory.py`, and `mem0/graphs/` (Neo4j / Memgraph / Kuzu / Apache AGE / Neptune drivers) deleted, about 4,000 lines... Graph memory now runs natively as built-in entity linking. Remove `enable_graph` and `graph_store` from your config ([#4805])"*.
  - Git verification: In `v1.0.11`, `mem0/graphs/` and `mem0/memory/graph_memory.py` existed (`git ls-tree -r v1.0.11`). In HEAD (`v2.2.1`), these files and directories are completely absent.
  - Entity store implementation: In [`mem0/memory/main.py:422-424`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L422-L424), `_entity_collection_name()` constructs `{collection_name}_entities` (or `-entities` for s3_vectors).
  - Extraction implementation: [`mem0/utils/entity_extraction.py:761`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/utils/entity_extraction.py#L761) uses spaCy `nlp.pipe()` in `extract_entities_batch()` for high-throughput batch extraction of PROPER, QUOTED, and noun compounds.

### Claim 3: Hybrid Scoring Formula, Sigmoid BM25, and Degree Damping
- **Status:** **CONFIRMED (Exact Mathematical Match)**
- **Evidence:**
  - Additive Fusion Formula & Max Possible Divisor in [`mem0/utils/scoring.py:60-140`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/utils/scoring.py#L60-L140):
    - `max_possible = 1.0` (base).
    - If `has_bm25`: `max_possible += 1.0`.
    - If `has_entity`: `max_possible += ENTITY_BOOST_WEIGHT` (where `ENTITY_BOOST_WEIGHT = 0.5`).
    - Raw combined: `raw_combined = semantic_score + bm25_score + entity_boost`.
    - Final combined: `combined = min(raw_combined / max_possible, 1.0)`.
  - Semantic Gate: Lines 111–112 of `scoring.py`: `if semantic_score < threshold: continue` (default `threshold = 0.1` in `main.py:1399`). Candidates failing this gate are dropped before any BM25 or entity boost is added.
  - BM25 Sigmoid Normalization in [`mem0/utils/scoring.py:16-54`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/utils/scoring.py#L16-L54):
    - Normalization formula: `1.0 / (1.0 + math.exp(-steepness * (raw_score - midpoint)))`.
    - Query length parameter table matches R3 §5.2 table identically:
      - $\le 3$ terms: midpoint 5.0, steepness 0.7
      - $4 - 6$ terms: midpoint 7.0, steepness 0.6
      - $7 - 9$ terms: midpoint 9.0, steepness 0.5
      - $10 - 15$ terms: midpoint 10.0, steepness 0.5
      - $> 15$ terms: midpoint 12.0, steepness 0.5
  - Entity Boost with Degree Damping in [`mem0/memory/main.py:1805-1823`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L1805-L1823):
    - Gated by similarity: `if similarity < 0.5: continue`.
    - Frequency damping: `num_linked = max(len(linked_memory_ids), 1)`.
    - Weight: `memory_count_weight = 1.0 / (1.0 + 0.001 * ((num_linked - 1) ** 2))`.
    - Boost: `boost = similarity * ENTITY_BOOST_WEIGHT * memory_count_weight`.
    - This is identical to:
      $$\text{Entity Boost} = \text{Similarity} \times 0.5 \times \frac{1}{1.0 + 0.001 \times (N - 1)^2}$$

### Claim 4: LoCoMo Benchmark Numbers & Methodological Controversies (arXiv:2504.19413)
- **Status:** **CONFIRMED (Exact Match to Published Paper Tables)**
- **Evidence:**
  - Evaluated against full paper text downloaded from arXiv:
    - Multi-Hop LLM-as-a-Judge (J) score (Section 4.1): Base Mem0 achieved **51.15%** ($F1 = 28.64$), whereas graph-augmented Mem0g scored **48.72%** (Table 1 & Section 4.1 paragraph 2). The paper explicitly notes: *"Interestingly, the addition of graph memory in Mem0g does not provide performance gains here, indicating potential inefficiencies or redundancies in structured graph representations for complex integrative tasks compared to dense natural language memory alone."*
    - Latency (Section 4.4, Table 2 & paragraph 2): Mem0 achieved total median latency of 0.708s and p95 of **1.440s** vs Full-Context p50 of 9.870s and p95 of **17.117s (~17.12s)** (a 91.6% / 92% reduction).
    - Accuracy comparison: Full-Context baseline attained **73.20%** Overall J score vs Mem0's **67.00%** and Mem0g's **68.44%** (Section 4.3).
    - Single-hop: Mem0 **67.13%**, Mem0g 65.58%, Full-Context 66.80%, Zep 58.90%, LangMem 59.10%, A-Mem 41.20%.
    - Temporal: Mem0g **58.13%**, Mem0 55.51%, Full-Context 52.40%, Zep 54.20%, LangMem 49.10%, OpenAI < 15%.
    - Open-Domain: Zep **76.60%**, Mem0g 75.71%, Mem0 72.93%, Full-Context 71.50%.
    - Tokens: Mem0 ~**7k tokens**, Mem0g ~**14k tokens**, Full Context ~**26k tokens**, Zep **>600k tokens** (due to whole-summary duplication across nodes).
    - Exclusion of adversarial queries: Confirmed in Section 3.1: *"The dataset originally included an adversarial question category... However, this category was excluded from our evaluation because ground truth answers were unavailable..."*

### Claim 5: Hermes mem0 Plugin Facts
- **Status:** **CONFIRMED**
- **Evidence:**
  - Source location: [`integrations/hermes-plugin-mem0/__init__.py`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/integrations/hermes-plugin-mem0/__init__.py) referenced by [`~/.hermes/hermes-agent/plugin-catalog/mem0.yaml`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/plugin-catalog/mem0.yaml).
  - Truncation limit: Line 43: `_SYNC_MSG_MAX_CHARS = 450`.
  - Truncation rationale comment (lines 36–42): Explicitly documents that embedding models with small context windows (e.g., `bge-small-zh-v1.5` at 512 tokens ≈ 500 chars) cause Ollama to return HTTP 500 and hosted APIs to fail with `INPUT_TOKEN_LIMIT_EXCEEDED`. Because `_try()` only logs warnings, turns over 450 characters were silently dropped from memory extraction.
  - Sentence boundary trimming: Lines 53–68 implement `_truncate_for_sync()` using `_SYNC_SENTENCE_ENDS = ("。", "！", "？", ".", "!", "?")`.
  - Circuit Breaker: Line 30: `_BREAKER_THRESHOLD, _BREAKER_COOLDOWN_SECS, _PREFETCH_WAIT_SECS = 5, 120, 3`. Trips after 5 consecutive failures, cooling down for 120 seconds.
  - Blocking Hot-Path Wait: Lines 294–304: `prefetch()` joins the background worker thread up to `_PREFETCH_WAIT_SECS = 3` seconds (`thread.join(timeout=_PREFETCH_WAIT_SECS)`), violating Hermes's recommendation for instantaneous prefetch return.

### Claim 6: History SQLite Schema and UUID-to-Integer ID Mapping
- **Status:** **CONFIRMED (with historical separation)**
- **Evidence:**
  - SQLite Schema in [`mem0/memory/storage.py:108-142`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/storage.py#L108-L142):
    - `history` table: `id TEXT PRIMARY KEY, memory_id TEXT, old_memory TEXT, new_memory TEXT, event TEXT, created_at DATETIME, updated_at DATETIME, is_deleted INTEGER, actor_id TEXT, role TEXT`.
    - `messages` table: `id TEXT PRIMARY KEY, session_scope TEXT, role TEXT, content TEXT, name TEXT, created_at DATETIME`.
    - Rolling 10-message eviction: Lines 284–291 use the exact derived table query cited in R3 §3.2.
  - UUID-to-Integer ID Mapping:
    - In v1 ([`v1.0.11:mem0/memory/main.py:585-588, 646`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L585)): `temp_uuid_mapping = {}` mapped candidate UUIDs to string indices (`str(idx)`) for LLM Call 2 (`get_update_memory_messages`), and mapped back via `temp_uuid_mapping[resp.get("id")]` to apply `_update_memory` and `_delete_memory`.
    - In v2 ([`v2.2.1:mem0/memory/main.py:937-941`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L937-L941)): The code defines `uuid_mapping = {}`, but because LLM Call 2 was deleted, `uuid_mapping` is never looked up. It is dead code.

---

## 4. Assessment of "Patterns for Engram"

The architectural recommendations in Section 12 of `03-mem0.md` provide clear, high-value technical direction for Engram. Here is an independent assessment of each row:

1. **Fact Extraction Prompt (ADOPT):**
   - *R3 Assessment:* Adopt Mem0's guidelines for capturing transitions ("switched from X to Y"), grounding relative timestamps to an absolute observation date, and retaining proper nouns.
   - *Verifier Evaluation:* **Sound and Strongly Endorsed.** Mem0's prompt rules prevent catastrophic context loss where state changes become disconnected facts. Engram's Rust prompts should incorporate these exact rules.

2. **UUID Anti-Hallucination Mapping (ADOPT with Fix):**
   - *R3 Assessment:* Map candidate UUIDs to integer handles before prompting LLMs.
   - *Verifier Evaluation:* **Sound Principle, but Mem0's Implementation is Broken.** In Mem0 v2, `uuid_mapping` is dead code and the LLM's returned links are dropped (FIND-01). Engram should adopt the principle (mapping SurrealDB `Thing` Record IDs to short indices `0, 1, 2` to conserve prompt tokens and prevent hallucination of 26-character ULIDs), but ensure the Rust pipeline actually persists the resolved graph edges.

3. **Single-Pass Additive Ingestion (ADAPT):**
   - *R3 Assessment:* Use single-pass extraction, but extract subject-predicate-object triples + temporal validity into SurrealDB graph edges instead of flat text.
   - *Verifier Evaluation:* **Sound.** Eliminates the 2x latency penalty of Mem0 v1 while avoiding Mem0 v2's failure to maintain structured relations.

4. **Truth Maintenance & Contradiction (REJECT BOTH / ADAPT ENGRAM MODEL):**
   - *R3 Assessment:* Reject v1 destructive overwrite/delete and reject v2 unconstrained pile-up. Close outdated edges with `valid_to = time::now()` and mark contested claims with `contradiction_of`.
   - *Verifier Evaluation:* **Sound.** Provides bi-temporal auditing ($t_v$ vs $t_s$) without data loss or unresolved contradiction accumulation.

5. **Graph Modeling (REJECT MEM0's REMOVAL / SINGLE-ENGINE ADAPTATION):**
   - *R3 Assessment:* Mem0 dropped graph databases because running Neo4j/Memgraph alongside Qdrant created poly-store maintenance hell and multi-hop noise. SurrealDB unifies graph and vector natively.
   - *Verifier Evaluation:* **Sound.** SurrealDB executes graph traversals (`RELATE`) and vector cosine search within the exact same database engine in single ACID transactions.

6. **Score Fusion (ADAPT to RRF):**
   - *R3 Assessment:* Reject Mem0's additive normalizer in favor of Reciprocal Rank Fusion (RRF).
   - *Verifier Evaluation:* **Strongly Endorsed.** Mem0's additive normalization requires manually adjusting divisors ($1.0 \to 2.0 \to 2.5$) and sigmoid constants that drift across domains. RRF is scale-invariant and robust.

7. **Entity Boost Degree Damping (ADAPT):**
   - *R3 Assessment:* Use $1 / (1 + 0.001 \cdot (N-1)^2)$ to damp high-degree hub entities during traversal.
   - *Verifier Evaluation:* **Sound.** Prevents graph fan-out explosion on common concepts (e.g. "User", "work", "agent").

8. **Prefetch & Concurrency (ADAPT):**
   - *R3 Assessment:* Replace Mem0's 3-second thread block with non-blocking cache-then-serve.
   - *Verifier Evaluation:* **Sound.** Hermes hot path must never stall turn execution on external HTTP calls.

---

## 5. Verified-Correct Claims (Comprehensive Audit)

| Section in R3 | Subject | Verified Primary Source Code & Artifacts |
|---|---|---|
| **§1.1** | Tenant Scoping | [`mem0/memory/main.py:135-141`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L135-L141): `ENTITY_PARAMS`, `_IDENTITY_KEYS`, `_strip_identity_keys`. |
| **§1.1** | Top-Level Parameter Rejection | [`mem0/memory/main.py:165-173, 1449-1475`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L165-L173): `_reject_top_level_entity_params()` enforces `filters` dict. |
| **§1.2** | Procedural Memory Prompt & Deprecation | [`mem0/memory/main.py:853-864`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L853-L864) (TODO deprecation notice); [`mem0/configs/prompts.py:326-403`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/configs/prompts.py#L326-L403). |
| **§1.3** | `infer=False` Raw Ingestion | [`mem0/memory/main.py:882-916`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L882-L916): embeds text directly without LLM call. |
| **§1.4** | Metadata Filter Operators DSL | [`mem0/memory/main.py:1416-1431, 1538-1636`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L1416-L1431): `eq`, `ne`, `in`, `nin`, `gt`, `gte`, `lt`, `lte`, `contains`, `icontains`, `*`, `AND`, `OR`, `NOT`. |
| **§2.1** | Classic v1 Prompt & Schema | [`mem0/configs/prompts.py:15-121`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/configs/prompts.py#L15-L121) (`FACT_RETRIEVAL_PROMPT`, `USER_MEMORY_EXTRACTION_PROMPT`); [`prompts.py:176-324`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/configs/prompts.py#L176-L324) (`DEFAULT_UPDATE_MEMORY_PROMPT`). |
| **§2.3** | Async Ingestion Parity | [`mem0/memory/main.py:2455-2880`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/main.py#L2455-L2880): `AsyncMemory` replicates the 8 phases with `asyncio.to_thread`. |
| **§3.1–3.3** | SQLite Tables & Sliding Window | [`mem0/memory/storage.py:108-142, 229-238, 279-291`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/storage.py#L108-L142): `history`, `messages`, and derived table eviction subquery. |
| **§4.2–4.4** | Mem0g Cypher Queries in v1.0.11 | `v1.0.11:mem0/memory/graph_memory.py:310-317` (threshold `0.7`); `lines 423-433` (soft delete `r.invalidated_at = datetime()`). |
| **§4.4** | v1 Graph / Vector Unfused Return | `v1.0.11:mem0/memory/main.py:962-965`: `return {"results": original_memories, "relations": graph_entities}`. |
| **§5.2** | Sigmoid BM25 Normalization | [`mem0/utils/scoring.py:16-54`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/utils/scoring.py#L16-L54): midpoints 5.0, 7.0, 9.0, 10.0, 12.0; steepnesses 0.7, 0.6, 0.5. |
| **§5.4** | Supported Rerankers | [`mem0/reranker/`](https://github.com/mem0ai/mem0/tree/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/reranker/): `cohere`, `huggingface`, `sentence_transformer`, `llm`, `zero_entropy`. |
| **§6.2** | `VectorStoreBase` Interface | [`mem0/vector_stores/base.py:1-101`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/vector_stores/base.py#L1-L101): abstract methods and extension defaults. |
| **§7.1–7.2** | REST Endpoints & Compose | [`server/main.py:146-561`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/server/main.py#L146-L561); [`server/docker-compose.yaml:1-77`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/server/docker-compose.yaml#L1-L77) (FastAPI, pgvector pg17, Next.js). |
| **§7.3** | MCP Tool Declarations | [`docs/platform/mem0-mcp.mdx:62-79`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/docs/platform/mem0-mcp.mdx#L62-L79); [`integrations/agent-plugin-core/python/mcp_server.py:22-68`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/integrations/agent-plugin-core/python/mcp_server.py#L22-L68). |
| **§8.1–8.3** | Hermes Plugin Internals | [`integrations/hermes-plugin-mem0/__init__.py:30, 43, 263, 294-327`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/integrations/hermes-plugin-mem0/__init__.py#L30): circuit breaker, 450-char truncation, prefetch join. |
| **§9.1–9.2** | Telemetry & Upsell Prompts | [`mem0/memory/telemetry.py:14-16, 32, 58-74`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/telemetry.py#L14-L16); [`mem0/memory/notices.py:127`](https://github.com/mem0ai/mem0/blob/2c81af3bbe27d9bccb09c772d583df9e9be72ee5/mem0/memory/notices.py#L127) (`PERFORMANCE_SLOW_QUERY_THRESHOLD_SECONDS = 2.0`). |
| **§10.1–10.2** | LoCoMo Benchmark Metrics | arXiv:2504.19413 Sections 3.1, 4.1–4.5, Tables 1 & 2: 51.15% vs 48.72%, 1.44s vs 17.12s, 67.0% vs 73.2%, token counts. |

---

## 6. Unverifiable Items

1. **Mem0 Hosted Platform Backend Internals:**
   - The private server-side code behind `api.mem0.ai` (Platform mode) is closed-source. Features such as Platform graph traversal, automatic recency decay scoring, and server-side `delete_linked` handling cannot be inspected directly from the OSS repo.
2. **Proprietary Benchmark Reproducibility:**
   - The paper arXiv:2504.19413 evaluates commercial systems (OpenAI Memory Playground, Zep Platform). Exact reproduction requires proprietary API accounts, proprietary judge models, and the exact timestamp configurations used during the authors' April 2025 benchmark runs.

---

## 7. Conclusion & Next Steps for Engram

The report `03-mem0.md` accurately analyzes Mem0's strengths, weaknesses, and operational lessons. The findings identified above (FIND-01 through FIND-07) do not invalidate the conclusions drawn for Engram; rather, **they reinforce them**. 

Specifically, discovering that Mem0 OSS v2 silently discards `linked_memory_ids` and leaves `uuid_mapping` as dead code confirms that Mem0 abandoned true graph relationships in open-source in favor of a commercial Platform upsell. This validates Engram's core architectural thesis: **a single, coherent Rust service backed by SurrealDB that natively integrates bi-temporal graph edges, dense vectors, and full ACID consistency**.

The author of `03-mem0.md` should apply the recommended fixes in FIND-01 through FIND-07 to complete the documentation.
