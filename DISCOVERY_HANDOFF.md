# Engram — Discovery Handoff & PRD Input

**Status:** Discovery complete. Ready for PRD authoring and implementation.
**Audience:** An AI coding agent (Claude Code / Codex / Hermes) picking this up cold.
**Product name:** **Engram** (working title, locked by the user)
**Owner:** Ichsan Rahardianto (`irahardianto`), Hermes Agent user, Linux, Jakarta (WIB)
**Date of discovery:** October 2026

---

## 0. How to use this document

This is a **distillation of a long design conversation**, not a PRD. Your job is to turn it into a concrete PRD and then build the thing.

Read sections 1–5 before writing any spec. Sections 6–10 are already-settled technical decisions — do not re-litigate them unless you find a hard technical blocker. Section 11 lists what is genuinely still open.

**Do not propose Mem0, Zep, Letta, or a generic vector-DB RAG layer as the answer.** Those were evaluated and rejected with reasons (see §4). Re-proposing them wastes the user's time.

---

## 1. Elevator pitch

> Today's agent memory is broken in one of two ways. It is either flat vector RAG — which finds things that *sound* similar but is blind to relationships, time, and contradiction — or it is a "poly-store" contraption that duct-tapes a graph database to a vector database to a relational database and hopes the Python glue keeps them in sync.
>
> **Engram** is a unified, single-engine long-term memory layer for the Hermes agent, built natively on SurrealDB. Documents, knowledge-graph edges, vector embeddings, full-text indexes, and temporal provenance all live in the same records under a single ACID transaction. Engram gives an agent human-like recall: it connects entities, tracks how facts evolve over time, and *flags contradictions instead of silently overwriting them*.
>
> One Rust binary, zero orchestrator daemons, no glue code, no drift. **Engram — the physical memory trace for autonomous agents.**

---

## 2. What problem it solves

The user runs Hermes Agent locally on a high-bandwidth NVMe machine. Over months of daily use across automation, email triage, health/athletics data, finance, and project work, two failure modes appear:

**Failure mode A — the native memory ceiling.**
Hermes's built-in memory is two curated text files (`MEMORY.md` ~2.2k chars, `USER.md` ~1.4k chars) injected into every turn. This is excellent for standing facts and is *not* being replaced. But it is deliberately tiny and manually curated, so it cannot hold the episodic long tail: *"what did we decide about the Garmin key rotation back in July"*, *"which repo used which build flag"*, *"who said what in the Tokopedia vetting thread"*. That history exists only as raw transcripts retrievable by keyword search, with no entity structure and no notion of what is still true.

**Failure mode B — the poly-store memory stack.**
The available external memory frameworks (Cognee, Mem0, Zep/Graphiti) each solve extraction and retrieval well, but architecturally they are *coordinators*: they route graph nodes to one store, embeddings to a second, and relational/session metadata to a third. Consequences the user actually cares about:
- No atomic write across the three stores → partial writes leave orphaned graph pointers and index drift that no one cleans up.
- Contradictions are handled by application-level heuristics or by silently letting both edges coexist, so the agent cannot distinguish *"currently true"* from *"was true in March"*.
- Operational sprawl: a graph daemon, a vector store, a server process for the memory framework itself, an embedding service — four moving parts to keep alive for one agent.

**The gap Engram fills:** durable, entity-structured, temporally-aware long-term memory that is *one* system with *one* consistency model and *one* process to run.

---

## 3. Why the user wants this to exist at all

Explicit, quoted intent from the discovery conversation, so you do not mistake this for a whimsical side project:

> "natively … it need skills to work better, let alone the rest mechanics"  — on why tool-call-based memory (MCP `remember`/`recall`) feels fragile

> "given seems like the falkordb ecosystem for agentic memory is much more mature and the underlying tech i.e. falkor, covers my use graph + vector" — the user *knows* the mature path exists and is choosing to build anyway

> "why I should create a new memory system on top of surrealdb, what will I miss?"

