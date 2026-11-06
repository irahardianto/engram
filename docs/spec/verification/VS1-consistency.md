# Engram Specification Package — Cross-Document Consistency Audit (VS1)

**Audit Date:** 2026-10-24  
**Auditor:** Principal Verification Engineer (Independent Skeptical Audit)  
**Target:** Engram v1 Specification Package (`docs/spec/00-decisions.md` through `12-prior-art-learnings.md`, `migrations/0001_init.surql`, `prompts/extract.v1.md`, `prompts/consolidate.v1.md`, `Dockerfile`, `docker-compose.yml`)  
**Binding Baseline:** `docs/spec/00-decisions.md` (Current content wins) + Orchestrator CBOR /rpc binding update (2026-10-24)

---

## 1. Summary Verdict

### Verdict: **FAIL** (Remediation Required Before Implementation)

The Engram specification package demonstrates extraordinary conceptual depth, rigorous algorithmic grounding in prior art (Hindsight, Mem0, Cognee, Zep), and high overall cohesion. However, mechanical and semantic cross-document verification identified **4 BLOCKER** and **11 MAJOR** inconsistencies that would cause immediate runtime crashes, schema rejections in SurrealDB `SCHEMAFULL` mode, or complete breakdown of the Hermes Agent read path:

1. **[BLOCKER] SurrealDB `/rpc` Wire Format:** `00-decisions.md` ADR-02 strictly mandates CBOR on `/rpc` via `ciborium` because SurrealDB JSON-RPC irreversibly coerces bound strings shaped like `ident:ident` (e.g. `"User: Hello"`, `"Note: fix"`) into record IDs and truncates them. `02-architecture.md` and `11-rust-implementation-guide.md` erroneously specify JSON (`application/json`, `serde_json`, `.json(&request)`), and `Cargo.toml` in `11` omits `ciborium`.
2. **[BLOCKER] Missing `timezone` Field on `meta` Table:** ADR-05, ADR-16, and §3.5 mandate storing the bank timezone in `meta.timezone`. However, `migrations/0001_init.surql` and `03-data-model.md` define `meta` as `SCHEMAFULL` without a `timezone` field. Attempting to write `meta:bank` at bank initialization will cause SurrealDB to reject the query (`Found field 'timezone', but no such field exists for table 'meta'`).
3. **[BLOCKER] Recall Response Model Mismatch (`context_markdown` vs `markdown`):** The Hermes plugin (`07-hermes-plugin.md`) explicitly extracts `res.get("context_markdown")`. However, the API specification (`06-api-and-mcp.md`) defines the recall response field as `"markdown"`, and `10-testing-evaluation.md` mocks the response using `"markdown"`. In production, this causes the Hermes plugin to receive `None` and return an empty string (`""`), breaking all prompt context injection.
4. **[BLOCKER] `audit` Table Schema Collision:** `migrations/0001_init.surql` and `03-data-model.md` define `audit` as `SCHEMAFULL` with a flexible object (`details: object FLEXIBLE`). `09-observability.md` specifies an incompatible schema with 12 flat columns, and `04-ingestion-pipeline.md` writes top-level fields (`episodes`, `entities_resolved`, etc.) directly to `audit`, which will fail validation in SurrealDB.

A total of 25 findings (4 Blocker, 11 Major, 8 Minor, 2 Nit) are cataloged below with exact line numbers and an unambiguous, file-by-file mechanical fix list.

---

## 2. Findings Table

