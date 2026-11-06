# Engram Specification Package — Cross-Document Consistency Re-Audit (VS1b)

**Audit Date:** 2026-10-25  
**Auditor:** Principal Verification Engineer (Independent Skeptical Audit — Round 2)  
**Target:** Engram v1 Complete Specification Package (`docs/spec/00-decisions.md` through `12-prior-art-learnings.md`, `README.md`, `migrations/0001_init.surql`, `prompts/extract.v1.md`, `prompts/consolidate.v1.md`, `Dockerfile`, `docker-compose.yml`, `docker-compose.external.yml`)  
**Binding Baseline:** `docs/spec/00-decisions.md` (Current accepted v1 decisions & Canonical Registry §3)

---

## 1. Summary Verdict

### Verdict: **PASS-WITH-FIXES** (Ready for Implementation after Applying Fix List)

The Round 2 consistency re-audit evaluated all spec files following the comprehensive amendments to `00-decisions.md` (ADR-02 CBOR wire mandate, rewritten ADR-08 truth maintenance, ADR-12 consolidation counter, ADR-13 plugin contract, ADR-14 purge/access, ADR-16 crate and image budgets, ADR-17 outbox batching timers & re-embedding, ADR-19 evaluation targets, §3.3 canonical recall/forget/audit schemas, and §3.4 tool schema canonicalization in `06-api-and-mcp.md`).

**Round 1 Blockers Status:**
1. **SurrealDB `/rpc` Wire Format (JSON vs CBOR):** **RESOLVED.** CBOR wire serialization (`application/cbor`, `ciborium`, tag 6 NONE, tag 8 RecordId, tag 12 Datetime) is consistently adopted across `00`, `02`, `03`, `06`, `10`, and `11`. Zero occurrences of JSON over SurrealDB `/rpc` remain.
2. **Missing `timezone` Field on `meta` Table:** **RESOLVED.** `timezone ON meta TYPE string DEFAULT "UTC"` is defined in `migrations/0001_init.surql:30`, `03-data-model.md:229`, and `00-decisions.md:186`.
3. **Recall Response Model (`context_markdown` vs `markdown`):** **RESOLVED.** All consumers and producers (`05`, `06`, `07`, `10`) standardize on `context_markdown` as the canonical field name, with defensive aliasing in `06` and `07`.
4. **`audit` Table Schema Collision:** **RESOLVED.** `migrations/0001_init.surql:211-226` is adopted as canonical across `00`, `03`, `04`, and `09` with field `at` and `details FLEXIBLE`.

**Round 2 Audit Findings:**
Zero fatal **BLOCKER** findings remain. However, **5 MAJOR**, **8 MINOR**, and **2 NIT** discrepancies were identified across the recently updated documents. These represent mechanical discrepancies between code sketches/OpenAPI schemas and database constraints, or residual draft inconsistencies in truth maintenance rules:

1. **[MAJOR] `meta:bank` DDL Field Names in `02-architecture.md`:** The `CREATE ONLY meta:bank SET` example in `02` specifies `embedding_dimension = 1024` and `predicate_vocab_version = "v1"`. In `SCHEMAFULL` mode, SurrealDB 3.3.4 strictly enforces column names; `migrations/0001_init.surql:28-29` and `03-data-model.md:229` define `embedding_dim` and `vocabulary_version`. Executing the snippet in `02` will trigger an immediate schema rejection.
2. **[MAJOR] Negative Polarity Sets `expired_at` in `04-ingestion-pipeline.md`:** `04-ingestion-pipeline.md` lines 650, 798, and 913 set `expired_at = time::now()` upon negative polarity assertions. This directly violates ADR-08 Rule 3, `03-data-model.md` Invariant 4 (`expired_at remains NONE`), Invariant 7 (`active facts must have expired_at = NONE`), and `Q-FACT-NEGATE`. In Engram's bi-temporal model, negative assertions close facts in *world time only* (`valid_to = n.valid_from`); belief remains active (it is a believed historical fact). Setting `expired_at` corrupts transaction-time history, rendering the historical fact invisible in `as_of` queries.
3. **[MAJOR] `Fact.polarity` Modeled as Boolean in `06` and `11`:** `11-rust-implementation-guide.md:412` defines `pub polarity: bool` and `06-api-and-mcp.md:1267` specifies `polarity: { type: boolean }`. However, `migrations/0001_init.surql:123`, `00-decisions.md:187`, `03-data-model.md:234`, and `prompts/extract.v1.md:196` strictly define `polarity` as a string enum (`"positive" | "negative"`). Serializing a boolean causes SurrealDB schema validation rejection.
4. **[MAJOR] `determine_reconciliation` Logic Discrepancies in `11-rust-implementation-guide.md`:** The Rust reconciliation sketch in `11` contains four deviations from ADR-08: (a) uses `proposed.valid_from >= prior.valid_from` (non-strict `>=`), causing equal-timestamp claims to supersede instead of contest; (b) completely omits Rule 2 Authority Guard rejection; (c) completely omits Rule 6 History Backfill; and (d) names the negative-polarity action `RetractMatchingPositive`.
5. **[MAJOR] `engram_forget` Tool Description Claims `valid_to = now` in `06-api-and-mcp.md`:** Line 681 declares `description = "Soft-retire memory record by ID (marks retracted, valid_to = now)."`. This contradicts ADR-08 and §3.3 forget semantics (`06:299`, `00:189`, `03:1365`), which mandate that retraction withdraws belief and leaves `valid_to` untouched.