The user is not avoiding work. They are choosing a **single-engine multi-model architecture** over a **poly-store** one, and they want a real Hermes-native `MemoryProvider` (lifecycle-integrated, automatic prefetch + write-behind) rather than a tool-call interface. Respect that framing.

---

## 4. Decision log — what was evaluated and rejected, and why

This section exists so the PRD can state *"we are not building X because Y"* with authority.

### 4.1 Memory frameworks

| Candidate | Verdict | Reasoning |
|---|---|---|
| **Hindsight** (vectorize-io) | Strong, **not chosen** | Best-in-class benchmark scores; 4-way hybrid retrieval (dense vector + BM25 + graph + temporal) with Reciprocal Rank Fusion and cross-encoder rerank; native Hermes provider plugin exists. **But** its storage is PostgreSQL + `pgvector` + `pg_trgm`. Graph is modelled relationally (entity/edge tables + recursive CTEs) — not a graph engine. Rejected on architecture: the user wants real graph semantics, not SQL joins pretending to be edges. |
| **Cognee** | Mature, **useful reference** | Already in the Hermes catalog (`plugin-catalog/cognee.yaml`). Graph-native extraction pipeline, four-op API (`remember`/`recall`/`forget`/`improve`), pluggable backends including FalkorDB/Neo4j/Kuzu/LanceDB. **But** it is a poly-store coordinator by design — its own docs describe "graph, vector and relational in one pipeline", i.e. multiple stores. Best used as a *reference implementation for extraction prompts and lifecycle hooks*, not as the runtime. |
| **Mem0** | Mature, **rejected** | Catalog plugin exists; broadest adoption. Vector-first flat atomic facts with optional graph. Treats memory as facts, not as a world model. Not a fit for relational/temporal reasoning. |
| **Zep / Graphiti** | Mature, **rejected (mostly)** | Graphiti is genuinely good: bi-temporal knowledge graph. **But** it requires Neo4j/FalkorDB/Neptune, and Zep's Community Edition is deprecated; self-hosting means running your own user/session management anyway. Its bi-temporal model is a **direct input to Engram's design** — study it, don't ship it. |
| **Qdrant (`qdrant-memory`)** | Solid, **rejected** | Native Hermes catalog plugin, Rust, `mmap`-friendly. Pure vector + payload engine; no graph traversal. Fine as a fallback, wrong as the core. |
| **LanceDB (`lancedb-suite`)** | Good, **rejected** | Catalog plugin; embedded, serverless, NVMe-native, typed relations and conflict tracking. But relations are simulated in-column, not traversable. Great *embedded embedding store*; would still need a graph layer. |
| **hwiki** | Good, **rejected** | Catalog plugin; Obsidian-compatible markdown + SQLite FTS5. Excellent for human-readable notes; not a queryable entity graph. |
| **Redis Iris / Redis Agent Memory** | **Rejected** | Two-tier session + long-term memory with automated extraction. Proprietary to Redis Ltd., public preview, RAM-priced, no real graph traversal. |
| **Valkey / Dragonfly** | **Rejected** | No agent-memory framework exists on either. Redis Iris does not exist in open-source Valkey. Would require writing everything from scratch anyway, on a RAM-only engine. |
| **SurrealDB Agent Memory** (vendor product) | **Rejected as a product, adopted as a model** | Correct architecture in principle, but shipping today it is cloud-first, MCP-tool-exposed, and has no Hermes lifecycle integration. Engram reuses the *ideas* (typed facts, provenance, explicit uncertainty) inside a native provider. |

### 4.2 Why not just run FalkorDB + Cognee today?

This was the strongest counter-argument raised, and it deserves a straight answer in the PRD's "alternatives considered" section:

**FalkorDB + Cognee is the correct choice for anyone who wants Graph + Vector working this afternoon.** Zero code, ten minutes, `docker run falkordb/falkordb` + `hermes plugins install cognee`. FalkorDB (the successor to RedisGraph) is a serious engine: OpenCypher, GraphBLAS sparse-matrix traversal, sub-millisecond multi-hop, and first-class integrations with Graphiti, Cognee, and Mem0.

Engram is chosen instead for four specific gains, each of which the user is knowingly paying engineering cost for:

1. **Single-engine ACID vs. poly-store drift.** One write transaction updates the entity text, its embedding, its graph edges, and its temporal validity together. Cognee's pipeline spans FalkorDB + LanceDB/pgvector + SQLite/Postgres; a crash mid-pipeline leaves them inconsistent.
2. **Native contradiction and uncertainty modelling.** Engram records both claims plus a confidence and a validity interval rather than picking a winner by cosine similarity. This is a first-class schema concern, not application logic.
3. **Operational simplicity.** One `surreal start` process replaces a graph daemon + vector store + framework server + glue. On a fast NVMe this is a latency non-issue.
4. **True lifecycle integration.** A `MemoryProvider` gets `prefetch()` before the model runs and `sync_turn()` after — no tool-call hop, no "ignorance paradox" where the agent fails to call `recall` because it does not know it has forgotten something.

> **PRD requirement:** state this trade-off explicitly and honestly. Engram is *not* claiming FalkorDB+Cognee is bad. It is claiming a different consistency model is worth the build.

---

## 5. Environment facts the implementation must respect

- Host: Linux, kernel 7.x. User home `~`. **Storage: NVMe, ~12 Gbps** — disk-bound designs are acceptable; do not over-optimise for RAM residency.
- Hermes is **git-installed** at `~/.hermes/hermes-agent/`. `hermes` binary is `~/.local/bin/hermes`.
- Active profile: `default`. Per-profile state lives under `$HERMES_HOME` (default `~/.hermes/`) with `profiles/<name>/` for others. **Never hardcode `~/.hermes` in provider code** — use the `hermes_home` kwarg from `initialize()`.
- Python deps for plugins are prepared by the PM layer; declare them in `pyproject.toml` / `pip_dependencies`, do not `pip install` into Hermes's env by hand.
- The user's `config.yaml` uses OpenRouter as default provider; secrets belong in `.env`, settings in `config.yaml`, and **never hand-edit `config.yaml` — use `hermes config set`**.

---

## 6. Technical architecture (settled)

### 6.1 Integration surface

Engram is a **directory memory provider**, not an MCP server and not a plugin with a toolset-only surface:

```
$HERMES_HOME/plugins/engram/
├── __init__.py        # MemoryProvider subclass + register(ctx)
├── plugin.yaml        # name, version, description, external_dependencies
├── pyproject.toml     # python deps (surrealdb client, embedding client)
├── schema.surql       # namespace/table/index definitions, idempotent
├── config_schema.py   # fields for `hermes memory setup` dashboard panel
├── README.md          # setup, config reference, tools
└── prompts/           # entity-extraction + contradiction prompts, versioned
```

Discovery precedence (bundled → user → project → package entry point) is handled by Hermes; a user-installed provider lives in `$HERMES_HOME/plugins/engram/`. Activation is exclusively via:

```bash
hermes config set memory.provider engram
```

Only **one** external provider may be active at a time. The built-in `MEMORY.md`/`USER.md` store stays active alongside it and is not replaced.

### 6.2 The `MemoryProvider` contract to implement

Source of truth: `~/.hermes/hermes-agent/agent/memory_provider.py` (read it before coding — the docstrings carry hard requirements). Required and important methods:

**Abstract (must implement):**
- `name` → property returning `"engram"`.
- `is_available()` → configured/credentialed/importable. **No network calls.** Check config + importability only.
- `initialize(session_id, **kwargs)` → build the SurrealDB client, apply `schema.surql` idempotently, start the writer thread. `kwargs` always includes `hermes_home` and `platform`, and may include `agent_context` (`primary` | `subagent` | `cron` | `flush`) — **skip durable writes for non-primary contexts**; `agent_identity`, `agent_workspace`, `user_id`.
- `get_tool_schemas()` → optional explicit tools. Recommend a minimal set (see §6.7).

