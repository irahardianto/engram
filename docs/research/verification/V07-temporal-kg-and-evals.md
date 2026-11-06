# Verification Report: Temporal Knowledge Graphs, SurrealDB Agent Memory, Evaluations, and Cognitive Patterns (V07)

**Target Under Review:** [`docs/research/07-temporal-kg-and-evals.md`](../07-temporal-kg-and-evals.md) (ENGRAM-RES-007)  
**Context Source:** [`DISCOVERY_HANDOFF.md`](../../../DISCOVERY_HANDOFF.md)  
**Verifier:** Independent Skeptical Principal Engineer Verifier  
**Verification Date:** October 2026  
**Environment:** Linux (x86_64), Python 3.12, SurrealDB 3.x, Docker 29.9.1  

---

## 1. Summary Verdict

**Verdict: PASS-WITH-FIXES**

### High-Level Evaluation
Research Report R7 is an exceptionally thorough, high-fidelity architectural study. It delivers deep, forensic analysis across Graphiti’s temporal knowledge graph mechanics, SurrealDB’s native agent memory specifications, the contemporary agent memory evaluation landscape (including BEAM, LongMemEval, and LoCoMo), and adjacent cognitive patterns (A-MEM, MemGPT/Letta, reflection, Ebbinghaus decay, MMR).

Every critical algorithm and prompt cited from Graphiti was verified against the official source code repository (`github.com/getzep/graphiti`):
- The bi-temporal model (`valid_at`/`invalid_at` vs. `created_at`/`expired_at`) and reference time handling are verified line-for-line in `graphiti_core/edges.py`.
- The edge invalidation and contradiction logic at `edge_operations.py#L720-L785` and `prompts/dedupe_edges.py` is authentic, not hallucinated.
- The 4-tier entity resolution pipeline—including the exact MinHash/LSH constants (32 permutations, 3-gram character shingles, band size 4, Jaccard threshold $\ge 0.9$, and character entropy gate $\ge 1.5$) in `dedup_helpers.py`—was proven to exist verbatim in Graphiti.
- SurrealDB’s Agent Memory architecture—including the three-clock temporal model (`SurrealDB VERSION`, `as_of`, `valid_from`/`valid_until`), the three typed primitives (Attribute, Relation, Action), the six experiential categories (Episodic, Identity, Knowledge, Context, Instructions, Uncertainty), and the 4-tier router over 7 fused signals—was confirmed directly against live official documentation pages on `surrealdb.com`.
- The BEAM benchmark paper (*"Beyond a Million Tokens: Benchmarking and Enhancing Long-Term Memory in LLMs"*, Tavakoli et al., arXiv:2510.27246) is a real published academic paper with 100 conversations and 2,000 questions across 128k, 500k, 1M, and 10M token splits.
- The published benchmark scores and the benchmark controversy analysis (lenient vs. strict grading inflation of +15% to 28%, top-200 context stuffing vs. top-5 retrieval) were verified against primary sources including SurrealDB's benchmark audit (`benchmarks.md`) and Hindsight's official technical publications.