All 15 findings are itemized below with line numbers, conflicting claims, and exact mechanical fixes.

---

## 2. Findings Table

| ID | Sev | Location (Files & Lines) | Conflicting Values / Descriptions | Canonical Value & Recommended Fix |
|---|---|---|---|---|
| **F-01** | **MAJOR** | `02-architecture.md:787-788, 804`<br>`04-ingestion-pipeline.md:268, 270, 275` | `02` specifies `CREATE ONLY meta:bank SET ... embedding_dimension = 1024, predicate_vocab_version = "v1"`. Line 804 refers to `meta.embedding_dimension`. `04` uses `meta.embedding_dimensions`. | **`migrations/0001_init.surql:28-29` & `03-data-model.md:229`:** In SurrealDB `SCHEMAFULL` mode, fields must match migration exactly: `embedding_dim` and `vocabulary_version`. Update `02` lines 787-788 to `embedding_dim = 1024, vocabulary_version = "v1"`, line 804 to `meta.embedding_dim`, and `04` lines 268-275 to `meta.embedding_dim`. |
| **F-02** | **MAJOR** | `04-ingestion-pipeline.md:650, 798, 913` | Rule 3 (Negative Polarity) sets `expired_at = time::now()` (`updated_e.expired_at = Some(Utc::now())`). | **ADR-08 Rule 3 & `03-data-model.md:1364, 1367`:** Negative polarity assertions close facts in *world time only* (`valid_to = n.valid_from`). The fact's `status` remains `'active'` (it is a believed historical fact) and `expired_at` MUST remain `NONE` (Invariant 7: `An active fact must have expired_at = NONE`). In `04`, remove `expired_at` assignment on lines 650, 798, and 913. |
| **F-03** | **MAJOR** | `11-rust-implementation-guide.md:412, 450, 456, 471`<br>`06-api-and-mcp.md:1267` | `Fact.polarity` is declared as `pub polarity: bool` with `if !proposed.polarity` logic; `06` OpenAPI specifies `polarity: { type: boolean }`. | **`migrations/0001_init.surql:123` & `00-decisions.md:187`:** `polarity` is a string enum: `ASSERT $value IN ["positive", "negative"]`. Define `pub enum Polarity { Positive, Negative }` (serialized as lowercase strings) in `11`, and change OpenAPI schema in `06` to `{ type: string, enum: [positive, negative] }`. |
| **F-04** | **MAJOR** | `11-rust-implementation-guide.md:448-505` | `determine_reconciliation`: (1) uses `proposed.valid_from >= prior.valid_from` (non-strict `>=`); (2) omits Rule 2 Authority Guard rejection; (3) omits Rule 6 History Backfill; (4) names negative polarity action `RetractMatchingPositive`. | **ADR-08 Rules 1–7 & `04-ingestion-pipeline.md:635-677`:** (1) Change `>=` to strict `>` per Rule 5; equal timestamps contest per Rule 7; (2) Add Rule 2 Authority Guard: if `prior.trust == Trust::UserStated && proposed.trust <= Trust::AssistantStated`, return `ReconcileAction::RejectLowTrust`; (3) Add Rule 6 History Backfill: if `proposed.valid_from < prior.valid_from`, return `ReconcileAction::HistoryBackfill { valid_to: prior.valid_from }`; (4) Rename action to `CloseNegativeWorldTime`. |
| **F-05** | **MAJOR** | `06-api-and-mcp.md:681` | MCP `engram_forget` tool docstring states: `description = "Soft-retire memory record by ID (marks retracted, valid_to = now)."`. | **ADR-08 & §3.3:** Retraction withdraws belief in transaction time, leaving world validity `valid_to` untouched (`06:299`, `00:189`, `03:1365`). Change description to: `"Soft-retire memory record by ID (marks retracted, expired_at = now; leaves valid_to untouched; reopens predecessor)."`. |
| **F-06** | **MINOR** | `00-decisions.md:129` | States: `Measured 2026-10-24 (11-rust-implementation-guide.md): 211 normal crates default / 239 with otlp`. | **ADR-16 & `11:16, 35, 48`:** Adding `ciborium` for CBOR RPC added +7 crates. The actual measured crate counts with ciborium are **218 normal crates default / 245 with otlp** (matching `11`, `docs/spec/README.md:124`, and audit prompt). Update `00-decisions.md:129` to cite 218 / 245. |
| **F-07** | **MINOR** | `05-retrieval.md:209-210` | Section 2.3 table lists `engram_recall Tool` default `top_k: 15, token_budget: 2048` and `MCP engram_recall` default `top_k: 15, token_budget: 2048`. | **`00-decisions.md §3.5`, `06:468, 648`, `07:455-456`:** Standard default across all recall invocations is `top_k = 12, token_budget = 1200`. Update table entries in `05-retrieval.md:209-210` from 15 / 2048 to 12 / 1200. |
| **F-08** | **MINOR** | `06-api-and-mcp.md:250-251` | `POST /v1/banks/{bank}/recall` response example duplicates key `"context_markdown"` on lines 250 and 251. | **Schema Cleanliness:** Remove duplicate `"context_markdown"` key on line 251. |
| **F-09** | **MINOR** | `06-api-and-mcp.md:328` | `POST /v1/banks/{bank}/entities/merge` states: `marks merged_id.status = "merged"`. | **`migrations/0001_init.surql:94-108` & `03:233`:** Table `entity` is `SCHEMAFULL` and does NOT have a `status` field. Update description to state that `merged_id` is physically removed (`DELETE $merged_id`) after edge rewiring and alias consolidation. |
| **F-10** | **MINOR** | `07-hermes-plugin.md:502, 1421` | `trust` parameter enum in `engram_remember` lists `["user_stated", "assistant_stated", "inferred"]` (3 values). | **`00-decisions.md:187` & `06-api-and-mcp.md:474`:** 5 canonical trust tiers exist: `user_stated`, `user_implied`, `assistant_stated`, `tool_output`, `inferred`. Add `user_implied` and `tool_output` to enum in `07` lines 502 and 1421. |
| **F-11** | **MINOR** | `07-hermes-plugin.md:503, 1650` | Table 10.1 (L503) omits `cascade` from forget response. L1650 states `Forget returns {"status": "retracted", "id": "...", "valid_to": "..."}`. | **`00-decisions.md:189` & `06:308, 1224`:** Canonical forget response is `{"id": "...", "status": "retracted", "retracted_at": "...", "cascade": {"facts": n, "reopened": n}}`. Update line 503 and line 1650 to include `cascade` and replace `valid_to` with `retracted_at`. |
| **F-12** | **MINOR** | `09-observability.md:340-353` | Section 6.1 `audit` schema lists `DEFAULT "system"` for `actor` and omits `job` field. | **`migrations/0001_init.surql:211-222`:** Schema should match migration verbatim: `actor TYPE string DEFAULT "engram" ASSERT $value IN ["engram", "api", "mcp", "hermes", "system"]` and include `job ON audit TYPE option<record<job>>`. |
| **F-13** | **MINOR** | `11-rust-implementation-guide.md:360-365` | `enum Trust` values: `Inferred = 1, ToolOutput = 2, AssistantStated = 3...`. Deriving `PartialOrd, Ord` makes `AssistantStated > ToolOutput`. | **ADR-08 Trust Ranks:** `assistant_stated` equals `tool_output` (both rank 3). Implement `pub fn rank(self) -> u8` returning `(5, 4, 3, 3, 2)` instead of deriving direct enum ordering. |
| **F-14** | **NIT** | `07-hermes-plugin.md:1652` | Refers to `POST /v1/sessions/:id/flush`, omitting `banks/:bank/`. | Change to `POST /v1/banks/{bank}/sessions/{id}/flush`. |
| **F-15** | **NIT** | `06-api-and-mcp.md:1122` | OpenAPI `BankConfig` property uses `embedding_dimensions` (matching config key), whereas `meta` record uses `embedding_dim`. | Add documentation comment noting serialization mapping between config `embedding_dimensions` and DB `meta.embedding_dim`. |

