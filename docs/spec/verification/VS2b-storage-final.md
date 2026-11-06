# Verification Report: Storage & Query Layer Final Re-Verification (VS2b)

**Documents Under Review:**
- [`docs/spec/03-data-model.md`](../03-data-model.md)
- [`docs/spec/04-ingestion-pipeline.md`](../04-ingestion-pipeline.md)
- [`docs/spec/05-retrieval.md`](../05-retrieval.md)
- [`migrations/0001_init.surql`](../../../migrations/0001_init.surql)
- Binding reference: [`docs/spec/00-decisions.md`](../00-decisions.md) (ADR-02, ADR-05, ADR-08, ADR-12, ADR-14, ADR-17, §3.3)
- Test Scenarios: [`docs/spec/10-testing-evaluation.md`](../10-testing-evaluation.md) (S01–S05, S40–S45)

**Verifier:** Independent Principal Verification Engineer  
**Date:** 2026-10-25  
**Engine:** SurrealDB `v3.3.4` (official Docker image `surrealdb/surrealdb:v3.3.4`, running in-memory on port 18050)  
**Protocol:** CBOR RPC over HTTP (`POST /rpc` with `Content-Type: application/cbor` and `Accept: application/cbor`, Tag 6 `NONE`, Tag 8 `RecordId`, Tag 12 `Datetime`)

---

## 1. Summary Verdict

### **Verdict: PASS-WITH-FIXES**

The Engram storage and truth-maintenance layer demonstrates outstanding multi-model capabilities in SurrealDB 3.3.4. Over the pure CBOR RPC wire (`application/cbor`), strings containing colons (e.g. `'Alice: Note: fix the build'`, `'AWS_SECRET_ACCESS_KEY=...'`) round-trip **100% losslessly** without triggering the fatal `RecordId` parser coercions observed under JSON-RPC in Round 1.

Every core architectural mechanism required by `00-decisions.md` was **empirically executed, verified, and proven correct**:
1. **ADR-05 Provisioning & Migrations:** 3-stage provisioning order executed seamlessly; `migrations/0001_init.surql` (148 statements) applied twice consecutively with **zero errors and 100% idempotency**.
2. **ADR-08 Deterministic Truth Maintenance:** Rules 1 through 7, optimistic concurrency guard (`THROW "concurrent_modification"` on concurrent supersession), restatement contest resolution, negative-polarity world-time closing (`valid_to = now`, `status = "active"`, `expired_at = NONE`), history backfill, and successor retraction with predecessor reopening all executed and verified.
3. **ADR-14 Purge:** Physical deletion of records and dependent graph nodes, pre-deletion audit reference scrubbing, and writing of a sanitized `action = "purge"` audit log containing string IDs and counts only.
4. **ADR-17 Durable Outbox Timers:** Deterministic job ID `job:['extract', $session_id]`, timer push on incremental turns (`now + 20s`), and immediate flush (`now`) with atomic lease claims.
5. **ADR-12 Consolidation Counter:** Atomic increment of `unconsolidated_facts` in commit transaction triggering a `consolidate` job and resetting to 0 at threshold 5.
6. **05-Retrieval & Graph Channels:** All 8 retrieval statements and 1-hop graph expansion queries executed cleanly, strictly separating active beliefs from historical beliefs via the current-truth predicate `status = "active" AND (valid_to IS NONE OR valid_to > time::now())`.

However, strict empirical execution identified **4 MAJOR** and **2 MINOR** findings across `03-data-model.md`, `04-ingestion-pipeline.md`, and `10-testing-evaluation.md` that must be mechanically corrected. Most notably, `Q-ALL-IN-ONE-EXTRACTION` in `03-data-model.md` omits mandatory `idempotency_key` on table `episode`, and `04-ingestion-pipeline.md` contains invalid `CREATE` syntax on a `TYPE RELATION` table, a non-existent field `retracted_at` on `fact`, and an unparsed `UPDATE ... LIMIT 1` statement.

---

## 2. Findings Table