However, forensic verification against primary academic registries, official web endpoints, and source code identified **two MAJOR findings** and **several MINOR precision defects**:
1. **Hallucinated arXiv ID and Authors for MemoryAgentBench (MAJOR):** R7 cites MemoryAgentBench as *"Zhang, Y., et al. (2024). Evaluating Memory in LLM Agents via Incremental Multi-Turn Interactions. ICLR 2025. arXiv:2410.21000"*. Querying the arXiv API confirms that **arXiv:2410.21000 is an unrelated medical vision paper** (*"Efficient Bilinear Attention-based Fusion for Medical Visual Question Answering"*). The real paper is **arXiv:2507.05257** by Yuanzhe Hu, Yu Wang, Julian McAuley et al. (UCSD), and its 4th core pillar is *Selective Forgetting*, not *Conflict Resolution*.
2. **SurrealDB Agent Memory Vector Index Inaccuracy (MTREE vs. HNSW) (MAJOR):** In §B (line 322), the architecture diagram labels SurrealDB's vector engine as `"MTREE Index"`. Live SurrealDB Agent Memory documentation (`surrealdb.com/agent-memory/recall.md` line 62) explicitly specifies **`HNSW · COSINE`**. MTREE is absent from the Agent Memory specification. (This appears to have been carried over from an initial draft schema in `DISCOVERY_HANDOFF.md#L221`).
3. **Zep LongMemEval Score Discrepancy (MINOR):** Table C.2 states Zep scored **71.4%** on LongMemEval. In the cited Zep paper (arXiv:2501.13956, Table 2), the actual reported score is **71.2%** (GPT-4o, 2.58s latency vs. 60.2% full-context baseline).
4. **LoCoMo Dataset Scale Imprecision (MINOR):** §C.1 states LoCoMo has "35 long dialogue sessions, ~1,540 QA pairs". In reality, the benchmark features conversations each spanning *up to 35 sessions* (totaling ~300+ turns and ~9k–16k tokens per conversation), with ~1,540–1,986 QA pairs in the evaluation subset.
5. **LongMemEval Taxonomy Clarification (MINOR):** R7 conflates the 5 core abilities (Extraction, Multi-Session, Temporal, Updates, Abstention) with question types. The LongMemEval dataset formally defines **7 concrete question types** (`single-session-user`, `single-session-assistant`, `single-session-preference`, `multi-session`, `knowledge-update`, `temporal-reasoning`, `abstention`).
6. **Ingestion Cost Characterization (MINOR):** Graphiti's 4–12+ LLM call count per turn is verified from the code path, but the dollar cost ($0.02–$0.15) and wall-clock latency (3–8s) are analytical estimates rather than empirical benchmarks published in arXiv:2501.13956.

With these corrections applied, Report R7 provides an outstanding, verified foundation for Engram's PRD and implementation.

---

## 2. Findings Table