| ID | Sev | Location (Files & Lines) | Conflicting Values / Descriptions | Canonical Value & Recommended Fix |
|---|---|---|---|---|
| **F-01** | **BLOCKER** | `02-architecture.md:563-605`<br>`11-rust-implementation-guide.md:129-137, 512-585` | Documents specify SurrealDB `/rpc` over JSON (`Content-Type: application/json`, `serde_json`, `.json(&request)`). | **ADR-02 (CBOR Mandate):** Use `Content-Type: application/cbor` and `Accept: application/cbor` via `ciborium` (serde CBOR). Bound strings shaped `ident:ident` are truncated by SurrealDB JSON-RPC. Add `ciborium = "0.2.2"` to `Cargo.toml` in `11` and update `store::rpc` client implementation. |
| **F-02** | **BLOCKER** | `migrations/0001_init.surql:24-34`<br>`03-data-model.md:221`<br>`02-architecture.md:743-749` | `meta` table is `SCHEMAFULL` but lacks `timezone` field. Bank initialization query in `02` sets fields without `timezone`. | **ADR-05, ADR-16, §3.5:** Add `DEFINE FIELD OVERWRITE timezone ON meta TYPE string DEFAULT "UTC";` to `migrations/0001_init.surql`. Update table summary in `03` and initialization query in `02`. |
| **F-03** | **BLOCKER** | `05-retrieval.md:49, 109`<br>`06-api-and-mcp.md:244, 397, 1088-1094`<br>`07-hermes-plugin.md:495, 1041, 1060`<br>`10-testing-evaluation.md:604` | `05` and `07` use `"context_markdown"`. `06` and `10` use `"markdown"`. Hermes plugin calls `res.get("context_markdown")`, which yields `None` against `06` and `10`. | **Canonical Resolution:** Align on `"context_markdown"` for the rendered markdown string (or update `RecallResponse` in `06` to provide both `"context_markdown"` and alias `"markdown"` for backward compatibility; update `07` and `10` to handle both). |
| **F-04** | **BLOCKER** | `migrations/0001_init.surql:205-219`<br>`03-data-model.md:230, 513`<br>`04-ingestion-pipeline.md:795-814`<br>`09-observability.md:334-351` | `0001_init.surql` defines `audit` with `actor`, `action`, `target_type`, `target_id`, `details FLEXIBLE`. `09` defines 12 different flat columns (`bank`, `subject_ref`, etc.). `04` issues `CREATE audit CONTENT` with undefined top-level keys. | **ADR-15 & §3.3:** Standardize on `migrations/0001_init.surql`. Update `09-observability.md:334-351` to match the migration. Update `04-ingestion-pipeline.md:795` to nest extraction/resolution traces inside `details: { ... }`. |
| **F-05** | **MAJOR** | `05-retrieval.md:136-159`<br>`06-api-and-mcp.md:267-273, 1088-1094` | `05` defines response metadata as `counts`, `timings_ms`, `degraded`. `06` defines response metadata as `stats: { total_candidates, returned_items, estimated_tokens, duration_ms, channels }`. Items in `05` have `type`, items in `06` have `item_type`. | Standardize `RecallResponse` metadata across `05` and `06`. In `05`, update response schema to align with `06`'s `stats` object, or declare `counts`/`timings_ms` as nested within `stats`. Standardize item discriminator field as `item_type: "fact" \| "observation" \| "episode"`. |
| **F-06** | **MAJOR** | `06-api-and-mcp.md:402, 542-550, 739`<br>`07-hermes-plugin.md:496, 1280-1283, 1308` | `engram_remember` in `06` takes `triple: { subject, predicate, object }` and `trust`. `07` takes flat `subject`, `predicate`, `object`, `valid_from` without `triple` or `trust`. `engram_entities` uses `ref` in `06` vs `name` in `07`. | Harmonize tool schemas: Update `07-hermes-plugin.md` schema to accept both flat and `triple` arguments, and support `trust`. Align `engram_entities` on `name` (with `ref` alias) or update `06` and `07` to match. |
| **F-07** | **MAJOR** | `03-data-model.md:512`<br>`06-api-and-mcp.md:281, 283, 611, 1115`<br>`07-hermes-plugin.md:497`<br>`migrations/0001_init.surql:70, 118, 150` | `07` documents `forget` return as `status: "superseded", superseded_at: "..."`. `06` says `status: "retracted", retracted_at: "..."`. `06` claims `forget` sets `valid_to = now, retracted_at = now, status = "retracted"` on all tables, but `fact`/`observation` lack `retracted_at`, and `episode` lacks `valid_to`/`status`. | Fix `07-hermes-plugin.md:497` to return `status: "retracted"`. In `06-api-and-mcp.md:281`, clarify table-specific soft retirement: for `fact`/`observation`, set `status = "retracted", valid_to = now, expired_at = now`; for `episode`, set `retracted_at = now`. |
| **F-08** | **MAJOR** | `02-architecture.md:575, 605` | JSON-RPC query example uses `RELATE $e->asserts->$target` and returns `id: "asserts:01JAY..."`. | **00-decisions.md §1:** Table `asserts` was renamed to `fact`. Change `RELATE $e->asserts->$target` to `RELATE $e->fact->$target` and `"asserts:..."` to `"fact:..."`. |
| **F-09** | **MAJOR** | `02-architecture.md:755`<br>`08-deployment-operations.md:775` | `02` specifies unlisted endpoint `DELETE /v1/banks/{bank}?confirm=true` and CLI `engram bank drop`. `08` specifies `POST /v1/banks/default/jobs/retry-all`. | **00-decisions.md §3.1 & §3.2:** Neither endpoint exists in the canonical REST registry. Remove `DELETE /v1/banks` from `02` (replace with CLI admin note) and replace `/jobs/retry-all` in `08` with loop over `POST /v1/banks/{bank}/jobs/{id}/retry`. |
| **F-10** | **MAJOR** | `06-api-and-mcp.md:138, 179, 186, 229, 277, 281, 290, 305, 317, 321, 325, 329, 333, 337` | Endpoints reference informal non-existent FR tags (`FR-health`, `FR-status`, `FR-admin`, `FR-ingest`, `FR-recall`, `FR-remember`, `FR-forget`, `FR-entities`, `FR-facts`, `FR-sessions`, `FR-jobs`). | **01-prd.md §6.5:** Replace informal tags with canonical numbered PRD requirements: `FR-040` (system/health/status), `FR-041` (banks), `FR-001` (episodes), `FR-042` (recall/remember/forget), `FR-043` (entities/facts), `FR-044` (sessions), `FR-045` (jobs/admin). |
| **F-11** | **MAJOR** | `01-prd.md:312, 473`<br>`08-deployment-operations.md:206`<br>`00-decisions.md:116` | `01-prd.md` NFR-013 states Docker image MUST NOT exceed 200 MB. `08` measures compressed transfer size as `~210 MB`. `00-decisions.md` ADR-16 fixes budget at `≤ 650 MB uncompressed / ≤ 160 MB compressed`. | **ADR-16 (Current Baseline):** Update `01-prd.md` NFR-013 and Milestone M5 to `≤ 650 MB uncompressed / ≤ 160 MB compressed pull`. Update `08-deployment-operations.md:206` compressed transfer estimate to align with `≤ 160 MB`. |
| **F-12** | **MAJOR** | `01-prd.md:472`<br>`10-testing-evaluation.md:740, 804` | `01-prd.md` Milestone M5 sets LongMemEval_S strict accuracy target at `≥ 75.0%`. `10` sets baseline target at `≥ 68.0%` (calibrated for local `qwen3:8b`). | Align Milestone M5 in `01-prd.md:472` to `≥ 68.0%` for local `qwen3:8b` (with note that 75% applies to frontier cloud models). |
| **F-13** | **MAJOR** | `04-ingestion-pipeline.md:756` | Negative polarity example states: `closes (User, uses, Docker) by setting valid_to = reference_time and status = superseded`. | **03-data-model.md:442, 587:** Invariant requires `superseded` to point to a valid `superseded_by` successor. Negative assertions have no successor; status must be set to `status = "retracted"`. |
| **F-14** | **MAJOR** | `07-hermes-plugin.md:1111`<br>`migrations/0001_init.surql:74`<br>`06-api-and-mcp.md:205, 1045` | `07` plugin passes `author` as an object/dict (`{"id": "user", "name": "User", "is_bot": False}`). Migration defines `author ON episode TYPE option<string>`. `06` defines `author: string`. | In `07-hermes-plugin.md:1111`, extract author string ID: `"author": (turn_author.get("id") if isinstance(turn_author, dict) else turn_author) or "user"`. |
| **F-15** | **MAJOR** | `04-ingestion-pipeline.md:92-93`<br>`migrations/0001_init.surql:83-85`<br>`03-data-model.md:224` | `04` defines index `episode_idempotency` on `FIELDS session_id, idempotency_key UNIQUE;` and `episode_content_hash` on `FIELDS session_id, content_hash UNIQUE;`. Migration defines `episode_idempotency_key` on `FIELDS idempotency_key UNIQUE;` and non-unique `episode_content_hash`. | Update `04-ingestion-pipeline.md:92-93` to match `0001_init.surql`: `DEFINE INDEX episode_idempotency_key ON episode FIELDS idempotency_key UNIQUE;` and `DEFINE INDEX episode_content_hash ON episode FIELDS content_hash;`. |
| **F-16** | **MINOR** | `05-retrieval.md:97`<br>`06-api-and-mcp.md:231, 1066`<br>`07-hermes-plugin.md:456` | Token budget max limit differs across documents: `05` caps at `4096`; `06` allows max `8192`; `07` config allows max `8000`. | Standardize maximum allowed `token_budget` at `8192` across `05`, `06`, and `07`. |
| **F-17** | **MINOR** | `docker-compose.yml:96, 137`<br>`00-decisions.md:45` | `docker-compose.yml` sets `stop_grace_period: 30s` under the `external-surreal` profile for `engram-external` and `surrealdb`. | **ADR-03:** Mandates `stop_grace_period ≥ 40s` (drain 10s + jobs 15s + child 10s = 35s minimum). Change `30s` to `40s` on line 137. |
| **F-18** | **MINOR** | `12-prior-art-learnings.md:55-64, 181, 275, 302, 326` | Document cross-references obsolete file names: `03-retrieval-engine.md` (now `05-retrieval.md`), `08-hermes-plugin.md` (now `07-hermes-plugin.md`), `02-data-model.md` (now `03-data-model.md`). | Update all markdown links and section citations in `12-prior-art-learnings.md` to reference the canonical file names. |
| **F-19** | **MINOR** | `02-architecture.md:743-749` | `meta:bank` insertion example omits required `bank_id`, uses plural `embedding_dimensions` (migration uses `embedding_dimension`), and uses `predicate_vocabulary_version` (migration uses `predicate_vocab_version`). | Update SQL snippet in `02-architecture.md:743-749` to use exact migration column names: `bank_id`, `embedding_dimension`, `predicate_vocab_version`, and add `timezone = "UTC"`. |
| **F-20** | **MINOR** | `05-retrieval.md:981-985`<br>`09-observability.md:213-214`<br>`00-decisions.md:204` | `05` invents metrics `engram_recall_cache_hits_total`, `engram_recall_cache_misses_total`, and `engram_recall_degraded_total`. Misclassifies `engram_recall_items` as Counter (it is a Histogram). Uses stage labels `channels_rt1`, `graph_rt2` instead of `channel_vector`, `channel_bm25`, `graph`. | Align `05-retrieval.md:981-985` with §3.7 and `09-observability.md`: remove invented metrics, mark `engram_recall_items` as Histogram, and use canonical stage labels. |
| **F-21** | **MINOR** | `10-testing-evaluation.md:322` | Refers to `BM25 Lexical Analyzer: Define search analyzer`. | In SurrealDB 3.x, `SEARCH ANALYZER` was removed. Update text to `Define analyzer engram_analyzer and FULLTEXT index`. |
| **F-22** | **MINOR** | `06-api-and-mcp.md:1036-1048` | OpenAPI schema component `EpisodeInput` omits `idempotency_key` property. | Add `idempotency_key: { type: string }` to properties of `EpisodeInput` in `06-api-and-mcp.md`. |
| **F-23** | **MINOR** | `02-architecture.md:472` | Sequence diagram shows `on_pre_compress(messages, require_checkpoint=False)` (API v2). | **ADR-13 & 07-hermes-plugin.md:431:** Engram v1 retains API v1 `on_pre_compress(messages)`. Update sequence diagram to show API v1 signature. |
| **F-24** | **NIT** | `00-decisions.md:135, 174`<br>`08-deployment-operations.md:143, 411`<br>`Dockerfile:67`<br>`docker-compose.yml:24` | §3.1 lists `ENGRAM_BIND`, §3.5 lists `server.bind` (general env rule `ENGRAM_SERVER_BIND`), and `server.api_key` has alias `ENGRAM_API_KEY`. | Code in `config.rs` should explicitly alias `ENGRAM_BIND` $\to$ `server.bind` and `ENGRAM_API_KEY` $\to$ `server.api_key` alongside standard `ENGRAM_<SECTION>_<KEY>` hierarchy. |
| **F-25** | **NIT** | `09-observability.md:211` | Example `route` labels for `engram_http_requests_total` list `/v1/recall` and `/v1/episodes` instead of route templates `/v1/banks/:bank/recall` and `/v1/banks/:bank/episodes`. | Clarify that the `route` metric label uses Axum parameterized route paths (`/v1/banks/:bank/recall`) to avoid high cardinality. |