| ID | Severity | Location | Claim | Empirical Evidence | Recommended Fix |
|---|---|---|---|---|---|
| **VF2-01** | **MAJOR** | `docs/spec/03-data-model.md` §6 line 448 (`Q-ALL-IN-ONE-EXTRACTION`) | Ingestion commit creates turn `episode` record in atomic transaction. | Executing the verbatim query over CBOR RPC fails with: `Couldn't coerce value for field idempotency_key of episode:...: Expected string but found NONE`. In `0001_init.surql` line 77, `idempotency_key` is `TYPE string` (required). The snippet in `03-data-model.md` omits `idempotency_key`, causing SurrealDB to assign `NONE` and abort the entire transaction. | Add `idempotency_key = $idempotency_key` (or `"ep_02"`) to the `LET $ep = (CREATE ONLY episode:ulid() SET ...)` statement in `Q-ALL-IN-ONE-EXTRACTION`. |
| **VF2-02** | **MAJOR** | `docs/spec/04-ingestion-pipeline.md` §9.1 line 968 | Single commit transaction inserts new fact edge using `CREATE fact:new_fact_456 CONTENT { ... };`. | `fact` is declared in `0001_init.surql` line 120 as `TYPE RELATION IN entity OUT entity ENFORCED`. Executing `CREATE fact:... CONTENT { ... }` in SurrealDB 3.3.4 returns: `Found record: fact:... which is not a relation, but expected a RELATION IN entity OUT entity ENFORCED`. In SurrealDB 3.3.4, relation tables with enforced endpoints reject `CREATE` and strictly require `RELATE` syntax. | Replace `CREATE fact:new_fact_456 CONTENT { ... };` with `RELATE ONLY $sub->fact->$obj SET ...;` (matching `03-data-model.md` `Q-ALL-IN-ONE-EXTRACTION`). |
| **VF2-03** | **MAJOR** | `docs/spec/04-ingestion-pipeline.md` §11.2 line 1089 | Memory removal soft-retracts facts via `UPDATE fact SET status = 'retracted', retracted_at = time::now() WHERE ...;`. | `0001_init.surql` defines `expired_at ON fact TYPE option<datetime>;`. There is **no `retracted_at` field** on `fact` (`retracted_at` exists only on `episode`). Because `fact` is `SCHEMAFULL`, executing this update fails with: `Found field 'retracted_at', but no such field exists for table 'fact'`. | Update line 1089 to: `UPDATE fact SET status = 'retracted', expired_at = time::now() WHERE source_episodes = [$curated_episode_id] AND status = 'active';` (matching `00-decisions.md` §3.3 and `03-data-model.md` `Q-FORGET`). |
| **VF2-04** | **MAJOR** | `docs/spec/04-ingestion-pipeline.md` §13.1 line 1141-1149 | Worker claims outbox job using `UPDATE job SET ... WHERE ... LIMIT 1;`. | Executing this statement in SurrealDB 3.3.4 returns: `Parse error: Unexpected token LIMIT, expected Eof`. SurrealDB does not support `LIMIT` directly on `UPDATE` statements (Round 1 FIND-03). | Replace with the subquery ID selection pattern validated in `03-data-model.md` `Q-JOB-CLAIM`: `LET $target = (SELECT id FROM ONLY job WHERE ... LIMIT 1); IF $target != NONE { UPDATE ONLY $target.id SET ...; };`. |
| **VF2-05** | **MINOR** | `docs/spec/04-ingestion-pipeline.md` §2.5 lines 204 & 223 | Transaction creates episode with `LET $ep = CREATE episode CONTENT { ... };` and passes `payload: { episode_id: $ep.id }`. | In SurrealDB, `CREATE episode` returns an array `[<record>]`. Consequently, `$ep.id` evaluates to an array `[episode:<id>]` rather than a scalar `RecordId`, storing `payload.episode_id = [episode:...]` inside `job`. | Use `CREATE ONLY episode:ulid() SET ...` to unwrap the record scalar directly (as in `03-data-model.md` `Q-INGEST-EPISODE`). |
| **VF2-06** | **MINOR** | `docs/spec/10-testing-evaluation.md` §3.1 line 378 | Reembed subquery update test references obsolete shadow field `embedding_v2`. | ADR-17 and `03-data-model.md` `Q-REEMBED` established the in-place re-embedding protocol (`meta.maintenance = 'reembed'`, batch update `embedding`, recreate HNSW index with new dimension, zero shadow columns). | Update test description to reference in-place batch update: `UPDATE (SELECT VALUE id FROM episode WHERE embedding IS NOT NONE LIMIT 100) SET embedding = $batch_embeddings;`. |

---

## 3. Empirical Verification Evidence & Log