---

## 3. Verified-Correct Claims

1. **CBOR RPC Wire Protocol Compliance (ADR-02):** Tested and codified across `00`, `02`, `03`, `06`, `10`, and `11`. Uses `application/cbor` via `ciborium` with native tags 6 (NONE), 8 (RecordId), and 12 (Datetime). Bound strings with colons round-trip verbatim without record coercion or truncation. Zero occurrences of JSON over `/rpc` remain.
2. **SurrealDB 3.3.4 Schemas & Idempotency:** The 10 per-bank tables (`meta`, `schema_migration`, `session`, `episode`, `entity`, `fact`, `mentions`, `observation`, `job`, `audit`) in `migrations/0001_init.surql` and `03-data-model.md` are verified `SCHEMAFULL` compliant, idempotent, and include the missing `timezone` field.
3. **Budget Compliance (ADR-16):**
   - **Docker Image Size:** Measured **584.03 MB** uncompressed / **140.76 MB** compressed pull, strictly complying with the $\le 650\text{ MB} / \le 160\text{ MB}$ budget across `01`, `08`, `11`, and `README.md`.
   - **Rust Crate Count:** Compiles with **218 normal crates** default (budget $\le 300$) and **245 crates** with OTLP (budget $\le 340$).
   - **Stripped Binary:** Measures **7.7 MB** default / **8.06 MB** with OTLP (budget $\le 25\text{ MB}$).