**The two that matter most:**
- `prefetch(query, *, session_id="")` → returns formatted recall context for the upcoming turn, or `""`. **Must be fast.** Do not run the hybrid query synchronously here — return what `queue_prefetch()` already computed on the previous turn; fall back to a cached/empty result on a cold start.
- `queue_prefetch(query, *, session_id="")` → kick off the hybrid retrieval on a background thread via `spawn_context_thread(...)` so the next turn's `prefetch()` is a cheap read.

**Write path:**
- `sync_turn(user_content, assistant_content, *, session_id="", messages=None, turn_author=None)` → must be **non-blocking**. Enqueue onto a single-writer background thread; return immediately. Consider whether the signature accepts `turn_author` (the manager passes it only if the signature does).

**Optional hooks worth implementing:**
- `on_session_end(messages)` → end-of-session consolidation pass (promote repeated observations, expire stale edges).
- `on_pre_compress(messages)` → extract durable facts from transcript about to be summarized. Set `pre_compress_checkpoint_api_version = 2` **only if** you durably checkpoint; otherwise leave at the default 1.
- `on_memory_write(action, target, content, metadata=None)` → mirror built-in `MEMORY.md`/`USER.md` writes into Engram so the curated store and the graph stay coherent. `metadata["previous_content"]` carries the prior entry for `replace`/`remove`.
- `on_session_switch(new_session_id, *, parent_session_id="", reset=False, rewound=False, **kwargs)` → rebind per-session buffers on `/new`, `/resume`, `/branch`, compression.
- `on_delegation(task, result, *, child_session_id="", **kwargs)` → parent-side observation of subagent work.
- `recall_status()` → return `RecallStatus(provider_label="Engram", count=N)` so the deterministic recall indicator renders. Must reflect only the last prefetch.
- `get_config_schema()` / `save_config(values, hermes_home)` → for `hermes memory setup`. Every secret field must carry `env_var` so it lands in `.env`.
- `backup_paths()` → must work **without** `initialize()` or network. Return SurrealDB data dir if it lives outside `HERMES_HOME`.

### 6.3 Hard invariants (violating these breaks Hermes)

Reproduced from the ABC docstring and Hermes skill — treat as build-blocking:

- **Multiplexing / profile isolation.** One gateway process may serve several profiles. Hand out a **new instance per load**; bind every store, path, client and tenant from `initialize()`'s `hermes_home`; keep **no** profile-specific mutable state at module or class level. Two profiles' calls interleave on different threads.
- **Every background job must use `spawn_context_thread(...)`** from `agent.memory_provider` — it propagates ContextVars so secrets and profile scope resolve correctly. A bare `threading.Thread` silently lands on the default profile or fails closed on secrets.
- **`prefetch()` must never block on the network.** Hermes bounds external prefetch with a timeout and a stuck-call gate; a provider that hangs repeatedly gets skipped for later turns. Design for cache-then-serve, and make the hybrid query cancellable.
- **`sync_turn()` must never block the user's turn.** Single writer thread, bounded queue, durable retry queue on shutdown (fail-closed), and redact before persisting.
- **Secrets in `.env` only**, read through `agent.secret_scope.get_secret`. Settings via `hermes config set`. Never write a non-credential setting into `.env`.
- **Respect `is_trivial_prompt()`** — skip recall for greetings, acknowledgements, slash commands, and empty input. It is exported from `agent.memory_provider` and already used by the core gate.

### 6.4 Data model (SurrealQL draft — refine during PRD)

Multi-model in one database: document fields, vector fields, and graph edges on the same records.