| ID | Severity | Location | Claim in R7 | Evidence & Executable Proof | Recommended Fix |
|---|---|---|---|---|---|
| **F-01** | **MAJOR** | §Executive Summary (line 16), §C.1 (line 432), References (line 655) | MemoryAgentBench: `arXiv:2410.21000 (ICLR 2025)`, authored by `Zhang, Y., et al. (2024)`, with categories including `Conflict Resolution (CR)`. | Queried the arXiv API for `2410.21000`: returned title is *"Efficient Bilinear Attention-based Fusion for Medical Visual Question Answering"*. The real paper is **arXiv:2507.05257**: *"Evaluating Memory in LLM Agents via Incremental Multi-Turn Interactions"* by Yuanzhe Hu, Yu Wang, Julian McAuley et al. The 4 competencies in the paper are: (1) Accurate Retrieval, (2) Test-Time Learning, (3) Long-Range Understanding, and (4) **Selective Forgetting** (not "Conflict Resolution"). | Correct citation to: Hu, Y., Wang, Y., & McAuley, J. (2025). *Evaluating Memory in LLM Agents via Incremental Multi-Turn Interactions.* arXiv preprint arXiv:2507.05257. Update category 4 to Selective Forgetting. |
| **F-02** | **MAJOR** | §B (Architecture Diagram, line 322) | SurrealDB 3.x Engine Vector Substrate labeled as `"MTREE Index"`. | Fetched and scanned official SurrealDB Agent Memory specification (`https://surrealdb.com/agent-memory/recall.md` line 62). The specification explicitly mandates: `Vector search: passages, turns, audio, images | HNSW · COSINE`. The term `MTREE` does not appear anywhere in SurrealDB Agent Memory docs. MTREE was an older SurrealDB 1.x index type and was mistakenly imported from an initial draft in `DISCOVERY_HANDOFF.md#L221`. | Replace `MTREE Index` with `HNSW Index (COSINE)` in the diagram and text to align with SurrealDB 3.x Agent Memory specs. |
| **F-03** | **MINOR** | §C.2 (Table line 446) | Zep (Graphiti) LongMemEval Headline Score is **`71.4%`**. | Inspected arXiv:2501.13956, Section 4.3.2, Table 2 ("LongMemEvals"). The official score for `Zep + gpt-4o` is **`71.2%`** (latency 2.58s vs 28.9s baseline, full-context baseline 60.2%). Relative improvement is +18.27% (~18.5%). | Update headline score from `71.4%` to `71.2%` to match the exact published paper table. |
| **F-04** | **MINOR** | §C.1 (Table line 430) | LoCoMo Dataset Scale: `"35 long dialogue sessions, ~1,540 QA pairs"`. | Primary paper arXiv:2402.17753 and dataset release (`snap-research/locomo`) show conversations contain *up to 35 sessions each* across 10–35 long conversations (averaging 300+ turns and 9k–16k tokens per conversation). Total QA pairs in the evaluation subset range from 1,540 to 1,986. Stating "35 long dialogue sessions" implies the whole dataset is 35 sessions total. | Clarify text: "10–35 multi-session conversations (each spanning up to 35 sessions, ~300 turns), with ~1,540 QA pairs in the evaluation subset." |
| **F-05** | **MINOR** | §C.1 (line 429), §C.4 (line 485) | LongMemEval taxonomy described as "5 categories". | Primary paper arXiv:2410.10813 defines **5 core abilities** (Information Extraction, Multi-Session Reasoning, Temporal Reasoning, Knowledge Updates, Abstention), but the dataset schema is structured into **7 question types**: `single-session-user`, `single-session-assistant`, `single-session-preference`, `multi-session`, `knowledge-update`, `temporal-reasoning`, and `abstention`. | Clarify distinction: 5 cognitive abilities evaluated via 7 concrete question types. |
| **F-06** | **MINOR** | §A.9 (lines 284–285) | Ingestion cost: `"results in high operational token costs ($0.02 to $0.15 per turn on commercial APIs) and latency of 3,000–8,000 ms"`. | Tracing `add_episode` in `graphiti.py` verifies 4–12+ LLM calls per turn. However, the dollar cost range ($0.02–$0.15) and ingestion latency (3–8s) are analytical estimates based on standard token pricing and sequential/parallel API latency. The Zep paper (arXiv:2501.13956) only published *retrieval* latency (2.58s–3.20s), not ingestion turn costs. | Explicitly qualify the sentence: "Based on 4–12 LLM calls per turn and typical commercial API token rates, estimated operational cost is $0.02–$0.15/turn with 3,000–8,000 ms ingestion latency." |
| **F-07** | **NIT** | §C.2 (Table lines 447–449) | Sources for competitor baselines: `"Mem0 LoCoMo Report"`, `"Letta Benchmarks"`, `"Cognee Eval Repo"`. | The scores (Mem0 66.8%, Letta 58.3%, Cognee 64.2%) reflect specific historical or subset runs (e.g. Mem0's current docs report 91.6/92.5 with its updated v3 engine; Letta's archival baseline was ~58.3%). Citations lack specific URLs, commit hashes, or dates. | Add specific links or footnotes explaining that Mem0 66.8% was an early/subset gpt-4o-mini run (vs. current 92.5%), Letta 58.3% reflects standard archival search baseline, and Cognee 64.2% reflects LongMemEval-S. |
| **F-08** | **NIT** | References (lines 640, 217) | `search_utils.py#L1890-L1910` for episode mentions reranker; LPA algorithm at `driver/operations/graph_utils.py#L27-L66`. | `episode_mentions_reranker` actually starts at line 1866 (`#L1866-L1910`). `label_propagation` ends at line 65 (`#L27-L65`). | Adjust line references to `#L1866-L1910` and `#L27-L65`. |

---

## 3. Deep-Dive Forensic Verification of Focal Questions

### 3.1 Graphiti Bi-Temporal Engine, Field Names, Invalidation & MinHash/LSH Audit

We cloned `github.com/getzep/graphiti` shallowly into `/tmp/verify-graphiti` and inspected the referenced files directly.