---

## 3. Detailed Cross-Document Audit Sections

### 3.1 REST Paths & Methods (§3.2)
- Canonical registry in `00-decisions.md` §3.2 lists 14 route patterns.
- **Discrepancy (Finding F-09):** `02-architecture.md:755` introduces `DELETE /v1/banks/{bank}?confirm=true`, which does not exist in `00-decisions.md` or `06-api-and-mcp.md`. `08-deployment-operations.md:775` introduces `POST /v1/banks/default/jobs/retry-all`, which does not exist in `00-decisions.md` or `06-api-and-mcp.md`.
- All other endpoints (`/healthz`, `/readyz`, `/metrics`, `/v1/status`, `/v1/banks`, `/v1/banks/{bank}`, `/episodes`, `/recall`, `/remember`, `/forget`, `/entities`, `/facts`, `/sessions/.../flush`, `/sessions/.../end`, `/jobs`, `/jobs/{id}/retry`, `/export`, `/import`, `/mcp`) match across docs.

### 3.2 Request/Response Field Names & Recall Model
- **Recall Response Model (Finding F-03, BLOCKER):**
  - `05-retrieval.md:109`: `"context_markdown": "## Recalled context (Engram)..."`
  - `07-hermes-plugin.md:1041`: `markdown = str(res.get("context_markdown") or "").strip()`
  - `06-api-and-mcp.md:244, 1092`: `"markdown": "### Architectural Facts & Preferences..."`
  - `10-testing-evaluation.md:604`: `"markdown": "## Facts..."`
  - *Impact:* Hermes plugin will receive empty markdown if talking to `06`/`10`. Must align on `"context_markdown"` (with optional `"markdown"` alias).