```surql
-- Namespace/database per profile+workspace, e.g. ns: hermes, db: default
DEFINE TABLE entity SCHEMAFULL;
DEFINE FIELD name          ON entity TYPE string;
DEFINE FIELD kind          ON entity TYPE string;         -- person | project | tool | account | concept
DEFINE FIELD aliases       ON entity TYPE array<string> DEFAULT [];
DEFINE FIELD summary       ON entity TYPE string DEFAULT "";
DEFINE FIELD embedding     ON entity TYPE array<float>;   -- dim fixed at config time
DEFINE FIELD first_seen    ON entity TYPE datetime DEFAULT time::now();
DEFINE FIELD last_updated  ON entity TYPE datetime DEFAULT time::now();
DEFINE FIELD confidence    ON entity TYPE float DEFAULT 0.7;
DEFINE INDEX entity_name        ON entity FIELDS name UNIQUE;
DEFINE INDEX entity_fts         ON entity FIELDS summary SEARCH ANALYZER ascii BM25;
DEFINE INDEX entity_vec         ON entity FIELDS embedding MTREE DIMENSION 1024;

-- Episodic memory: the raw trace, never rewritten
DEFINE TABLE episode SCHEMAFULL;
DEFINE FIELD session_id    ON episode TYPE string;
DEFINE FIELD role          ON episode TYPE string;       -- user | assistant | tool
DEFINE FIELD text          ON episode TYPE string;
DEFINE FIELD at            ON episode TYPE datetime DEFAULT time::now();
DEFINE FIELD embedding     ON episode TYPE array<float>;
DEFINE FIELD turn_ref      ON episode TYPE option<string>;
DEFINE INDEX episode_session ON episode FIELDS session_id, at;
DEFINE INDEX episode_fts     ON episode FIELDS text SEARCH ANALYZER ascii BM25;
DEFINE INDEX episode_vec     ON episode FIELDS embedding MTREE DIMENSION 1024;

-- Facts as graph edges, bi-temporal
DEFINE TABLE asserts SCHEMAFULL TYPE RELATION IN entity OUT entity;
DEFINE FIELD predicate     ON asserts TYPE string;        -- works_at | prefers | owns | depends_on
DEFINE FIELD confidence    ON asserts TYPE float DEFAULT 0.7;
DEFINE FIELD valid_from    ON asserts TYPE datetime DEFAULT time::now();  -- true in the world
DEFINE FIELD valid_to      ON asserts TYPE option<datetime>;             -- null = still true
DEFINE FIELD learned_at    ON asserts TYPE datetime DEFAULT time::now();  -- transaction time
DEFINE FIELD source        ON asserts TYPE string;         -- session id, file, url, "user-stated"
DEFINE FIELD contested     ON asserts TYPE bool DEFAULT false;
DEFINE FIELD contradiction_of ON asserts TYPE option<record<asserts>>;
DEFINE INDEX asserts_live ON asserts FIELDS valid_to;

-- Observations: consolidated beliefs derived from many episodes
DEFINE TABLE observation SCHEMAFULL;
DEFINE FIELD claim         ON observation TYPE string;
DEFINE FIELD support_count ON observation TYPE int DEFAULT 1;
DEFINE FIELD confidence    ON observation TYPE float DEFAULT 0.5;
DEFINE FIELD evidence      ON observation TYPE array<record>;  -- episode/asserts refs
DEFINE FIELD embedding     ON observation TYPE array<float>;
DEFINE INDEX observation_vec ON observation FIELDS embedding MTREE DIMENSION 1024;
```

Design notes:
- `episode` is immutable. Corrections happen by asserting new facts and closing old ones (`valid_to`), never by editing history. This mirrors the `raw/` immutability rule that works well elsewhere.
- Bi-temporal split (`valid_from/valid_to` = world time; `learned_at` = transaction time) is the single most valuable idea borrowed from Graphiti. Implement it from day one; retrofitting it is painful.
- Contradiction is represented, not resolved: both `asserts` edges exist, `contested=true`, `contradiction_of` links them, and retrieval surfaces both with dates.

### 6.5 Retrieval design

Four strategies executed in parallel, then fused:

1. **Dense vector** — `episode_vec` / `observation_vec` / `entity_vec` k-NN on the query embedding.
2. **Sparse keyword** — BM25 over `episode.text`, `entity.summary` (SurrealDB native `SEARCH ANALYZER ... BM25`).
3. **Graph** — from top-N vector/BM25 hits, traverse 1–2 hops: `SELECT ->asserts->entity.* FROM <hit entity>` plus live-edge filtering (`valid_to == null`).
4. **Temporal** — recency boost on `at` / `last_updated`; explicit range filtering when the query mentions time.

Fuse with **Reciprocal Rank Fusion** (no tuning needed, robust across incompatible score scales), then optionally rerank with a cross-encoder if configured. Trim to a configurable token budget.