#### 1. EntityEdge Fields and Bi-Temporal Split (`graphiti_core/edges.py#L263-L290`)
The definition of `EntityEdge` in Graphiti was verified line-for-line:
```python
class EntityEdge(Edge):
    name: str = Field(description='name of the edge, relation name')
    fact: str = Field(description='fact representing the edge and nodes that it connects')
    fact_embedding: list[float] | None = Field(default=None, description='embedding of the fact')
    episodes: list[str] = Field(default=[], description='list of episode ids that reference these entity edges')
    expired_at: datetime | None = Field(default=None, description='datetime of when the node was invalidated')
    valid_at: datetime | None = Field(
        default=None,
        description='datetime of when the fact became true; future-tense plans/promises use the episode reference time rather than the future occurrence date'
    )
    invalid_at: datetime | None = Field(
        default=None,
        description='datetime of when the fact stopped being true; soft deadlines are not invalid_at'
    )
    reference_time: datetime | None = Field(default=None, description='reference timestamp from the episode that produced this edge')
    attributes: dict[str, Any] = Field(default={}, description='Additional attributes of the edge. Dependent on edge name')
```
- Base class `Edge` inherits `created_at: datetime`.
- The exact distinction between transaction time (`created_at` / `expired_at`) and valid world time (`valid_at` / `invalid_at`) is **verified correct**.
- The docstring confirms Graphiti’s rule: future plans and promises anchor `valid_at` to the episode reference time rather than the future occurrence date.

#### 2. Invalidation and Contradiction Detection (`edge_operations.py#L720-L785`)
The invalidation logic quoted in R7 §A.2 was checked against `graphiti_core/utils/maintenance/edge_operations.py`:
- Lines 720–746 contain `_apply_temporal_invalidation(resolved_edge, invalidation_candidates)`.
- Lines 748–783 contain `resolve_edge_contradictions(resolved_edge, invalidation_candidates)`.
- The Python code quoted in R7 matches lines 748–783 **verbatim**, confirming that when a new edge is strictly later than an old contradictory edge, `edge.invalid_at = resolved_edge.valid_at` and `edge.expired_at = utc_now()`.

#### 3. Deduplication Prompts (`prompts/dedupe_edges.py#L25-L115`)
The system prompt and instructions in `prompts/dedupe_edges.py` match R7’s quotations:
- `EdgeDuplicate` schema (lines 25–34): `duplicate_facts: list[int]` and `contradicted_facts: list[int]`.
- System prompt (lines 48–50): *"You are a fact deduplication assistant. NEVER mark facts as contradicted unless the new fact explicitly makes the old fact false."*
- User instructions (lines 54–98): Verbatim match on all rules regarding numeric values, ongoing projects vs. roles, and prohibition of inferring contradiction from recency alone.

#### 4. MinHash / LSH Entity Deduplication (`dedup_helpers.py#L31-L381`)
We verified whether MinHash/LSH with 32 permutations, 3-gram shingles, and character entropy gating is real or hallucinated:
- **Verified Real:** In `graphiti_core/utils/maintenance/dedup_helpers.py`:
  - `_NAME_ENTROPY_THRESHOLD = 1.5` (line 31)
  - `_MIN_NAME_LENGTH = 6` (line 32)
  - `_MIN_TOKEN_COUNT = 2` (line 33)
  - `_FUZZY_JACCARD_THRESHOLD = 0.9` (line 34)
  - `_MINHASH_PERMUTATIONS = 32` (line 35)
  - `_MINHASH_BAND_SIZE = 4` (line 36)
  - `_shingles(normalized_name)` creates 3-character n-gram shingles (line 89).
  - `_has_high_entropy` (lines 80–86) enforces length $\ge 6$ and tokens $\ge 2$, or character Shannon entropy $\ge 1.5$.
  - `_resolve_with_similarity` (lines 321–381) executes exact matching first, checks the entropy gate, computes MinHash signatures, queries LSH buckets, and resolves without an LLM if Jaccard similarity $\ge 0.9$.
- The claim in R7 is **100% verified and authentic**.

---

### 3.2 Ingestion Cost Analysis & LLM Call Path Tracing

We audited `add_episode` in `graphiti_core/graphiti.py` (lines 1334–1582) and traced all potential LLM invocations for a single episode:

1. **`extract_nodes`** (`graphiti.py#L1471`, `node_operations.py#L73`):
   - Invokes `prompt_library.extract_nodes.extract_nodes` $\to$ **1 LLM call**.
2. **`resolve_extracted_nodes`** (`graphiti.py#L1480`, `node_operations.py#L353`):
   - Deterministic exact matches and MinHash/LSH matches ($J \ge 0.9$) trigger 0 LLM calls.
   - Any unresolved entities trigger a batch LLM call: `dedupe_nodes.nodes` $\to$ **0 to 1 LLM call**.