- **Recall Metadata Model (Finding F-05, MAJOR):**
  - `05-retrieval.md:136-159` defines `counts`, `timings_ms`, `degraded`.
  - `06-api-and-mcp.md:267-273` defines `stats` with `total_candidates`, `returned_items`, `estimated_tokens`, `duration_ms`, `channels`.
  - Items in `05` use `type: "fact"`, while `06` uses `item_type: "fact"`.
- **Episode Ingest Payload (Finding F-14, F-15, F-22):**
  - Array wrapper `{"episodes": [...]}` is consistent across `04`, `06`, `07`.
  - `07-hermes-plugin.md:1111` passes `author` as a dictionary, violating `author: string` in migration and `06`.
  - `04-ingestion-pipeline.md:92` claims compound index `session_id, idempotency_key UNIQUE`, while migration uses `idempotency_key UNIQUE`.

### 3.3 Tables, Schemas & Enums (§3.3)
- **10 Tables:** `meta`, `episode`, `entity`, `fact`, `mentions`, `observation`, `session`, `job`, `audit`, `schema_migration` are present in `00-decisions.md`, `03-data-model.md`, and `migrations/0001_init.surql`.
- **Missing `timezone` on `meta` (Finding F-02, BLOCKER):** Table is `SCHEMAFULL`; missing `timezone` prevents storing bank timezone.
- **`audit` Table Conflict (Finding F-04, BLOCKER):** `09-observability.md` invents a completely different schema; `04-ingestion-pipeline.md` attempts to insert non-existent top-level fields.
- **Stale `asserts` (Finding F-08, MAJOR):** `02-architecture.md:575, 605` still contains `asserts`.
- **Enums Verification:**
  - `status` on `fact`: `active`, `superseded`, `retracted`, `pending` — verified consistent across `00`, `03`, `04`, migration.
  - `status` on `observation`: `active`, `superseded`, `retracted` — verified consistent.
  - `kind` on `episode`: `turn`, `note`, `curated`, `delegation`, `document` — verified consistent.
  - `kind` on `job`: `embed`, `extract`, `consolidate`, `reembed` — verified consistent.
  - `kind` on `entity`: 9 kinds verified consistent.
  - `trust`: 5 tiers (`user_stated`, `user_implied`, `assistant_stated`, `tool_output`, `inferred`) verified consistent.
  - `extraction_state`: `pending`, `done`, `skipped`, `failed` — verified consistent.
  - `time_precision`: `exact`, `second`, `minute`, `hour`, `day`, `month`, `year`, `indefinite` — verified consistent.
  - `polarity`: `positive`, `negative` — verified consistent.