**Output format** must be compact, dense, and append-only-friendly markdown, e.g.:

```
## Recalled context (Engram)
- Alice — teammate, owns `billing-service` (conf 0.9, since 2026-03)
- Project billing-service uses Python 3.12 (conf 0.8, valid since 2026-02; superseded Rust claim from 2025-11 is marked contested)
- 2026-07-14: user asked to rotate GARMIN key; done same day
```

**Contended facts must be shown with their dates and the `contested` marker.** Do not let the LLM smooth over the disagreement.

### 6.6 Ingestion pipeline (write path)

On `sync_turn`, enqueue `{user, assistant, session_id, turn_author, ts}`. The single writer thread:

1. **Redact** secrets/PII using Hermes's existing redaction helpers before anything is persisted or sent to an embedding endpoint.
2. **Embed** the turn text (batch where possible).
3. **Extract** structured facts with an auxiliary LLM using a versioned prompt: entities (with canonical names + aliases), typed relations, and the *time reference* the fact is valid from ("yesterday", "last month" → resolve to absolute).
4. **Resolve** entities against existing rows (exact alias match → embedding similarity above threshold → create new).
5. **Reconcile** against live edges: same subject+predicate+object → bump confidence; different object for a functional predicate → close the old edge (`valid_to = now`), insert the new one, mark `contested` when the source is not authoritative, link via `contradiction_of`.
6. **Persist** in **one transaction**: episode + entities upserted + edges + observations touched.
7. **Compact** opportunistically: promote frequently-supported claims into `observation` records; expire edges whose source episodes were deleted.

Keep the extraction model configurable (local Ollama preferred for this user; any OpenAI-compatible endpoint allowed). Every prompt is a versioned file so re-extraction is reproducible.

### 6.7 Tools to expose

Minimal, explicit surface — the automatic lifecycle does the heavy lifting; tools exist for deliberate agent action:

| Tool | Purpose |
|---|---|
| `engram_recall` | Explicit hybrid search, returns ranked memories with dates and confidence |
| `engram_remember` | Persist a fact the agent judges important but which extraction would miss (an instruction, a preference, a decision) |
| `engram_forget` | Retire a fact or episode by id (`valid_to = now`, never a hard delete) |
| `engram_entities` | List/inspect entities and their live relations for a name — the debugging and "what do you know about X" surface |
| `engram_status` | Health, counts, schema version, last write, queue depth — for `hermes doctor` and the dashboard |

`handle_tool_call` must return a JSON string. Tool errors should use `tools.registry.tool_error`.

### 6.8 Deployment and config

- **Embedded mode (default):** Engram connects to a local `surreal start` (or uses an embedded/local file store) at a profile-scoped path. Single binary, no Docker.
- **Server mode:** `SURREAL_URL` + credentials for a shared instance, namespace per profile, database per workspace.
- Config keys under `memory.engram` in `config.yaml`: `url`, `namespace`, `database`, `embedding_provider`, `embedding_model`, `embedding_dim`, `extraction_model`, `prefetch_token_budget`, `top_k`, `rrf_k`, `rerank_enabled`, `extract_on_turn`, `write_approval`. Secrets (`SURREAL_PASS`, `SURREAL_TOKEN`) in `.env` via `env_var` fields.

---

## 7. Scope

**In scope for v1**
- Native `MemoryProvider` with `prefetch` / `queue_prefetch` / `sync_turn` / `shutdown`.
- SurrealQL schema bootstrap, idempotent, with migration versioning.
- Hybrid retrieval (dense + BM25 + graph + temporal) with RRF.
- LLM extraction with entity resolution and functional-predicate reconciliation.
- Bi-temporal edges, explicit contradiction marking.
- Five tools from §6.7.
- Mirroring of built-in `MEMORY.md`/`USER.md` writes via `on_memory_write`.
- `hermes memory setup` config schema, `hermes doctor` health check.
- Embedded single-process deployment against a local SurrealDB.