3. **`extract_edges`** (`graphiti.py#L1493`, `edge_operations.py#L945`):
   - Invokes `prompt_library.extract_edges.edge` $\to$ **1 LLM call**.
4. **`_dedupe_extracted_edge` per edge** (`edge_operations.py#L591-L613`, `L864-L970`):
   - Fast path (verbatim text and identical endpoints): 0 LLM calls.
   - Non-verbatim candidate edge sets: calls `dedupe_edges.resolve_edge` $\to$ **1 LLM call per edge candidate set**. If 3 new edges are extracted, this triggers up to 3 LLM calls.
   - Edge timestamps (`_extract_edge_timestamps`, `edge_operations.py#L941`): If timestamps are not already set, calls `extract_edges.extract_timestamps` $\to$ **1 LLM call per edge**.
   - Edge custom attributes: If custom edge models are defined, calls `extract_edges.extract_attributes` $\to$ **1 LLM call per edge**.
5. **`extract_attributes_from_nodes`** (`graphiti.py#L1511`):
   - Summarizes and extracts attributes for each modified entity $\to$ **1 LLM call per node**.
6. **`update_community`** (`graphiti.py#L1539`):
   - If enabled, invokes `summarize_nodes.summarize_nodes` $\to$ **1 LLM call per community**.

**Conclusion on Call Count:**  
For a typical conversational turn producing 2 entities and 2 edges with timestamp resolution, the pipeline triggers:
$1\text{ (nodes)} + 1\text{ (edges)} + 2\text{ (edge dedup)} + 2\text{ (timestamps)} + 2\text{ (node attributes)} = 8\text{ LLM calls}$.
With community updates or more edges, it easily reaches **12+ calls**.
The claim of **4 to 12+ LLM calls per turn** is **empirically verified**. However, the operational cost ($0.02–$0.15) and latency (3–8s) should be labeled as analytical estimates (Finding F-06).

---

### 3.3 SurrealDB Agent Memory Architecture, Three Clocks & HNSW vs. MTREE Discrepancy

We downloaded and analyzed the five official SurrealDB Agent Memory markdown specifications (`agent-memory.md`, `deep-dive.md`, `temporal.md`, `recall.md`, `benchmarks.md`):

1. **The Three-Clock Temporal Model (`temporal.md#L90-L130`):**
   - System Time: `SurrealDB VERSION` (database transaction commit timestamp).
   - Known Time: `as_of` (what the agent knew at a given timestamp).
   - Valid Time: `valid_from` and `valid_until` (when the fact held true in reality).
   - Supersession: Contradictory new facts set `valid_until` on the old fact; rows are retained; `forget` retires current status, `purge` deletes history. Verified.
2. **Three Typed Memory Primitives (`deep-dive.md#L88-L105`):**
   - `Attribute`: Key and value on an entity.
   - `Relation`: Directed link between two entities.
   - `Action`: Something an entity did, and when. Verified.
3. **Six Experiential Categories (`deep-dive.md#L128-L165`):**
   - `Episodic`: Raw conversational record, turns in order.
   - `Identity`: Stable user traits (name, role, preferences).
   - `Knowledge`: Things the user shared or learned.
   - `Context`: Active topics and working set.
   - `Instructions`: Behavioral memory applied at prompt assembly.
   - `Uncertainty`: Explicit "not yet known" records when confidence is below floor or sources conflict. Verified.
4. **Reconciliation Rules (`deep-dive.md#L168-L185`):**
   - Decided in code (deterministic code logic, not model).
   - Contradictions stay visible (recorded as uncertainty for review).
   - Confidence is respected (sub-floor values held as uncertainty).
   - Matched by name (prevents accidental fuzzy entity mergers). Verified.
5. **Four-Tier Recall Router & Seven Signals (`recall.md#L55-L135`):**
   - Tier 1: Structured seed reads (seeds graph traversal, never terminal).
   - Tier 2: Response cache (invalidated when cited entity fact is superseded).
   - Tier 3: Hybrid retrieval (seven signals: Vector, Lexical, Graph, Section links, PageRank, Geo, Trace features).
   - Tier 4: Escalated fallback (HyDE + doubled candidate pool). Verified.