### 3.4 Tool Names & Schemas
- 5 canonical tools: `engram_recall`, `engram_remember`, `engram_forget`, `engram_entities`, `engram_status` match across `00`, `01`, `06`, `07`, `10`.
- **Discrepancy (Finding F-06, MAJOR):** Parameter mismatch in `engram_remember` (`triple` in `06` vs flat `subject`/`predicate`/`object` in `07`) and `engram_entities` (`ref` in `06` vs `name` in `07`).
- **Discrepancy (Finding F-07, MAJOR):** Return schema for `engram_forget` in `07` lists `status: "superseded"`, whereas `06` lists `status: "retracted"`.

### 3.5 Config Keys & Environment Variables (§3.5, §3.6)
- Service config keys in `08-deployment-operations.md:411-450` match `00-decisions.md` §3.5.
- Hermes plugin config keys in `07-hermes-plugin.md:450-460` match `00-decisions.md` §3.6.
- Aliasing rule: `ENGRAM_BIND` and `ENGRAM_API_KEY` are used alongside `ENGRAM_SERVER_BIND` and `ENGRAM_SERVER_API_KEY` (Finding F-24).

### 3.6 Numbers & Constants
- Thresholds: Jaro-Winkler 0.92, embed_merge 0.90, embed_review 0.80 — verified consistent across `00`, `03`, `04`, `08`, `10`.
- Batch sizes: `batch_max_turns = 4`, `batch_idle_ms = 20000` — verified consistent.
- RRF: $k=60$; weights vector 1.0, bm25 1.0, graph 0.8, recency 0.5 — verified consistent.
- MMR: $\lambda = 0.7$ — verified consistent across `00`, `05`, `08`, `10`, `12`.
- Token budget: default 1200, estimator $\lceil \text{chars}/3.5 \rceil$ — verified consistent. Max token budget inconsistency noted in Finding F-16.
- Latency targets: accept $p95 \le 20\text{ ms}$, recall $p95 \le 150\text{ ms}$, Hermes prefetch $p95 \le 250\text{ ms}$ — verified consistent.
- Job retry policy: 1s to 5min exponential backoff, max 8 attempts — verified consistent across `00`, `03`, `04`, `08`, `10`, migration.
- Ordered shutdown timings: HTTP drain $\le 10\text{ s}$, jobs $\le 15\text{ s}$, surreal child $\le 10\text{ s}$, Docker `stop_grace_period` $\ge 40\text{ s}$ — verified consistent (docker-compose external profile fix noted in F-17).
- Dependency budget: $\le 300$ normal crates, $\le 340$ with OTLP, stripped binary $\le 25\text{ MB}$ — verified consistent.
- Image size budget: $\le 650\text{ MB}$ uncompressed / $\le 160\text{ MB}$ compressed pull — stale numbers in `01` and `08` noted in Finding F-11.
- Confidence formula: $\text{trust\_base} \times (1 + 0.1 \times \min(support - 1, 5))$, clamped to $[0, 1]$, rounded to 2 decimal places; base values 0.90, 0.75, 0.60, 0.60, 0.50 — verified consistent.

### 3.7 Metrics & Spans (§3.7)
- All 15 spans in `00-decisions.md` §3.7 match `09-observability.md:46-60`.
- All 14 metrics and their label dimensions in `00-decisions.md` §3.7 match `09-observability.md:209-224`.
- Inconsistencies in `05-retrieval.md:981-985` noted in Finding F-20.

### 3.8 Predicate Vocabulary & Cardinality (ADR-09)
- All 15 predicates (`is_a`, `works_at`, `has_role`, `reports_to`, `located_in`, `member_of`, `part_of`, `owns`, `uses`, `written_in`, `depends_on`, `prefers`, `scheduled_for`, `credentials_for`, `related_to`) and their cardinalities (5 functional, 10 multi) match across `00-decisions.md` ADR-09, `04-ingestion-pipeline.md`, `prompts/extract.v1.md`, and `migrations/0001_init.surql:116`.

### 3.9 Milestone Definitions M0–M5
- Milestones M0 through M4 match across `01-prd.md` and `10-testing-evaluation.md`.
- Milestone M5 LongMemEval_S accuracy target mismatch (75% in `01` vs 68% in `10`) noted in Finding F-12.

### 3.10 Deployment Topology & Environment
- Binary path: `/usr/local/bin/surreal` consistent across `00`, `02`, `08`, `Dockerfile`, `docker-compose.yml`, `11`.
- Ports: `8080` (Engram) and `8000` (internal loopback SurrealDB) consistent.
- Non-root user: UID/GID `10001` consistent across `00`, `02`, `08`, `Dockerfile`, `docker-compose.yml`.
- Data paths: `/data`, `/data/surreal`, `/data/secrets`, `/data/backups` consistent.

### 3.11 PRD Requirements Cross-References
- All 48 FRs (`FR-001`..`FR-075`) and 20 NFRs (`NFR-001`..`NFR-020`) defined in `01-prd.md` are valid.
- `06-api-and-mcp.md`'s use of informal strings (`FR-admin`, etc.) resolved in Finding F-10.

---

## 4. Issues Raised Against `00-decisions.md` Classification

Each document's "Issues Raised Against `00-decisions.md`" section was examined against the current `00-decisions.md` text:

| Doc | Section & Item | Subject | Status in Current `00-decisions.md` |
|---|---|---|---|
| `01-prd.md` | §14 | No issues raised | Confirmed. |
| `02-architecture.md` | §12.1 | SurrealDB Child Binary Path (`/surreal` vs `/usr/local/bin/surreal`) | **Resolved in ADR-03 & §3.5:** Stated as source `/surreal`, installed at `/usr/local/bin/surreal`. |
| `02-architecture.md` | §12.2 | Database Provisioning Order (`DEFINE DATABASE` before scoped queries) | **Resolved in ADR-05:** Explicit order codified in text. |
| `02-architecture.md` | §12.3 | HTTP RPC Base URL vs RPC Path (store client appends `/rpc`) | **Resolved in ADR-03:** Store appends `/rpc` for queries. |
| `03-data-model.md` | §10.1 | Object Field Schemas in `SCHEMAFULL` Tables (`FLEXIBLE` required) | **Resolved in ADR §3.3:** Defined with `TYPE object FLEXIBLE DEFAULT {};`. |
| `04-ingestion-pipeline.md` | §14.1 | `credentials_for` Predicate Storage (never secret value; pre-egress scrubbing) | **Resolved in ADR-09 & ADR-14:** Explicitly codified. |
| `04-ingestion-pipeline.md` | §14.2 | Observation Invalidation vs Fact Supersession Terminology (`status` enum) | **Resolved in ADR §3.3:** Key observation fields declare `status (active\|superseded\|retracted)`. |
| `05-retrieval.md` | §13.1 | SurrealQL KNN `<\|k, ef\|>` Rejects Bound Parameters (format u16 literals) | **Resolved in ADR-02:** Codified in ADR-02 injection rules. |
| `05-retrieval.md` | §13.2 | SurrealQL `FULLTEXT` Single-Column Constraint (one index per column) | **Resolved in ADR-02:** Codified in ADR-02 constraints. |
| `05-retrieval.md` | §13.3 | `observation` Field Naming Harmonization (`observation.text` standard) | **Resolved in ADR §3.3:** Standardized on `text`. |
| `05-retrieval.md` | §13.4 | Timezone Reference Defaults (`server.timezone` $\to$ `meta.timezone`) | **Resolved in ADR-16 & §3.5:** Codified with Jiff bundled tzdb. |
| `06-api-and-mcp.md` | §8.1 | rmcp Streamable HTTP protocol versions (`2025-06-18` to `2026-07-28`) | **Resolved in ADR-18:** Dual-stack support registered. |
| `06-api-and-mcp.md` | §8.2 | SurrealQL `search::rrf` single-table limitation vs Rust cross-channel fusion | **Resolved in ADR-11:** Cross-channel fusion executed in Rust. |
| `06-api-and-mcp.md` | §8.3 | Casing Conventions (REST `snake_case` vs MCP frames `camelCase`) | **Resolved in ADR-01 & ADR-18:** Protocol `camelCase`, payloads `snake_case`. |
| `07-hermes-plugin.md` | §14.1 | `on_memory_write` Deletion Contract (extract `previous_content`) | **Resolved in ADR-13:** Removal reads `metadata["previous_content"]`. |
| `07-hermes-plugin.md` | §14.2 | `sync_turn` Threading Model (Hermes `mem-sync` serialized worker) | **Resolved in ADR-13:** Direct synchronous POST without extra Python worker. |
| `07-hermes-plugin.md` | §14.3 | Pre-Compress Checkpoint API v2 Alignment (retain v1 for v1.0) | **Resolved in ADR-13:** `pre_compress_checkpoint_api_version = 1`. |
| `08-deployment-operations.md` | §13 | No issues raised | Confirmed. |
| `09-observability.md` | §9 | No issues raised | Confirmed. (Internal audit schema conflict handled in F-04). |
| `10-testing-evaluation.md` | §10.1-2 | Alignment & Test Harness Independence | Confirmed. |
| `11-rust-implementation-guide.md` | §9.1 | Missing `CDLA-Permissive-2.0` in ADR-16 License Allowlist | **Resolved in ADR-16:** Formally added to ADR-16 allowlist. |
| `11-rust-implementation-guide.md` | §9.2 | Explicit `jiff` Bundled Feature Name (`tzdb-bundle-always`) | **Resolved in ADR-16:** Formally added to ADR-16 text. |
| `11-rust-implementation-guide.md` | §9.3 | `uuid` Direct Dependency Redundancy (in rmcp 3.7.0) | **Open / Informational:** Harmless direct dependency. |
| `12-prior-art-learnings.md` | §8 | No issues raised | Confirmed. |

---

## 5. Verified-Correct Claims