**Explicit non-goals for v1**
- Replacing the built-in curated memory store. It stays.
- A web UI or graph visualisation (a `surreal` CLI query is enough; Grafana/`g.v()`-style viz later).
- Multi-user / multi-tenant hosting, auth, or a hosted SaaS.
- Fine-tuning embeddings; any local model is fine.
- Image/audio memory.
- Cross-profile memory sharing (each profile is isolated by default).
- Real-time collaboration between concurrent writers to the same bank.

---

## 8. Milestones & acceptance criteria

**M0 — Skeleton (hours).** Provider loads, `is_available()` true, `initialize()` creates namespace + tables idempotently, `hermes config set memory.provider engram` activates it, `hermes doctor` shows it healthy, `shutdown()` is clean.
*Accept:* two consecutive `initialize()` calls leave identical schema; `prefetch()` returns `""` without erroring on an empty store.

**M1 — Write path.** `sync_turn` enqueues and persists episodes without blocking; extraction creates entities and at least one typed edge; redaction verified.
*Accept:* a scripted 20-turn conversation produces a graph with ≥5 entities and ≥5 edges; measured p95 added latency to the turn is ~0 (write-behind confirmed by log timestamps).

**M2 — Read path.** `queue_prefetch` builds the cache, `prefetch` serves it; hybrid RRF retrieval returns dated, confidence-scored context; `recall_status()` reports counts.
*Accept:* a query about a fact stated 15 turns earlier surfaces it in the injected block; a greeting injects nothing (trivial-prompt gate respected); `prefetch` never exceeds the configured token budget.

**M3 — Truth maintenance.** Contradicting fact closes the prior edge, opens a new one, marks both `contested`, and both appear in recall with dates. `on_pre_compress` preserves facts about to be summarized away.
*Accept:* deliberately assert "service X uses Rust", then "service X uses Python" — recall shows Python as current and Rust as superseded-but-recorded, and no silent overwrite is observed in the DB.

**M4 — Integration polish.** `on_memory_write` mirroring, `on_session_end` consolidation, `backup_paths`, `get_config_schema` for `hermes memory setup`, README.
*Accept:* `hermes backup` includes Engram state; a fresh profile can be set up entirely through `hermes memory setup`.

---

## 9. Reference material to read before coding