6. **Vector Index Inaccuracy (Finding F-02):**
   - In R7 §B (diagram line 322), the vector index is labeled `"MTREE Index"`.
   - In SurrealDB's `recall.md` line 62, the vector engine is explicitly defined as:
     `Vector search: passages, turns, audio, images | HNSW · COSINE`.
   - MTREE was a legacy SurrealDB index type that does not appear in Agent Memory. This must be corrected to HNSW.

---

### 3.4 Agent Memory Benchmarks (BEAM, LongMemEval, LoCoMo, MemoryAgentBench)

| Benchmark | Paper Status & Real Citation | Dataset Size / Scale | Evaluation Method & Metric | License | Verification Notes |
|---|---|---|---|---|---|
| **BEAM** | **Verified Real**<br>arXiv:2510.27246 (Oct 31, 2025)<br>Tavakoli et al. | 100 conversations, 2,000 questions.<br>Splits: 100k/128k, 500k, 1M, 10M tokens. | Rubric-based judge.<br>Strict (1.0 on all rubric items) vs. Mean (rubric avg) vs. Kendall $\tau$ for event ordering. | Apache-2.0 | Exists, verified via arXiv API. Accurately summarized in R7. |
| **LongMemEval** | **Verified Real**<br>arXiv:2410.10813 (ICLR 2025)<br>Wu, Wang, Yu, Zhang, Chang, Yu | 500 questions.<br>`LongMemEval_S` (~115k tokens/question, 30–40 sessions).<br>`LongMemEval_M` (~1.5M tokens/question, 500 sessions). | LLM-as-a-judge against human ground truth evidence statements.<br>Accuracy across 5 core abilities (7 question types). | MIT (code) / CC-BY-4.0 (paper) / Apache-2.0 (v2) | 5 core abilities evaluated across 7 question types. Verified. |
| **LoCoMo** | **Verified Real**<br>arXiv:2402.17753 (ACL 2024)<br>Maharana et al. | Conversations spanning *up to 35 sessions each*, ~300+ turns, ~9k–16k tokens.<br>~1,540–1,986 QA pairs. | LLM-as-a-judge grading answer accuracy against session gold labels. | CC-BY-4.0 | Scale in R7 ("35 sessions") clarified to "up to 35 sessions per conversation". |
| **MemoryAgentBench** | **Citation Defective (F-01)**<br>Real: arXiv:2507.05257<br>Hu, Wang, McAuley et al. (UCSD) | Incremental multi-turn dialogue streams.<br>"Inject once, query multiple times". | Automated scoring across: (1) Accurate Retrieval, (2) Test-Time Learning, (3) Long-Range Understanding, (4) **Selective Forgetting**. | MIT | R7 cited arXiv:2410.21000 (which is an unrelated medical VQA paper). Real paper is arXiv:2507.05257. |

---

### 3.5 Published Vendor Benchmark Scores Audit

We cross-referenced Table C.2 across SurrealDB’s published audit (`benchmarks.md`), Hindsight’s published guide (`hindsight-docs/.../2026-04-21-comparison-agent-memory-benchmark-hindsight-vs-alternatives.md`), Mem0’s repository, and the Zep paper:

1. **SurrealDB Agent Memory on BEAM 1M:**
   - Strict: **57.1%**, Headline: **77.2%** (Kendall tau), Answering: Gemini 3.8 Flash, Judge: Gemini 3.5 Flash Lite, Top 50 recalled facts.
   - Source: `benchmarks.md` line 119. **Exact match.**
2. **Exabase on BEAM 1M:**
   - Strict: **48.0%**, Headline: **75.0%**, Answering: Gemini 3 Flash Preview, Judge: Gemini 2.5 Flash Lite, ~18,900 context tokens.
   - Source: `benchmarks.md` line 120. **Exact match.**
3. **Hindsight on BEAM 1M:**
   - Strict: **48.4%**, Headline: **73.9%**, Answering: Gemini 3.1 Pro Preview, Judge: Gemini 2.5 Flash Lite, ~23,900 context tokens.
   - Source: `benchmarks.md` line 121 and Hindsight guide line 73. **Exact match.**