4. **Evaluation Targets (ADR-19):** Calibrated across `01`, `10`, and `README.md`: local 8B stack baseline recorded at M5 with $\le 3.0\text{ percentage point}$ regression gate; frontier cloud model goal $\ge 70.0\%$ strict on the LongMemEval_S 100-question subset (with abstention questions retained).
5. **Docker Compose Separation:** Topologies are cleanly separated into `docker-compose.yml` (all-in-one default with optional `with-ollama` profile) and `docker-compose.external.yml` (external SurrealDB container), with consistent `stop_grace_period: 40s` across all services.
6. **Tool Schemas Parity:** Tool names (`engram_recall`, `engram_remember`, `engram_forget`, `engram_entities`, `engram_status`) and parameter schemas match across MCP (`06`) and Hermes plugin (`07`), with `06` established as canonical.
7. **Deterministic Truth Maintenance Architecture:** Decoupled world time (`valid_from`/`valid_to`) from belief state (`status`); current-truth predicate strictly filters `status = 'active' AND (valid_to IS NONE OR valid_to > time::now())` across retrieval queries and graph traversals.
8. **Durable Outbox Batching Timers (ADR-17):** Verified via `Q-EXTRACT-JOB-UPSERT` with deterministic ID `job:['extract', $session_id]`, surviving server restarts.
9. **Administrative Purge Pipeline (ADR-14):** Verified via `Q-PURGE` cascading to dependent facts/observations, scrubbing `audit` entries, and recording an unredacted audit record without leaking text content.

---

## 4. Unverifiable Items

1. **Host-Specific GPU Latency for Local Extraction:** While the 4-turn batch extraction token budget ($\le 35\text{k tokens per 100 turns}$) and prompt structure are verified, actual wall-clock P95 inference latency depends on the host GPU/NPU acceleration and quant level.
2. **LongMemEval_S Exact Score at M5:** Strict accuracy on the 100-question eval harness will be empirically recorded at Milestone M5 using local `qwen3:8b`.

---

## 5. Concise Fix List per File

### `docs/spec/00-decisions.md`
1. **Line 129 (F-06):** Change `211 normal crates default / 239 with otlp` to `218 normal crates default / 245 with otlp (including ciborium)`.