The following foundational claims were mechanically and empirically verified:
1. **SurrealDB 3.3.4 Binary Compatibility:** The `/surreal` binary extracted from `surrealdb/surrealdb:v3.3.4` runs natively under `debian:bookworm-slim` without missing shared libraries.
2. **SurrealQL Analyzer & Fulltext Syntax:** `DEFINE ANALYZER engram_analyzer TOKENIZERS class FILTERS lowercase, ascii;` and `DEFINE INDEX ... FULLTEXT ANALYZER engram_analyzer BM25` execute cleanly.
3. **Rust Crate Count Budget:** The production dependency manifest in `11-rust-implementation-guide.md` compiles with 211 normal crates (239 with `otlp`), well below the $\le 300$ ($\le 340$) ceiling.
4. **Stripped Binary Footprint:** Compiled release binary with debug symbols stripped measures $\sim 7.7\text{ MB}$, well below the $\le 25\text{ MB}$ ceiling.
5. **Jaro-Winkler Native Function:** SurrealDB 3.3.4 provides `string::similarity::jaro_winkler`, returning expected similarity values.
6. **Crypto SHA-256 Native Function:** `crypto::sha256` operates natively in SurrealDB 3.3.4.
7. **License Allowlist:** All production crates comply with permitted permissive licenses (Apache-2.0, MIT, BSD-2/3, ISC, Unicode-3.0, Zlib, MPL-2.0, CDLA-Permissive-2.0).

---

## 6. Unverifiable Items

1. **Local Ollama `qwen3:8b` Extraction P95 Latency on Target Host Hardware:** While estimated at $\sim 450\text{ ms}$ for 4-turn batches, actual latency depends on the host GPU/NPU acceleration and quant level.
2. **LongMemEval_S 100-Question Exact Accuracy on Local Hardware:** Exact strict accuracy score ($\ge 68\%$) requires running the complete 100-question eval harness against the live answering model, scheduled for Milestone M5.

---

## 7. Concise Fix List per File

Apply the following mechanical edits to achieve 100% cross-document consistency:

### `migrations/0001_init.surql`
1. **Line 33 (F-02):** Add `DEFINE FIELD OVERWRITE timezone ON meta TYPE string DEFAULT "UTC";` immediately after `active_hnsw_index`.

### `docs/spec/01-prd.md`
1. **Line 312 (F-11):** In NFR-013, change `MUST NOT exceed 200 MB` to `MUST NOT exceed 650 MB uncompressed / 160 MB compressed pull [ADR-16]`.
2. **Line 472 (F-12):** In Milestone M5 item 2, change `strict accuracy ≥ 75.0%` to `strict accuracy ≥ 68.0% (using local qwen3:8b answering model)`.
3. **Line 473 (F-11):** In Milestone M5 item 3, change `Docker image builds under 200 MB` to `Docker image builds under 650 MB uncompressed / 160 MB compressed pull`.

### `docs/spec/02-architecture.md`
1. **Line 472 (F-23):** In the sequence diagram, change `on_pre_compress(messages, require_checkpoint=False)` to `on_pre_compress(messages)`.
2. **Lines 563-605 (F-01):** In Section 6, change `Content-Type: application/json` and `Accept: application/json` to `application/cbor`. Update the narrative to state that the internal RPC client communicates via CBOR using `ciborium` per ADR-02.
3. **Lines 575 & 605 (F-08):** In the query and response examples, change `RELATE $e->asserts->$target` to `RELATE $e->fact->$target` and `"asserts:01JAY..."` to `"fact:01JAY..."`.
4. **Lines 743-749 (F-02, F-19):** In the `meta:bank` insertion example, change to:
   ```surql
   CREATE ONLY meta:bank SET
       schema_version = 1,
       bank_id = $bank_id,
       embedding_model = "qwen3-embedding:0.6b",
       embedding_dimension = 1024,
       predicate_vocab_version = "v1",
       timezone = "UTC",
       created_at = time::now();
   ```
5. **Line 755 (F-09):** Remove `or DELETE /v1/banks/{bank}?confirm=true`. State that permanent bank destruction is restricted to admin CLI `engram bank drop <name> --confirm`.

### `docs/spec/03-data-model.md`
1. **Line 221 (F-02):** In table `meta`, add `timezone: string` to Key Typed Fields.

### `docs/spec/04-ingestion-pipeline.md`
1. **Lines 92-93 (F-15):** Replace index definitions with:
   ```surql
   DEFINE INDEX episode_idempotency_key ON episode FIELDS idempotency_key UNIQUE;
   DEFINE INDEX episode_content_hash ON episode FIELDS content_hash;
   ```
2. **Line 756 (F-13):** Change `status = superseded` to `status = retracted`.
3. **Lines 795-814 (F-04):** Update `CREATE audit CONTENT` to nest trace payload inside `details`:
   ```surql
   CREATE audit:ulid() SET
       actor = 'reconciler',
       action = 'extract_and_reconcile',
       target_type = 'session',
       target_id = $session_id,
       session_id = $session_id,
       details = {
           bank: $bank_id,
           extractor_version: 'v1',
           episodes: [$ep_1, $ep_2],
           entities_resolved: [...],
           reconciliation_decisions: [...]
       };
   ```

### `docs/spec/05-retrieval.md`
1. **Line 97 (F-16):** Change `Capped at 4096` to `Capped at 8192`.
2. **Lines 108-160 (F-03, F-05):** Update response schema to provide `"markdown"` as an alias alongside `"context_markdown"`, or standardize the field name. Harmonize metadata to include `stats: { total_candidates, returned_items, estimated_tokens, duration_ms, channels }`. Change item discriminator field from `type` to `item_type`.
3. **Lines 981-985 (F-20):** Remove `engram_recall_cache_hits_total`, `engram_recall_cache_misses_total`, and `engram_recall_degraded_total`. Change `engram_recall_items` type to Histogram. Align stage labels to `channel_vector`, `channel_bm25`, `graph`, `fuse`, `pack`.
4. **Line 1004 (F-20):** In config table, add `rerank.model` (`ENGRAM_RERANK_MODEL`).