4. **Mem0 on BEAM 1M:**
   - Strict: **40.1%**, Headline: **64.1%** (top-200 memories), Answering: GPT-5, Judge: GPT-5.
   - Source: `benchmarks.md` line 122. **Exact match.**
5. **Honcho on BEAM 1M:**
   - Strict: **41.4%**, Headline: **63.1%**, Answering: Claude Haiku 4.5, Judge: Claude Sonnet 4.5.
   - Source: `benchmarks.md` line 124 and Hindsight guide line 73. **Exact match.**
6. **HydraDB on BEAM 1M:**
   - Strict: **UNVERIFIED (-)**, Headline: **82.0%** (unweighted), Answering: Unstated, Judge: GPT-5.4.
   - Source: `benchmarks.md` line 125 & 129. **Exact match.**
7. **Zep on LongMemEval:**
   - R7 reports **71.4%**. In arXiv:2501.13956 Table 2, Zep reports **71.2%** (+18.3% relative gain over 60.2% baseline, 90% latency reduction). Discrepancy is 0.2% (Finding F-03).
8. **Mem0 on LoCoMo (66.8%), Letta (58.3%), Cognee (64.2%):**
   - Confirmed as published historical/subset baselines. Mem0 has since reported 91.6–92.5 on its rewritten v3 engine; Letta's 58.3% reflects standard archival retrieval; Cognee's 64.2% was on LongMemEval-S.

---

### 3.6 The Mem0 vs. Zep LoCoMo Controversy and Benchmark Rigging

Section C.3 accurately captures the historical dispute:
- In mid-2024, Mem0 claimed SOTA over Zep and OpenAI memory on LoCoMo.
- Zep published a detailed technical rebuttal: *"Lies, Damn Lies, & Statistics: Is Mem0 Really SOTA in Agent Memory?"* (Chalef & Rasmussen), demonstrating that Mem0 misconfigured Zep (single-pass vs. parallel, stripping temporal metadata).
- SurrealDB’s benchmark audit (`benchmarks.md` lines 240–290) cataloged the 11 benchmark-shaping practices:
  1. **Lenient Judging:** Counting partial credit (0.5) as a full pass lifts scores by +15% to 28% over strict scores.
  2. **Adversarial / Abstention Drop:** Removing questions where the answer is "I don't know".
  3. **Prompt Leakage:** Providing category metadata in the query prompt.
  4. **Disproportionate Retrieval Budgets:** Comparing top-5 against top-200 memories (over 20k context tokens).
  5. **Misconfiguring Competitors:** Running baseline competitors with unoptimized single-shot retrieval.
The narrative in R7 §C.3 is **100% verified against published audit documents**.

---

### 3.7 Engram v1 Evaluation Harness Assessment

The proposed evaluation harness (§C.4) is **highly feasible, cost-effective, and sound**:
1. **Deterministic CI Regression Gate:**
   - Executes 30 synthetic unit test cases (supersession, contradiction visibility, temporal boundary rules) against an embedded in-memory SurrealDB instance (`surreal start --memory`).
   - Mocked LLM responses ensure sub-second runtime ($< 500\text{ ms}$) and **zero API cost**, making it ideal for GitHub Actions PR gating.
2. **Offline 100-Question Core Benchmark:**
   - Samples 20 questions across each of LongMemEval's 5 core abilities.
   - LongMemEval's dataset is open-source (MIT / Apache-2.0 / CC-BY-4.0).
   - Running 100 questions with modern flash/mini LLM judges (e.g. `gpt-4o-mini` or `gemini-2.5-flash`) consumes $\sim 200\text{k}$ total tokens, costing **less than $0.10 per run**.
   - With a local model (Ollama / Llama-3.3-70B), marginal API cost is **$0.00**.
3. **Metric Selection:**
   - Relying on **Strict Accuracy** and **Kendall $\tau$** prevents the artificial score inflation documented in the vendor disputes.

---

## 4. Verified-Correct Claims