### `docs/spec/02-architecture.md`
1. **Lines 787-788 (F-01):** In `CREATE ONLY meta:bank SET`, change:
   ```surql
   embedding_dimension = 1024,
   predicate_vocab_version = "v1",
   ```
   to:
   ```surql
   embedding_dim = 1024,
   vocabulary_version = "v1",
   ```
2. **Line 804 (F-01):** Change `meta.embedding_dimension` to `meta.embedding_dim`.

### `docs/spec/04-ingestion-pipeline.md`
1. **Lines 268, 270, 275 (F-01):** Change `meta.embedding_dimensions` to `meta.embedding_dim`.
2. **Line 650 (F-02):** In Rule 3, change `$e.valid\_to \gets n.valid\_from, e.expired\_at \gets time::now()$` to `$e.valid\_to \gets n.valid\_from$` (do NOT set `expired_at`).
3. **Line 798 (F-02):** In Rule 3 code, remove `updated_e.expired_at = Some(Utc::now());`.
4. **Line 913 (F-02):** In worked example 4, change `valid_to = 2026-07-15, expired_at = now()` to `valid_to = 2026-07-15, expired_at = NONE`.

### `docs/spec/05-retrieval.md`
1. **Lines 209-210 (F-07):** In Section 2.3 table, change `Default top_k: 15, Default token_budget: 2048` to `Default top_k: 12, Default token_budget: 1200` for both `engram_recall Tool` and `MCP engram_recall`.

### `docs/spec/06-api-and-mcp.md`
1. **Line 251 (F-08):** Remove duplicate `"context_markdown"` key on line 251.
2. **Line 328 (F-09):** Change `marks merged_id.status = "merged"` to `physically deletes merged_id (DELETE $merged_id)`.
3. **Line 681 (F-05):** In `engram_forget` tool description, change `(marks retracted, valid_to = now)` to `(marks retracted, expired_at = now; leaves valid_to untouched; reopens predecessor)`.
4. **Line 1267 (F-03):** In `FactDetail` schema, change `polarity: { type: boolean }` to `polarity: { type: string, enum: [positive, negative] }`.

### `docs/spec/07-hermes-plugin.md`
1. **Line 502 (F-10):** In tool table, change `enum: user_stated, assistant_stated, inferred` to `enum: user_stated, user_implied, assistant_stated, tool_output, inferred`.
2. **Line 503 (F-11):** In tool table, update return structure for `engram_forget` to: `JSON string: {"id": "...", "status": "retracted", "retracted_at": "...", "cascade": {"facts": n, "reopened": n}}`.
3. **Line 1421 (F-10):** In `get_tool_schemas()`, update `trust` enum to `["user_stated", "user_implied", "assistant_stated", "tool_output", "inferred"]`.
4. **Line 1650 (F-11):** Change `valid_to` to `retracted_at` and include `cascade`.
5. **Line 1652 (F-14):** Change `POST /v1/sessions/:id/flush` to `POST /v1/banks/{bank}/sessions/{id}/flush`.

### `docs/spec/09-observability.md`
1. **Lines 340-353 (F-12):** Update `audit` table schema snippet to match `migrations/0001_init.surql` verbatim, including `job ON audit TYPE option<record<job>>;` and `DEFAULT "engram" ASSERT $value IN ["engram", "api", "mcp", "hermes", "system"]`.

### `docs/spec/11-rust-implementation-guide.md`
1. **Lines 360-365 (F-13):** Implement `pub fn rank(self) -> u8` returning `5, 4, 3, 3, 2` for `Trust` comparison instead of relying on derived `Ord`.
2. **Line 412 (F-03):** Change `pub polarity: bool` to `pub polarity: Polarity`. Define `Polarity` enum with `Positive` and `Negative`.
3. **Line 443 & 458 (F-04):** Rename `RetractMatchingPositive` to `CloseNegativeWorldTime`.
4. **Line 487 (F-04):** Change `proposed.valid_from >= prior.valid_from` to `proposed.valid_from > prior.valid_from` (strict inequality).
5. **Lines 448-505 (F-04):** Update `determine_reconciliation` to include Rule 2 Authority Guard rejection (`RejectLowTrust`) and Rule 6 History Backfill (`HistoryBackfill`).
