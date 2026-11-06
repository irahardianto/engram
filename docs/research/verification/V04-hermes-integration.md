# Verification Report: Hermes MemoryProvider Integration Research (V04)

**Target Under Review:** [`docs/research/04-hermes-integration.md`](../04-hermes-integration.md) (R4)  
**Primary Source:** Hermes Agent v0.22.4 (`~/.hermes/hermes-agent`)  
**Context Source:** [`DISCOVERY_HANDOFF.md`](../../../DISCOVERY_HANDOFF.md)  
**Verifier:** Independent Principal Engineer Verifier  
**Verification Date:** October 2026  

---

## 1. Summary Verdict

**Verdict: PASS-WITH-FIXES**

### High-Level Evaluation
Report R4 is exceptionally detailed, highly knowledgeable, and demonstrates remarkable forensic accuracy regarding Hermes's internal codebase (tag `v0.22.4`). Almost every single file-and-line citation across `agent/memory_manager.py`, `agent/memory_provider.py`, `plugins/memory/__init__.py`, `agent/secret_scope.py`, and `pyproject.toml` was verified to be line-exact against the primary source.

However, the report suffers from **two architectural flaws** and **three critical code-level bugs** in its recommended Python plugin skeleton:
1. **Architectural Flaw — The Prefetch 1-Turn Lag & Cold-Start Blindness (BLOCKER):** R4's insistence that `prefetch()` must *never* make network calls and must *only* drain an in-memory cache populated by `queue_prefetch()` at the end of the prior turn introduces a severe 1-turn lag. On cold starts (turn 1), `prefetch()` returns empty context (`""`), and on subsequent turns it returns memories recalled for the *previous* turn's prompt, not the user's current query. Because Engram is a local Rust daemon on NVMe taking ~10–25ms per hybrid search, and Hermes gives `prefetch()` an 8.0s timeout on a dedicated thread, `prefetch(query)` should query synchronously (or with a join timeout) on the *current* prompt.
2. **Architectural Flaw — Unjustified SQLite Write-Behind Queue (MAJOR):** R4 copied RetainDB's `_WriteQueue` pattern without recognizing that Hermes's `MemoryManager.sync_all` already runs `sync_turn` on a single-worker background executor (`mem-sync`). A local SQLite queue in Python introduces redundant double-backgrounding, multi-threaded connection management bugs, and violates the goal of a lean HTTP client. The local Rust service backed by SurrealDB should own persistence and durability directly.
3. **Critical Code Bug — `on_memory_write` Drops All Deletions (MAJOR):** In `EngramMemoryProvider.on_memory_write`, the code checks `if not content.strip(): return`. In Hermes's memory tool mirror, a `remove` operation sets `content = ""` and passes the deleted text in `metadata["previous_content"]`. R4's code silently ignores and drops all memory deletions.
4. **Code Bug — SQLite Connection Leak & Race in `queue.py` (MAJOR):** `_get_conn()` calls `sqlite3.connect()` on every operation without closing connections (context manager on sqlite3 only manages transactions, not connection lifecycle). Furthermore, `_replay_crashed()` is called after `self._thread.start()`, creating an initialization race condition.
5. **Scope Omission — Dropped Tools from Specification (MAJOR):** DISCOVERY_HANDOFF §6.7 requires five explicit tools (`engram_recall`, `engram_remember`, `engram_forget`, `engram_entities`, `engram_status`). R4 only declared and implemented three, omitting `engram_entities` and `engram_status`.

---

## 2. Findings Table