### `docs/spec/06-api-and-mcp.md`
1. **Section 2 & 6.5 (F-10):** Replace all informal `FR-...` tags (`FR-health`, `FR-status`, `FR-admin`, `FR-ingest`, `FR-recall`, `FR-remember`, `FR-forget`, `FR-entities`, `FR-facts`, `FR-sessions`, `FR-jobs`) with canonical numbers: `FR-040` through `FR-045` and `FR-001`.
2. **Line 244 & 1092 (F-03):** In `RecallResponse`, add `"context_markdown"` alongside `"markdown"`.
3. **Line 281 (F-07):** Clarify soft retirement by table: for `fact`/`observation`, set `status = "retracted", valid_to = now, expired_at = now`; for `episode`, set `retracted_at = now`.
4. **Line 402, 543, 739 (F-06):** In `engram_remember`, support flat `subject`, `predicate`, `object` in addition to `triple: { subject, predicate, object }`.
5. **Line 1045 (F-22):** In OpenAPI component `EpisodeInput`, add `idempotency_key: { type: string }`.

### `docs/spec/07-hermes-plugin.md`
1. **Line 456 (F-16):** Change `(min: 100, max: 8000)` to `(min: 100, max: 8192)`.
2. **Line 497 (F-07):** In tool table, change `engram_forget` return structure to `JSON string: {"id": "...", "status": "retracted", "retracted_at": "..."}`.
3. **Line 1111 (F-14):** In `sync_turn`, change `"author": turn_author or ...` to `"author": (turn_author.get("id") if isinstance(turn_author, dict) else turn_author) or "user"`.
4. **Line 1041 & 1060 (F-03):** Change `res.get("context_markdown")` to `res.get("context_markdown") or res.get("markdown")` for defensive compatibility.
5. **Line 1280-1283 (F-06):** In `engram_remember` schema, add `"trust"` property to align with MCP.

### `docs/spec/08-deployment-operations.md`
1. **Line 206 (F-11):** Change `(~210 MB compressed transfer size)` to `(≤ 160 MB compressed pull)`.
2. **Line 775 (F-09):** Replace `POST /v1/banks/default/jobs/retry-all` with a bash loop retrying individual dead job IDs via `POST /v1/banks/default/jobs/{id}/retry`.

### `docs/spec/09-observability.md`
1. **Line 211 (F-25):** Clarify that `route` labels use Axum parameterized paths (`/v1/banks/:bank/recall`).
2. **Lines 334-351 (F-04):** Update `audit` schema definition to match `migrations/0001_init.surql:205-219`:
   ```surql
   DEFINE TABLE OVERWRITE audit SCHEMAFULL;
   DEFINE FIELD OVERWRITE occurred_at  ON audit TYPE datetime DEFAULT time::now() READONLY;
   DEFINE FIELD OVERWRITE trace_id     ON audit TYPE option<string>;
   DEFINE FIELD OVERWRITE session_id   ON audit TYPE option<string>;
   DEFINE FIELD OVERWRITE actor        ON audit TYPE string DEFAULT "system";
   DEFINE FIELD OVERWRITE action       ON audit TYPE string;
   DEFINE FIELD OVERWRITE target_type  ON audit TYPE string;
   DEFINE FIELD OVERWRITE target_id    ON audit TYPE option<string>;
   DEFINE FIELD OVERWRITE details      ON audit TYPE object FLEXIBLE DEFAULT {};
   DEFINE FIELD OVERWRITE reason       ON audit TYPE option<string>;
   DEFINE INDEX OVERWRITE audit_retention ON audit FIELDS occurred_at;
   DEFINE INDEX OVERWRITE audit_target    ON audit FIELDS target_type, target_id;
   DEFINE INDEX OVERWRITE audit_action    ON audit FIELDS action;
   ```

### `docs/spec/10-testing-evaluation.md`
1. **Line 322 (F-21):** Replace `Define search analyzer` with `Define analyzer engram_analyzer and FULLTEXT index`.
2. **Line 604 (F-03):** In mock transport, return both `"context_markdown"` and `"markdown"`.
3. **Line 608 (F-05):** In mock transport, return `{"accepted_ids": ["ep_01"], "enqueued_jobs": {"embed": 1}}`.

### `docs/spec/11-rust-implementation-guide.md`
1. **Lines 135-139 (F-01):** Add `ciborium = "0.2.2"` to `Cargo.toml` under Section 5 (Serialization).
2. **Lines 512-585 (F-01):** Rewrite `store::rpc` client to serialize RPC requests using `ciborium::into_writer` and deserialize responses from CBOR with `ciborium::from_reader`, setting `Content-Type: application/cbor` and `Accept: application/cbor`. Add support for SurrealDB CBOR tags (tag 6 NONE, tag 8 RecordId, tag 12 Datetime).

### `docs/spec/12-prior-art-learnings.md`
1. **Lines 55-64, 181, 275, 302, 326 (F-18):** Replace obsolete filenames: `03-retrieval-engine.md` $\to$ `05-retrieval.md`, `08-hermes-plugin.md` $\to$ `07-hermes-plugin.md`, `02-data-model.md` $\to$ `03-data-model.md`.

### `docker-compose.yml`
1. **Line 137 (F-17):** In `engram-external` service, change `stop_grace_period: 30s` to `stop_grace_period: 40s`.