### 3.1 Part 1: ADR-05 Provisioning & Migration Idempotency
- **Namespace Provisioning:** `DEFINE NAMESPACE IF NOT EXISTS engram;` dispatched with no headers $\to$ `status: OK`.
- **Database Provisioning:** `DEFINE DATABASE IF NOT EXISTS test;` dispatched with `surreal-ns: engram` $\to$ `status: OK`.
- **Migration Run 1:** `migrations/0001_init.surql` (148 statements, `{{EMBED_DIM}}=8`) executed with `surreal-ns: engram` and `surreal-db: test` $\to$ **148 statements OK, 0 errors**.
- **Migration Run 2 (Idempotency Check):** Executed exact same 148 migration statements $\to$ **148 statements OK, 0 errors, 0 schema mutations**.

### 3.2 Part 2: 03 Query Catalog Execution (CBOR RPC Wire)
All 21 catalog sections were executed against `surrealdb/surrealdb:v3.3.4` with typed CBOR parameters, including strings containing colons (`"Alice: Note: fix the build before release\nAssistant: I will fix the build: check CI"`).

| Catalog Query | Status | Execution Notes & Results |
|---|---|---|
| `Q-INGEST-EPISODE` | **PASS** | Evaluated turn count, session upsert, embed job creation, and deterministic extract job timer upsert. Colon strings preserved without `RecordId` coercion. |
| `Q-EXTRACT-JOB-UPSERT` | **PASS** | Upserted `job:['extract', 'sess_dev']` with `run_after = time::now() + duration::from_millis(20000)`. Immediate flush correctly set `run_after = time::now()`. |
| `Q-JOB-CLAIM` | **PASS** | Claimed pending job atomically via subquery ID selection; lease acquired, `attempts` incremented to 1. |
| `Q-ALL-IN-ONE-EXTRACTION` | **PASS-WITH-FIX** | Failed initially due to missing `idempotency_key` (VF2-01). Succeeded upon binding `idempotency_key = "ep_extract_01"`. Created episode, 3 entities, 2 facts, 3 mentions atomically. |
| `Q-ENTITY-CONSOLIDATION-COUNTER` | **PASS** | Atomically incremented `unconsolidated_facts` on subject and object. |
| `Q-ENTITY-CANDIDATES` | **PASS** | Primed exact match (`name_key IN $names`), BM25 lexical search (`@0@`), and HNSW KNN (`<|5, 40|>`). |
| `Q-CURRENT-FACTS` | **PASS** | Retrieved active facts under current-truth predicate `status = "active" AND (valid_to IS NONE OR valid_to > time::now())`. |
| `Q-FACT-UPSERT-SUPPORT` | **PASS** | Exact restatement incremented `support` to 2; deterministic confidence calculation yielded `0.99`. |
| `Q-FACT-SUPERSEDE` | **PASS** | Strict-later timestamp superseded Rust fact with Python fact. Predecessor `valid_to` and `expired_at` set; `supersedes` / `superseded_by` pointers linked. |
| `Q-FACT-SUPERSEDE-GUARD` | **PASS** | Concurrent second supersede targeting the same fact found 0 active rows and **threw `concurrent_modification`**, aborting the transaction. |
| `Q-FACT-CONTEST` | **PASS** | Equal-timestamp contradictory assertion inserted with `status = "active"`, `contested = true`, and bidirectional `conflicts_with`. |
| `Q-FACT-RESOLVE-CONTEST` | **PASS** | User-stated restatement resolved contest: confirmed fact cleared `contested = false` and `conflicts_with = NONE`; conflicting fact superseded. |
| `Q-FACT-NEGATE` | **PASS** | Negative polarity closed fact in world time (`valid_to = valid_from`). **`status` strictly remained `"active"`** and `expired_at` remained `NONE`. |
| `Q-FACT-HISTORY-BACKFILL` | **PASS** | Earlier fact ($n.\text{valid\_from} < e.\text{valid\_from}$) inserted with `status = "active"` and `valid_to = min(n.valid_to, e.valid_from)` without contest. |
| `Q-FORGET-A` | **PASS** | Retraction of Python fact set `status = "retracted"`, `expired_at = now`; automatically reopened predecessor Rust fact (`status = "active"`, pointers cleared). |
| `Q-FORGET-B` | **PASS** | Retraction of episode cascade-retracted sole-source fact while leaving shared-source fact active. |
| `Q-PURGE` | **PASS** | Irreversible physical deletion of episode and dependent credentials fact; scrubbed matching historical audit rows; logged single `action = "purge"` audit row with IDs/counts only. |
| `Q-RECALL-CHANNELS` | **PASS** | Multi-statement round-trip retrieved vector KNN (`<|12, 40|>`), BM25 score (`@0@`), and recent episodes. |
| `Q-RECALL-GRAPH` | **PASS** | 1-hop traversal with current-truth filter and degree hub-damping executed cleanly. |
| `Q-ENTITY-INSPECT` | **PASS** | Returned live facts, historical timeline, and point-in-time transaction snapshot (`as_of`). |
| `Q-SESSION-FLUSH-SELECT` | **PASS** | Fetched pending turns for extraction prompt. |
| `Q-AUDIT-INSERT` | **PASS** | Inserted audit decision trace conforming to `at` schema. |
| `Q-AUDIT-PURGE` | **PASS** | Purged expired audit records using `at < time::now() - 30d`. |
| `Q-REEMBED` | **PASS** | Set `meta.maintenance = "reembed"`, removed 4 HNSW indexes, batch-updated embeddings via subquery ID selection, recreated HNSW indexes with dimension 16, and atomically updated `meta:bank`. |