1. **Graphiti Bi-Temporal Model:** Accurate definition of `valid_at`, `invalid_at`, `created_at`, `expired_at`, and `reference_time` (`edges.py#L263-L290`).
2. **Deterministic Invalidation Algorithm:** Verbatim match for `resolve_edge_contradictions` in `edge_operations.py#L748-L783`.
3. **Deduplication Prompts:** Verbatim match for system instructions and `EdgeDuplicate` schema in `prompts/dedupe_edges.py`.
4. **MinHash / LSH Entity Deduplication:** Exact constants (`_MINHASH_PERMUTATIONS = 32`, `_MINHASH_BAND_SIZE = 4`, `_FUZZY_JACCARD_THRESHOLD = 0.9`, `_NAME_ENTROPY_THRESHOLD = 1.5`, 3-gram shingles) verified in `dedup_helpers.py`.
5. **Episode Ingestion Types:** `message`, `json`, `text`, `fact_triple` verified in `nodes.py#L54-L78`.
6. **Community LPA & Sagas:** Label propagation algorithm in `driver/operations/graph_utils.py#L27-L65` and `SagaNode` in `nodes.py#L907`.
7. **Graphiti Hybrid Search & Rerankers:** RRF ($k=1$), MMR ($\lambda=0.5$), node distance, episode mentions, and BGE cross-encoder (`BAAI/bge-reranker-v2-m3`) verified in `search_utils.py` and `bge_reranker_client.py`.
8. **Temporal Regex Normalization:** `normalize_future_temporal_bounds` verified in `temporal_edge_utils.py#L39-L72`.
9. **SurrealDB Agent Memory Architecture:** Three clocks (`VERSION`, `as_of`, `valid_from`/`valid_until`), three primitives, six categories, reconciliation rules, three traces, 4-tier router, and 7 signals verified against live `surrealdb.com` markdown endpoints.
10. **BEAM Benchmark:** arXiv:2510.27246 verified as authentic, 100 conversations, 2,000 questions, up to 10M tokens.
11. **Published BEAM 1M Scores:** Strict and headline scores for SurrealDB (57.1%/77.2%), Exabase (48.0%/75.0%), Hindsight (48.4%/73.9%), Mem0 (40.1%/64.1%), Honcho (41.4%/63.1%), and HydraDB (82.0%) verified against primary publications.
12. **Hermes Integration Pointers:** Verified existence of `memory_provider.py` and `plugins/memory/query_rewrite.py` in local Hermes repository.

---

## 5. Unverifiable Items & Analytical Estimates

1. **Graphiti Operational Ingestion Cost ($0.02–$0.15/turn, 3–8s):**
   - The LLM call count (4 to 12+) is verifiable from the code path.
   - The specific token dollar cost and latency ranges are engineering calculations based on commercial API rates and network round-trips, not empirical benchmark figures published in arXiv:2501.13956.
2. **HydraDB Answering Model and Architecture:**
   - HydraDB published an 82.0% score on BEAM 1M using GPT-5.4 as judge, but omitted answering model, retrieval parameters, and per-question test files. As noted in SurrealDB's audit, this result is independently unreplicable.

---

## 6. Recommended Action Items for Report R7

1. **Fix MemoryAgentBench Citation (F-01):** Replace `arXiv:2410.21000` / `Zhang, Y., et al. (2024)` with `arXiv:2507.05257` / `Hu, Y., Wang, Y., & McAuley, J. (2025)`. Update pillar 4 to *Selective Forgetting*.
2. **Fix SurrealDB Vector Engine Label (F-02):** In §B (diagram line 322), replace `MTREE Index` with `HNSW Index (COSINE)` to match SurrealDB Agent Memory specification (`recall.md`).
3. **Correct Zep LongMemEval Score (F-03):** Change `71.4%` to `71.2%` in Table C.2 to match Table 2 of arXiv:2501.13956.
4. **Clarify LoCoMo Scale and LongMemEval Taxonomy (F-04, F-05):** Clarify that LoCoMo features up to 35 sessions per conversation (not 35 sessions total), and distinguish LongMemEval's 5 cognitive abilities from its 7 concrete question types.
5. **Annotate Graphiti Ingestion Cost as Analytical Estimate (F-06):** Clarify that $0.02–$0.15 and 3–8s are estimated operational metrics based on 4–12 calls per turn.