**Hermes internals (authoritative — read, don't guess):**
- `~/.hermes/hermes-agent/agent/memory_provider.py` — the ABC, `spawn_context_thread`, `RecallStatus`, `is_trivial_prompt`.
- `~/.hermes/hermes-agent/agent/memory_manager.py` — lifecycle fan-out, prefetch timeout + stuck-call gate, background sync executor, single-external-provider rule, profile-scope enforcement.
- `~/.hermes/hermes-agent/agent/agent_init.py` (~lines 1320–1380) — how `memory.*` config, the built-in store, and the external provider are wired together.
- `~/.hermes/hermes-agent/tools/memory_tool.py` — built-in store, `on_memory_write` contract, char limits.
- `~/.hermes/hermes-agent/website/docs/developer-guide/memory-provider-plugin.md` — the official provider guide.
- `~/.hermes/hermes-agent/plugins/memory/byterover/` and `.../retaindb/` — two complete, shipping reference implementations (CLI-backed and HTTP-backed). **Engram's structure should look like these.**
- `~/.hermes/hermes-agent/plugin-catalog/hindsight.yaml`, `cognee.yaml`, `mem0.yaml`, `qdrant-memory.yaml` — how catalog disclosures and capability declarations are written.

**External:**
- SurrealDB docs: graph relations (`RELATE`, `->edge->node` traversal), `DEFINE INDEX ... MTREE`, `SEARCH ANALYZER ... BM25`, transactions.
- Hindsight retrieval design (4-way + RRF) — `https://hindsight.vectorize.io/developer/retrieval`.
- Graphiti / Zep bi-temporal model — the source of the `valid_from` / `valid_to` / `learned_at` split.
- SurrealDB Agent Memory's "typed facts with provenance and uncertainty" writeup — `https://surrealdb.com/agent-memory/deep-dive`.
- Hermes docs index: `https://hermes-agent.nousresearch.com/docs/llms.txt` (see `/developer-guide/plugins` and `/user-guide/features/memory`).

---

## 10. Messaging and naming (locked)

- **Name:** Engram. Noun, from neuroscience: the physical trace a memory leaves in neural tissue. Pronounceable and spellable for a non-native English speaker (the user rejected "Eidetic" precisely because the `ei` spelling is unintuitive in Indonesian).
- **Slogan (primary):** *"The physical memory trace for autonomous agents."*
- **Slogan (alt, for README):** *"One engine. Zero drift. Absolute recall."*
- **Rejected names, for the record:** Eidetic (unintuitive spelling for the owner), Veritas (collides with Veritas Technologies), SurCortex, Synapsis, Anamnesis, ChronoGraph, Axiom, OmniRecall, SurMind, Continuum, Vivid, Memex, Locus, Nexus, Imprint, Strata, Cortex, Anchor.
- **Tone:** developer-first, confident, no hype adjectives. Claims must be technical and checkable. Never market this as "AI that remembers everything" — it is *structured, temporal, contradiction-aware* memory.

---

## 11. Open questions the PRD must resolve

1. **Embedding model and dimension.** Local Ollama (`nomic-embed-text` 768, or `qwen3-embedding:4b` at 2560) vs. a remote OpenAI-compatible endpoint. Dimension is baked into `MTREE DIMENSION` and every row — changing it later means re-embedding everything. Decide and document migration.
2. **Extraction cost ceiling.** One extraction LLM call per turn is the dominant running cost. Do we extract every turn, or batch per N turns / at session end? Propose a default with a measured token estimate.
3. **Automatic vs. approved writes.** Hermes supports `memory.write_approval`. Should Engram facts be auto-committed (fast, risky) or staged for review? Recommend auto for `episode` (raw trace) and approval-gated for `asserts` that close existing edges.
4. **Entity-resolution thresholds.** Exact alias → fuzzy string → embedding similarity. Pick numeric thresholds and a tie-break, and make them configurable.
5. **Scope of the graph.** Prose-to-triples extraction reliably produces garbage on conversational filler. Define a closed predicate vocabulary (start with ~10: `works_at`, `owns`, `prefers`, `depends_on`, `located_at`, `part_of`, `uses`, `related_to`, `scheduled_for`, `credentials_for`) and reject extractions outside it.
6. **Consolidation policy.** When do episodes become observations? Propose a rule (e.g. ≥3 supporting episodes within 90 days) and what happens to the underlying episodes (kept; `observation.evidence` references them).
7. **Subagent and cron writes.** `agent_context` is `subagent`/`cron` for non-primary runs. Which of those should write to Engram? Recommended default: read yes, write no — avoid a cron job polluting long-term memory.
8. **Backup and portability.** Does `hermes backup` ship a SurrealDB dump, or the raw data dir? A dump is portable across `surreal` versions; a data dir is not. Recommend `surreal export`.
9. **Migration story.** Schema version table + forward-only migrations applied at `initialize()`. Rehearse a v1→v2 migration on a populated store before shipping v2 exists.
10. **Failure mode UX.** If SurrealDB is down, does Hermes start normally with a warning (preferred), and does the writer queue persist across restarts? Define the fail-closed vs. degrade-open policy per operation.

---

## 12. One-paragraph instruction to the implementing agent

Build a Hermes directory memory provider called **Engram** at `$HERMES_HOME/plugins/engram/`, subclassing `MemoryProvider` from `agent/memory_provider.py`, backed by SurrealDB as a single multi-model engine holding episodes, entities, bi-temporal graph edges, observations, and their embeddings. Follow the contract in §6 exactly — especially `spawn_context_thread` for all background work, non-blocking `sync_turn`, cached `prefetch`, per-profile binding, and redaction before persistence. Read the two reference providers (`byterover`, `retaindb`) and the official provider guide before writing code. Deliver milestones M0–M4 with the stated acceptance criteria, and answer the ten open questions in the PRD before implementing the reconciliation logic — that logic is where this design either works or turns into noise.