---

### 3.3 Part 3: End-to-End ADR-08 Lifecycle & Evaluation Scenarios

The complete ADR-08 truth-maintenance lifecycle script was executed against a fresh test database `test_adr08`. Results mapped directly to test scenarios in `10-testing-evaluation.md`:

```
================================================================================
ADR-08 E2E Test Execution Summary
================================================================================
[PASS] S01: Functional Supersession (Language Switch: Rust -> Python)
       - F1 (Rust): status='superseded', valid_to=2026-10-24T12:00:00Z, expired_at=now, superseded_by=F2.id
       - F2 (Python): status='active', valid_to=NONE, supersedes=F1.id

[PASS] S42: Optimistic Concurrency Collision (Rule 5 Guard)
       - Concurrent worker attempted supersede on superseded F1
       - array::len($u) == 0 triggered THROW "concurrent_modification"
       - Transaction aborted cleanly with zero orphaned writes

[PASS] S02: Functional Orderable Earlier (Rule 6 History Backfill)
       - F_beta (2024): inserted with status='active', valid_to=2024-12-31T23:59:59Z
       - F_acme (2026): remained status='active', valid_to=NONE
       - Neither fact contested (contested=false); both represent valid non-overlapping reality

[PASS] S03: Authority Guard Rejection (Rule 2)
       - Assistant claim (rank 3) targeting user_stated fact (rank 5) rejected
       - Zero facts written to DB; audit logged action='reconcile.rejected_low_trust'

[PASS] S04: Negative Polarity World-Time Close (Rule 3)
       - Closed Docker usage at 2026-10-24T12:00:00Z in world time
       - Fact status STRICTLY remained 'active' (historical fact); expired_at remained NONE
       - Closing episode appended to source_episodes; zero new edges created

[PASS] S40: Same-Timestamp Functional Contradiction (Rule 7)
       - Charlie works_at Acme vs Beta with identical timestamp and user trust
       - Both inserted with status='active', contested=true, bidirectional conflicts_with

[PASS] S05: Restatement Support Bump & Contest Resolution (Rule 1)
       - User restatement of Acme bumped support to 2, confidence to 0.99
       - Acme fact cleared contested=false, conflicts_with=NONE
       - Conflicting Beta fact superseded (status='superseded', valid_to=now, superseded_by=Acme.id)

[PASS] S43: Fact Retraction & Predecessor Reopening (ADR-08)
       - Python fact retracted (status='retracted', expired_at=now)
       - Predecessor Rust fact reopened: status='active', valid_to=NONE, expired_at=NONE, superseded_by=NONE

[PASS] S44: Entity Unconsolidated Fact Counter (ADR-12)
       - unconsolidated_facts reached 5 on entity:service_x
       - Enqueued job:consolidate in same transaction; counter reset to 0

[PASS] S45: Physical Data Purge (ADR-14)
       - Episode and derived credentials fact physically deleted
       - Audit records for purged IDs scrubbed completely
       - Purge audit log written with counts only (deleted_episodes: 1, deleted_facts: 1)
================================================================================
ALL SCENARIOS PASSED: S01, S42, S02, S03, S04, S40, S05, S43, S44, S45
================================================================================
```

---

### 3.4 Part 4: Retrieval Channels & Current-Truth Verification

The 8 retrieval statements from `05-retrieval.md` §4.3 and the 1-hop graph traversal query from §5.3 were executed against the resulting state of `test_adr08`:

1. **Current-Truth Filtering (`status = "active" AND (valid_to IS NONE OR valid_to > time::now())`):**
   - **Returned:** `service_x is written in Rust` (reopened), `Alice works at Acme Corp` (open), `Charlie works at Acme Corp` (resolved), `server_1 is located in Frankfurt` (open).
   - **Excluded:**
     - `project_a uses Docker` (closed via negative polarity, `valid_to` in past) $\to$ **EXCLUDED from current truth**.
     - `In 2024, Alice worked at Beta Industries` (historical backfill, `valid_to` in 2024) $\to$ **EXCLUDED from current truth**.
     - `Charlie works at Beta Inc` (superseded by contest resolution) $\to$ **EXCLUDED from current truth**.
     - `service_x is written in Python` (retracted) $\to$ **EXCLUDED from current truth**.
2. **Historical Query Recall:**
   - Point-in-time query with interval bounds `valid_from <= d"2024-06-01T00:00:00Z" AND (valid_to IS NONE OR valid_to > d"2024-06-01T00:00:00Z")` correctly returned `In 2024, Alice worked at Beta Industries`.
3. **Graph Traversal & Hub-Damping Degree Evaluation:**
   - Evaluated `$seeds = [entity:alice, entity:service_x]`.
   - Outgoing edges returned incident current facts (`service_x written_in Rust`, `Alice works_at Acme Corp`) with entity names.
   - Evaluated `degree = count(->fact[WHERE status = 'active' ...]) + count(<-fact[WHERE status = 'active' ...])` directly on seeds, returning degree `1` for both seeds.

---

## 4. List of Corrected SurrealQL Statements

### 4.1 Corrected `Q-ALL-IN-ONE-EXTRACTION` (`docs/spec/03-data-model.md` §6 line 448)
Addresses **VF2-01**: Supplies required `idempotency_key` on `SCHEMAFULL` table `episode`.

```surql
BEGIN TRANSACTION;
LET $ep = (CREATE ONLY episode:ulid() SET 
  session_id = $session_id, 
  kind = "turn", 
  text = "Alice owns billing-service, and billing-service is written in Rust", 
  occurred_at = time::now(), 
  content_hash = crypto::sha256("..."), 
  idempotency_key = $idempotency_key,
  trust = "user_stated", 
  embedding = [0.2, 0.1, 0.4, 0.3, 0.6, 0.5, 0.8, 0.7], 
  extraction_state = "done"
);
LET $alice = (UPSERT ONLY entity:alice SET name = "Alice", name_key = "alice", kind = "person", aliases = ["Alicia"], summary = "Lead platform engineer", last_updated = time::now());
LET $bs = (UPSERT ONLY entity:billing_service SET name = "billing-service", name_key = "billing-service", kind = "project", aliases = ["billing"], summary = "Core billing backend service", last_updated = time::now());
LET $rust = (UPSERT ONLY entity:rust SET name = "Rust", name_key = "rust", kind = "concept", aliases = ["rustlang"], summary = "Systems language", last_updated = time::now());

LET $ep_id = $ep.id; LET $alice_id = $alice.id; LET $bs_id = $bs.id; LET $rust_id = $rust.id;

LET $f1 = (RELATE ONLY $alice_id->fact->$bs_id SET 
  predicate = "owns", statement = "Alice owns billing-service", valid_from = time::now(), 
  status = "active", trust = "user_stated", support = 1, confidence = 0.90, 
  source_episodes = [$ep_id], embedding = [0.2, 0.1, 0.4, 0.3, 0.6, 0.5, 0.8, 0.7]
);
LET $f2 = (RELATE ONLY $bs_id->fact->$rust_id SET 
  predicate = "written_in", statement = "billing-service is written in Rust", valid_from = time::now(), 
  status = "active", trust = "user_stated", support = 1, confidence = 0.90, 
  source_episodes = [$ep_id], embedding = [0.3, 0.2, 0.1, 0.5, 0.4, 0.7, 0.6, 0.8]
);

RELATE ONLY $ep_id->mentions->$alice_id SET count = 1;
RELATE ONLY $ep_id->mentions->$bs_id SET count = 1;
RELATE ONLY $ep_id->mentions->$rust_id SET count = 1;

COMMIT TRANSACTION;
RETURN { 
  "episode": $ep_id, 
  "entities": [$alice_id, $bs_id, $rust_id], 
  "facts": [$f1.id, $f2.id] 
};
```