| ID | Severity | Location | Claim in R4 | Evidence in Primary Source | Recommended Fix |
|---|---|---|---|---|---|
| **F-01** | **BLOCKER** | R4 §1 (line 22), §2 (line 41), §7 (line 817) | Hybrid search is computed in background during prior turn's `queue_prefetch()`. `prefetch()` merely reads and drains local in-memory cache (<1ms). Never run hybrid retrieval in `prefetch()`. | In [`run_agent.py:920-921`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/run_agent.py#L920-L921), `queue_prefetch` runs on the *completed* turn's query. If `prefetch` only drains that cache, Turn 1 injects *nothing* (cold start blindness), and Turn N injects memories for Turn N-1's question! In [`agent/memory_manager.py:358-396`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L358-L396), Hermes allocates 8.0s on a dedicated thread (`memory-prefetch-{name}`) specifically so providers can query on the *current* prompt. Hindsight ([`hindsight-integrations/hermes/__init__.py:1788-1793`](https://github.com/vectorize-io/hindsight/blob/b4a0da1e9fd2dfd052843e4f95fcf368301f6a73/hindsight-integrations/hermes/__init__.py#L1788-L1793)) and ByteRover ([`plugins/memory/byterover/__init__.py:212-218`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/plugins/memory/byterover/__init__.py#L212-L218)) execute recall synchronously on `prefetch(query)`. | Execute `self._client.recall(query)` directly in `prefetch(query)`. Since Engram runs locally on NVMe, hybrid search takes 10–25ms, well under the 8.0s timeout. Eliminate the 1-turn lag. |
| **F-02** | **MAJOR** | R4 §1 (line 23), §5.1 (line 295), §6.3 (line 413) | Turns must be enqueued into a local SQLite write-behind queue in Python (`queue.py`) with a dedicated daemon thread to prevent blocking `sync_turn`. | In [`agent/memory_manager.py:470-489`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L470-L489), `sync_all` wraps `sync_turn` in `_submit_background`, which runs on a single-worker `DaemonThreadPoolExecutor(max_workers=1, thread_name_prefix="mem-sync")`. `sync_turn` is **already** asynchronous and serialized! RetainDB needed SQLite because it talks to a remote cloud WAN. Engram is a local Rust daemon. Adding SQLite in Python adds redundant double-threading and disk I/O. | Remove `queue.py` and the SQLite database entirely. Inside `sync_turn()`, make a direct HTTP POST to `http://127.0.0.1:8080/v1/ingest/turn`. Since it runs on `mem-sync`, it does not block the user. The Rust service commits the episode immediately to SurrealDB to own durability. |
| **F-03** | **MAJOR** | R4 §6.4 (line 666) | In `EngramMemoryProvider.on_memory_write`: `if self._agent_context != "primary" or not self._queue or not content.strip(): return` | In [`agent/memory_manager.py:814`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L814) and [`tools/memory_tool.py:150`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/tools/memory_tool.py#L150), when an entry is removed, `content` is empty string (`""`) and the text of the removed entry is passed in `metadata["previous_content"]`. Checking `not content.strip()` causes all `remove` actions to be silently dropped! | Change condition to: `target_text = content.strip() or (metadata or {}).get("previous_content", "").strip(); if not target_text: return`. |
| **F-04** | **MAJOR** | R4 §6.3 (lines 443-450, 487-514) | Persistent SQLite queue implementation (`EngramWriteQueue`). | 1) `_get_conn()` opens a new `sqlite3.connect()` on every call inside `with self._get_conn() as conn:`. In Python, `with conn:` manages transactions, NOT connection closing. File descriptors leak continuously. 2) In `__init__`, `self._thread.start()` is called *before* `self._replay_crashed()`, causing new enqueued turns to race ahead of replayed crashed turns. | If SQLite queue is kept, use `threading.local` and proper connection closing like RetainDB, and replay *before* starting the worker thread. (Better: remove SQLite queue per F-02). |
| **F-05** | **MAJOR** | R4 §6.4 (lines 705-772) | Declares only three tools: `engram_recall`, `engram_remember`, `engram_forget`. | [`DISCOVERY_HANDOFF.md:270-276`](../../../DISCOVERY_HANDOFF.md#L270-L276) §6.7 explicitly mandates five tools: `engram_recall`, `engram_remember`, `engram_forget`, `engram_entities`, and `engram_status`. Milestone M0 and M4 acceptance criteria depend on `engram_status` and `engram_entities`. | Add `engram_entities` (graph inspection) and `engram_status` (health, counts, schema version, queue depth) to `get_tool_schemas()` and `handle_tool_call()`. |
| **F-06** | **MINOR** | R4 §6.5 (lines 795, 796) | Table 6.5 claims `on_session_switch` calls `POST /v1/sessions/switch` and `on_delegation` calls `POST /v1/observations/delegation`. | Neither `EngramClient` (§6.2) nor `EngramMemoryProvider` (§6.4) implements these HTTP endpoints or methods. `on_delegation` is completely missing from the Python code in §6.4. | Update `EngramClient` and `EngramMemoryProvider` to implement `on_delegation` and session switch endpoints, or remove them from Table 6.5 if they are handled locally. |
| **F-07** | **MINOR** | R4 §2 (line 52), §6.4 (lines 692-704) | Pre-compress checkpoint API v2 implementation in `on_pre_compress`. | 1) If `require_checkpoint=False` and an exception occurs, `on_pre_compress` returns `None` instead of `str` (`""`). 2) Developer guide ([`memory-provider-plugin.md:280-286`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/website/docs/developer-guide/memory-provider-plugin.md#L280-L286)) explicitly mandates that checkpoints **must be idempotent** (content-hashed and upserted) to handle retries after fail-closed blocks. R4 omitted this requirement. | Return `""` on caught exception when `require_checkpoint=False`. Ensure checkpoint endpoint in Rust and client computes a transcript digest for idempotent upsert. |
| **F-08** | **MINOR** | R4 §6.4 (line 765) | `res = self._client._client.delete(f"/v1/facts/{fact_id}", timeout=5.0).json()` in `handle_tool_call` | 1) Direct access to private `_client._client` bypasses client abstraction. 2) `fact_id` is interpolated into URL without URL encoding (`urllib.parse.quote`), which breaks SurrealDB record IDs containing colons or slashes (e.g. `asserts:ulid_123`). 3) Does not check `resp.raise_for_status()`. | Add `forget_fact(self, fact_id: str)` to `EngramClient` with `urllib.parse.quote(fact_id, safe="")` and call it from `handle_tool_call`. |
| **F-09** | **MINOR** | R4 §4.1 (line 163) | Discovery heuristic `_is_memory_provider_dir` reads `__init__.py`. | Fails to emphasize that if `__init__.py` is missing, `_is_memory_provider_dir` returns `False` immediately without checking AST or `plugin.yaml`. | Add clear note: `$HERMES_HOME/plugins/engram/__init__.py` is strictly mandatory for discovery. |
| **F-10** | **NIT** | R4 §2 (line 41), §7 (line 817) | `_StuckCallGate` closes if 4 calls exceed timeout. | Missing `_MAX_INFLIGHT_CALLS = 16` ([`memory_manager.py:57`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L57)), which acts as a hard cap on in-flight calls regardless of whether probe interval has elapsed. | Note the 16 in-flight call ceiling in the gate specification. |
| **F-11** | **NIT** | R4 §4.2 (line 173) | Manifest example uses `hooks: [on_turn_start, ...]`. | While [`hermes_cli/plugins_manifest.py:557`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/hermes_cli/plugins_manifest.py#L557) supports legacy `hooks:`, the canonical manifest v2 field is `provides_hooks:`. | Use canonical `provides_hooks:` in `plugin.yaml`. |

---

## 3. Deep-Dive Forensic Verification of Focal Questions

### 1. Prefetch Timeout (8.0s) & Stuck-Call Gate Thresholds
**Claim in R4:** 8.0s hard timeout ([`memory_manager.py:42`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L42)); gate closes after 4 stuck calls ([`memory_manager.py:51`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L51)); 60s probe interval.  
**Verification:**
- [`agent/memory_manager.py:42`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L42): `_EXTERNAL_PREFETCH_TIMEOUT_S = 8.0`. **VERIFIED.**
- [`agent/memory_manager.py:51`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L51): `_MAX_STUCK_CALLS = 4`. **VERIFIED.**
- [`agent/memory_manager.py:54`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L54): `_PROBE_INTERVAL_S = 60.0`. **VERIFIED.**
- [`agent/memory_manager.py:46`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L46): `_BACKGROUND_CALL_STALL_S = 30.0`. **VERIFIED.**
- **Nuance/Omission:** [`agent/memory_manager.py:57`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L57) defines `_MAX_INFLIGHT_CALLS = 16`. If 16 calls are in flight, the gate closes unconditionally, rejecting even probe calls. Also, stuck calls are counted only if `start > last_ok and now > deadline`: a single successful call resets the gate.

### 2. Is `sync_turn` Already Backgrounded on `mem-sync`? Is SQLite Write-Behind Justified?
**Claim in R4:** `sync_turn` must be non-blocking; turns must be enqueued into a local SQLite table in Python so that Hermes doesn't block.  
**Verification:**
- In [`agent/memory_manager.py:441-473`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L441-L473), `MemoryManager.sync_all` wraps the provider's `sync_turn` call inside `self._submit_background(...)`.
- Lines 481–486 instantiate:
  ```python
  self._sync_executor = DaemonThreadPoolExecutor(max_workers=1, thread_name_prefix="mem-sync")
  ```
- **Conclusion:** `sync_turn` is **ALREADY** executed on a serialized background worker (`mem-sync`). The caller thread (`run_agent.py:918`) returns immediately!
- **Architectural Verdict on SQLite Queue:**
  - RetainDB implemented `_WriteQueue` because it communicated with a remote cloud API (`https://api.retaindb.com`) over the public internet, where network partitions and outages are common.
  - Engram is a local service daemon communicating over `http://127.0.0.1:8080` on high-speed NVMe.
  - An HTTP call to localhost takes 2–5 ms. The Rust service can append the raw episode to SurrealDB immediately within that request.
  - Introducing a local SQLite database (`queue.db`) in Python adds:
    1. Redundant double-backgrounding (`mem-sync` -> Python SQLite -> `engram-writer` -> HTTP -> Tokio).
    2. Connection leak bugs (see F-04).
    3. Shutdown race conditions (Hermes drains `mem-sync` in 5.0s, but Python's custom writer thread is not tracked by Hermes's drain).
    4. Code bloat in Python, contrary to the design principle that the Python plugin is a *thin HTTP client*.
  - **Recommendation:** Cut `queue.py` entirely. Issue direct HTTP requests inside `sync_turn()`. Since it runs inside `mem-sync`, it will never block user interaction.

### 3. Pre-Compress Checkpoint API v2 Contract
**Verification against [`agent/conversation_compression.py:2889-2925`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/conversation_compression.py#L2889-L2925) and [`agent/memory_manager.py:693-733`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L693-L733):**
- **Opt-in mechanism:** Class attribute `pre_compress_checkpoint_api_version = PRE_COMPRESS_CHECKPOINT_API_VERSION` (2).
- **Handoff data:** `evidence_messages` (direct user/assistant text, tool outputs and prior summaries stripped) is passed to `on_pre_compress` **as the first positional parameter `messages`**, NOT as a keyword argument!
- **Keyword arguments:** If the method accepts `require_checkpoint` (checked via `inspect.signature`), `require_checkpoint=True` is passed when `compression.checkpoint_required: true`.
- **Return value:** Must return a `str` of insights to inject into the summary prompt (`""` if none).
- **Failure semantics:** When `require_checkpoint=True`, the method **MUST** raise an exception on failure. When raised, `conversation_compression.py:2917` raises `CompressionCheckpointUnavailable` (`BLOCKED_MISSING_PREREQUISITE`), halting compaction and preserving the raw uncompressed transcript.
- **Idempotency requirement:** [`memory-provider-plugin.md:280-286`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/website/docs/developer-guide/memory-provider-plugin.md#L280-L286) mandates that checkpoints **must be idempotent** (keyed by content/transcript hash) because retries will replay the same transcript. R4 missed this requirement.

### 4. Egress Redaction via `redact_for_egress`
**Claim in R4:** `MemoryManager` scrubs all queries, turns, messages, and tool arguments before handing them to providers.  
**Verification:**
Every single call site in [`agent/memory_manager.py`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py) was checked:
- Line 351 (`prefetch_all`): `clean_query = _redact_for_provider(clean_query)` -> **COVERED**
- Line 428 (`queue_prefetch_all`): `clean_query = _redact_for_provider(clean_query)` -> **COVERED**
- Line 458 (`sync_all`): `clean_user_content, assistant_content, redacted_messages = _redact_for_provider(...)` -> **COVERED**
- Line 602 (`handle_tool_call`): `args = _redact_for_provider(args)` -> **COVERED**
- Line 616 (`on_turn_start`): `message = _redact_for_provider(message)` -> **COVERED**
- Line 629 (`on_session_end`): `messages = _redact_messages_for_egress(messages or [])` -> **COVERED**
- Line 708 (`on_pre_compress`): `messages, evidence_messages = _redact_for_provider(messages or [], evidence_messages)` -> **COVERED**
- Line 749 (`on_memory_write`): `content, metadata = _redact_for_provider(content, dict(metadata or {}))` -> **COVERED**
- Line 832 (`on_delegation`): `task, result = _redact_for_provider(task, result)` -> **COVERED**
- In [`agent/redact.py:1164-1176`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/redact.py#L1164-L1176), `redact_for_egress` handles secret patterns and bearer tokens, failing closed (`REDACTION_UNAVAILABLE`).
- Lines 132–135 of `memory_manager.py` implement cross-propagation: a secret detected anywhere in a batch is scrubbed everywhere in that batch.
- **Verdict:** Claim is **100% VERIFIED-CORRECT**.

### 5. Plugin Discovery Precedence & `_is_memory_provider_dir`
**Verification against [`plugins/memory/__init__.py:1-132`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/plugins/memory/__init__.py#L1-L132):**
- Precedence order: Bundled -> User (`$HERMES_HOME/plugins/`) -> Project (`./.hermes/plugins/`) -> Package entry points (`hermes_agent.memory_providers`). Reverse of general plugins (first-seen wins). **VERIFIED.**
- Heuristic in `_is_memory_provider_dir(path: Path)`:
  1. Checks `(path / "__init__.py").exists()`. If missing, returns `False` immediately.
  2. Reads first 8192 bytes of `__init__.py`. Checks for `"register_memory_provider"` or `"MemoryProvider"`.
  3. Falls back to AST parsing of `*.py` files in `path` via `_defines_memory_provider(path)`.
  4. Does not import any Python code during discovery.
- **Verdict:** Verified exact.

### 6. Config Location & Secret Resolution
**Verification:**
- Settings live in `config.yaml` under `memory.engram.*`. Read via `from hermes_cli.config import load_config_readonly`. **VERIFIED.**
- Secrets live in `$HERMES_HOME/.env`. Read via `from agent.secret_scope import get_secret`. **VERIFIED.**
- Under multiplexing (`is_multiplex_active() == True`), reading a secret without an active scope raises `UnscopedSecretError` ([`agent/secret_scope.py:252`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/secret_scope.py#L252)).
- Any background thread must be created using `spawn_context_thread(...)` from `agent.memory_provider` to propagate `ContextVar` state. **VERIFIED.**

### 7. Availability of HTTP Libraries in Core Environment
**Verification against [`pyproject.toml:51, 61, 105`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/pyproject.toml#L51) and execution in `~/.hermes/tools/python-3.14.7+20260901-linux-x64/bin/python3`:**
- `httpx==0.28.1` (with socks support) — **CONFIRMED PRE-INSTALLED.**
- `requests==2.33.0` — **CONFIRMED PRE-INSTALLED.**
- `urllib3==2.8.0` — **CONFIRMED PRE-INSTALLED.**
- Recommendation for Engram plugin to have `dependencies = []` and directly import `httpx` is **100% SOUND AND VERIFIED.**

### 8. `on_session_switch` & `commit_session_boundary_async` Ordering
**Verification against [`agent/memory_manager.py:633-665`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L633-L665):**
- When `/new` executes, `commit_session_boundary_async` captures `snapshot = list(messages or [])` and submits a single task to `_submit_background` (`mem-sync` worker).
- In that worker, `self.on_session_end(snapshot)` executes strictly *before* `self.on_session_switch(new_session_id, ..., reset=True)`.
- This eliminates the race condition where session buffers were rebound before end-of-session fact extraction finished. **VERIFIED.**

### 9. Tool Schema Registration & `handle_tool_call`
**Verification against [`agent/memory_manager.py:284, 313-325, 590-612`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L284):**
- Function schemas must match OpenAI format (`{"name", "description", "parameters"}`).
- Names in `_HERMES_CORE_TOOLS` are rejected. Provider tools must be namespaced (`engram_*`). **VERIFIED.**
- Handler must return a valid JSON string (`tool_error(...)` on exception). **VERIFIED.**
- Kwargs passing: `handle_tool_call` receives `hermes_home`, `agent_identity`, and `caller_gsk` (from [`inline_tool_executors.py:333`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/inline_tool_executors.py#L333)). **VERIFIED.**

### 10. Missed Items in Developer Guide and Engine
1. **Prefetch Spill Mechanism:** Hermes supports `memory.prefetch_spill_enabled: true` and `spill_if_oversized(...)` ([`agent/memory_manager.py:403`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L403), [`developer-guide/memory-provider-plugin.md:190-215`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/website/docs/developer-guide/memory-provider-plugin.md#L190-L215)). External prefetch is capped at 100,000 characters by default, above which it spills to a temp file.
2. **CLI Subcommand Conventions (`cli.py`):** Providers can ship a `cli.py` with `register_cli(subparser)` to expose `hermes engram <subcommand>` directly in the Hermes CLI.
3. **Skill Registration via Context:** In `register(ctx)`, memory providers can call `ctx.register_skill(...)` to expose bundled domain skills (e.g. `engram:maintenance`).
4. **Idempotency Requirement for Pre-Compress Checkpoints:** Explicitly required by doc line 280, omitted by R4.

---

## 4. Verified-Correct Claims (Brief)

The following claims in R4 were checked line-by-line and verified exact against primary source code:
- **`MemoryProvider` ABC & methods:** [`agent/memory_provider.py:84-226`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_provider.py#L84-L226).
- **`MemoryManager` class structure & single-external-provider rule:** [`agent/memory_manager.py:196-931`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L196-L931), line 271.
- **`is_available()` call sites & synchronous constraint:** [`agent/agent_init.py:1363`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/agent_init.py#L1363), [`hermes_cli/doctor_state.py:610`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/hermes_cli/doctor_state.py#L610).
- **`unavailable_reason()` call site:** [`agent/agent_init.py:1369`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/agent_init.py#L1369).
- **`initialize()` call sites:** [`agent/agent_init.py:1373`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/agent_init.py#L1373), [`agent/memory_manager.py:929`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L929).
- **`system_prompt_block()` call site:** [`agent/memory_manager.py:338`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L338).
- **`prefetch()` call site & thread name `memory-prefetch-{name}`:** [`agent/turn_context.py:929`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/turn_context.py#L929), [`agent/memory_manager.py:369, 375`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L369).
- **`queue_prefetch()` call site & trivial prompt gate:** [`run_agent.py:921`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/run_agent.py#L921), [`agent/memory_manager.py:431`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L431).
- **`recall_status()` & `describe_recall()`:** [`agent/turn_context.py:934`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/turn_context.py#L934), [`agent/memory_manager.py:413`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L413).
- **`sync_turn()` call site:** [`run_agent.py:918`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/run_agent.py#L918), [`agent/memory_manager.py:468`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L468).
- **`shutdown()` call site & 5.0s drain timeout:** [`agent/memory_manager.py:41, 861`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L41).
- **`on_turn_start()` call site:** [`agent/turn_context.py:921`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/turn_context.py#L921), [`agent/memory_manager.py:622`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L622).
- **`identity_signature()` call site on uninitialized provider:** [`gateway/run_agent_cache.py:95`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/gateway/run_agent_cache.py#L95).
- **`on_session_end()` call site:** [`agent/memory_manager.py:630`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L630).
- **`on_session_switch()` call sites:** [`cli_session_mixin.py:656`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/hermes_cli/cli_session_mixin.py#L656), [`agent/memory_manager.py:677`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L677).
- **`on_pre_compress()` call sites:** [`agent/conversation_compression.py:2911`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/conversation_compression.py#L2911), [`agent/memory_manager.py:721`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L721).
- **`on_memory_write()` call sites & `patch` translation:** [`agent/inline_tool_executors.py:154`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/inline_tool_executors.py#L154), [`agent/memory_manager.py:758, 815-824`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L758).
- **`on_delegation()` call site:** [`tools/delegate_tool_results.py:353`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/tools/delegate_tool_results.py#L353), [`agent/memory_manager.py:835`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L835).
- **`get_config_schema()` and `save_config()`:** [`hermes_cli/web_server_memory.py:166`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/hermes_cli/web_server_memory.py#L166), [`hermes_cli/web_routers/memory_providers.py:463, 465-470, 473-493`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/hermes_cli/web_routers/memory_providers.py#L463).
- **`backup_paths()` call site:** [`hermes_cli/backup.py:254`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/hermes_cli/backup.py#L254).
- **`spawn_context_thread` & `UnscopedSecretError`:** [`agent/secret_scope.py:252`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/secret_scope.py#L252), [`agent/memory_provider.py:29-33`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_provider.py#L29-L33).
- **Core HTTP dependencies (`httpx==0.28.1`, `requests==2.33.0`):** [`pyproject.toml:51, 61`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/pyproject.toml#L51).
- **Reference code citations (RetainDB, ByteRover, Hindsight):** All line citations verified exact against disk files.

---

## 5. Unverifiable Items

- **Rust Service Latency under Live Load:** The assumption that hybrid search over SurrealDB will complete in 10–25ms on NVMe depends on the embedding model latency (e.g. local Ollama vs remote API). If embedding generation takes >500ms, prefetch will take ~550ms (still well within the 8.0s timeout). This will be validated during M2 benchmarks.
- **`gateway.multiplex_profiles` Concurrent Load:** While code paths in `agent/secret_scope.py` and `agent/memory_caller_scope.py` were verified statically, true multi-tenant concurrent profile stress testing requires a running gateway cluster.