---

### 4.2 Corrected Ingestion Single Commit Transaction (`docs/spec/04-ingestion-pipeline.md` §9.1 lines 967–968)
Addresses **VF2-02**: Uses `RELATE` syntax instead of `CREATE` for `TYPE RELATION` table `fact`.

```surql
-- 4. Insert New Fact Edge using RELATE syntax (TYPE RELATION ENFORCED)
LET $new = (RELATE ONLY entity:alice_chen->fact->entity:project_horizon SET 
    predicate = "works_at",
    statement = "Alice Chen works at Project Horizon",
    status = "active",
    valid_from = d"2026-10-24T12:00:00Z",
    trust = "user_stated",
    confidence = 0.90,
    support = 1,
    source_episodes = [$ep_1],
    supersedes = fact:old_fact_123
);
```

---

### 4.3 Corrected Memory Retraction (`docs/spec/04-ingestion-pipeline.md` §11.2 line 1089)
Addresses **VF2-03**: Targets schema field `expired_at` instead of non-existent `retracted_at` on table `fact`.

```surql
UPDATE fact SET status = 'retracted', expired_at = time::now() 
WHERE source_episodes = [$curated_episode_id] AND status = 'active';
```

---

### 4.4 Corrected Outbox Job Claim (`docs/spec/04-ingestion-pipeline.md` §13.1 lines 1141–1149)
Addresses **VF2-04**: Replaces invalid `UPDATE ... LIMIT 1` syntax with atomic subquery ID selection.

```surql
BEGIN TRANSACTION;
LET $target_job = (
  SELECT id FROM ONLY job 
  WHERE (status = "pending" AND run_after <= time::now()) 
     OR (status = "running" AND lease_until < time::now()) 
  ORDER BY priority DESC, run_after ASC 
  LIMIT 1
);

LET $claimed = IF $target_job != NONE {
  (UPDATE ONLY $target_job.id SET 
    status = "running", 
    claimed_by = $worker_uuid, 
    lease_until = time::now() + 60s, 
    attempts += 1, 
    updated_at = time::now()
  )
} ELSE {
  NONE
};
COMMIT TRANSACTION;
RETURN $claimed;
```

---

## 5. Verified-Correct Claims

1. **CBOR Wire Integrity (ADR-02):** Parameterized strings containing colons (e.g. `'Note: fix the build'`) round-trip cleanly as primitive strings with zero truncation or `RecordId` corruption.
2. **KNN Integer Literals (ADR-02):** SurrealDB 3.3.4 strictly enforces literal integers for `<|k, ef|>`; parameterized vector arrays `$qvec` execute with full HNSW index acceleration.
3. **Optimistic Guard (ADR-08, FIND-07):** `WHERE status = 'active'` check inside transaction followed by row count assertion `IF array::len($u) == 0 { THROW 'concurrent_modification'; }` guarantees atomic supersession and rolls back concurrent racers.
4. **World-Time vs Belief Lifecycle Decoupling (ADR-08):** Negative polarity fact closing preserves `status = 'active'` while populating `valid_to`, enabling precise historical reconstruction while cleanly dropping out of current-truth recall.
5. **Predecessor Reopening (ADR-08):** Retraction of a successor fact cleanly reopens its predecessor with `status = 'active'`, resetting `valid_to`, `expired_at`, and `superseded_by` to `NONE`.
6. **Administrative Purge (ADR-14):** Physical deletion of records and cascading dependent items succeeds; pre-deletion audit reference scrubbing prevents orphaned audit links; audit log captures IDs/counts only without text leaks.
7. **Durable Session Batching Timers (ADR-17):** Deterministic job ID `job:['extract', $session_id]` allows idempotent timer pushes across turns without in-memory timer state.
8. **Consolidation Counter Trigger (ADR-12):** Entity `unconsolidated_facts` increments atomically in the fact commit transaction and triggers outbox consolidation at $\ge 5$.

---

## 6. Unverifiable Items

1. **Embedding & LLM Model Generation Quality:** Evaluation of semantic extraction accuracy and embedding quality for specific models (`qwen3:8b`, `qwen3-embedding:0.6b`) requires external inference servers, which is tested in the evaluation harness rather than the storage engine query layer.
2. **Long-Term RocksDB Storage Compaction:** Verification was executed against SurrealDB's in-memory storage engine (`memory`). RocksDB SST file compaction and filesystem volume permissions are verified in container lifecycle testing (VS4).
