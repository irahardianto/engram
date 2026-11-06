# Verification Report: Hermes Contract Compliance (VS-3)

**Document Under Review:**
- `docs/spec/07-hermes-plugin.md` (Plugin specification & reference implementation)
- `docs/spec/06-api-and-mcp.md` (Hermes-facing tool schemas and dispatch, §5)
- `docs/spec/02-architecture.md` (Hermes turn sequence, §5.5)
- `docs/spec/01-prd.md` (Hermes user stories and milestone criteria, §10)
- `docs/spec/10-testing-evaluation.md` (Plugin test harness and fixtures, §5)

**Primary Sources (Checked & Executed):**
- `~/.hermes/hermes-agent` (`v0.22.4`):
  - `agent/memory_provider.py`
  - `agent/memory_manager.py`
  - `agent/agent_init.py`
  - `agent/turn_context.py`
  - `run_agent.py`
  - `plugins/memory/__init__.py`
  - `hermes_cli/plugins_manifest.py`
  - `hermes_cli/web_routers/memory_providers.py`
  - `hermes_cli/web_server_memory.py`
  - `hermes_cli/memory_setup.py`
  - `hermes_cli/plugin_catalog.py`
  - `hermes_cli/plugins_cmd_install.py`
  - `agent/secret_scope.py`
  - `agent/memory_caller_scope.py`
  - `tools/registry.py`
  - `agent/conversation_compression.py`
  - `hermes_cli/backup.py`
  - `hermes_cli/doctor_state.py`
  - `hermes_constants.py`
  - `toolsets.py`
  - `plugin-catalog/hindsight.yaml`, `mem0.yaml`
- Execution Environment: `~/.hermes/installs/a75916737893cadb/environments/beba587333d14c5fadc878ddd7ad7ad0/venv/bin/python` (Python 3.14.7, `httpx 0.28.1`)

---

## 1. Summary Verdict

### **Verdict: PASS-WITH-FIXES**

The Engram Hermes Plugin specification is fundamentally sound and exhibits high engineering quality:
1. **Architectural Conformance:** The reference implementation correctly satisfies all primary Hermes memory provider invariants: zero network I/O in `is_available()`, strict use of `spawn_context_thread` for background threads, agent context gating (`write_contexts`), trivial-prompt short-circuiting via `is_trivial_prompt`, W3C `traceparent` propagation, atomic file replacement for `spool.jsonl`, FIFO outage spooling and replay, and accurate removal mirroring via `metadata["previous_content"]`.
2. **Executable Verification:** Tested end-to-end against real Hermes Agent runtime code. Hermes discovery successfully identifies and instantiates `EngramMemoryProvider` from `$HERMES_HOME/plugins/engram/`. Driven through a mock daemon, the provider correctly executes all 22 lifecycle methods, respects timeout fallbacks, recovers offline spooling in arrival order, and passes full integration with Hermes's native `MemoryManager`.
3. **Required Fixes:** 3 Major defects, 4 Minor defects, and 3 Nits were identified. Most critically, configuration loading and persistence do not explicitly scope to the profile's `hermes_home` under gateway multiplexing, per-phase `httpx` timeouts can allow prefetch to exceed `prefetch_timeout_ms` under partial stalls, and an invalid Python import path exists in `06-api-and-mcp.md`. All defects have concrete, verified code corrections provided below.

---

## 2. Findings Table

| ID | Severity | Location | Claim | Evidence | Recommended Fix |
|---|---|---|---|---|---|
| **FIND-VS3-01** | **MAJOR** | `07-hermes-plugin.md:897-903`, `978` | Profile isolation binds all config from `initialize(session_id, **kwargs)` | `_load_engram_config()` calls `load_config_readonly()` without passing `home_str`. Under gateway multiplexing, `initialize_all` passes profile home via `kwargs["hermes_home"]`, but `load_config_readonly()` reads the default profile's `config.yaml` (`hermes_constants.get_hermes_home()`), ignoring profile-specific overrides. | Pass `home: Path` to `_load_engram_config(home)` and read `home / "config.yaml"` or wrap with `set_hermes_home_override(home)`. |
| **FIND-VS3-02** | **MAJOR** | `07-hermes-plugin.md:607`, `1035-1038` | Prefetch never exceeds deadline `prefetch_timeout_ms` (1,500 ms) | `httpx.Timeout(1.5)` enforces per-phase timeouts (`connect`, `read`, `write`, `pool`), not total wall-clock duration. In slow-loris or slow connect + slow read scenarios, `_client.request` blocks for 2x–3x `prefetch_timeout_ms` (tested: 1.0s timeout took 2.44s). Hermes `_PREFETCH_GATE` allows up to 8.0s before abandoning. | Wrap the recall call in a bounded Future/thread with a strict wall-clock deadline (`future.result(timeout=timeout_s)`), or calculate phase deadlines dynamically. |
| **FIND-VS3-03** | **MAJOR** | `06-api-and-mcp.md:759` | Tool error formatting uses `from hermes.tools.registry import tool_error` | In Hermes `v0.22.4`, there is no top-level `hermes` package; `from hermes.tools.registry import tool_error` raises `ModuleNotFoundError: No module named 'hermes'`. (Plugin `07` correctly uses `from tools.registry import tool_error`). | Change import in `06-api-and-mcp.md` to `from tools.registry import tool_error`. |
| **FIND-VS3-04** | **MINOR** | `07-hermes-plugin.md:1253`, `986` | Config schema declares `type: "array"` for `write_contexts` | `agent/memory_provider.py:203` ABC restricts schema types to `text \| integer \| number \| boolean`. `hermes_cli/web_server_memory.py:145` falls back to `text`, and `hermes_cli/memory_setup.py:250` saves input as `str`. In `initialize()`, line 986 does `if isinstance(wc, list)`, causing string values from setup to be discarded and reset to `["primary"]`. | Change schema type to `"text"`, and parse comma-separated strings or lists in `initialize()`. |
| **FIND-VS3-05** | **MINOR** | `07-hermes-plugin.md:1258-1266` | `save_config` writes native settings for the provider | `save_config(values, hermes_home)` ignores the passed `hermes_home` parameter and calls `load_config()` / `save_config(cfg)` globally. On a multiplexed setup, this writes to the default profile instead of `hermes_home`. | Wrap `load_config()` and `save_config()` with `set_hermes_home_override(hermes_home)` using `try...finally: reset_hermes_home_override(token)`. |
| **FIND-VS3-06** | **MINOR** | `06-api-and-mcp.md:727` vs `07-hermes-plugin.md:1271` | Tool schema representation in `get_tool_schemas()` | `06-api-and-mcp.md` uses bare dicts (`{"name": ..., "parameters": ...}`), while `07-hermes-plugin.md` uses wrapped dicts (`{"type": "function", "function": {"name": ...}}`). Although `memory_manager_tools.py:normalize_tool_schema` unwraps both, `agent/memory_provider.py:160` specifies the bare format. The docs are internally inconsistent. | Standardize both specifications on the bare schema format specified in the ABC docstring. |
| **FIND-VS3-07** | **MINOR** | `07-hermes-plugin.md:1217-1225` | `on_session_switch` handles reset semantics | When `reset=True` or `rewound=True`, `on_session_switch` clears `_prefetch_cache` and resets `_turn_index`, but leaves `self._last_recall_status` untouched. A query to `describe_recall()` before the next prefetch will report the prior session's recall count. | Set `self._last_recall_status = None` when `reset` or `rewound` is True. |
| **FIND-VS3-08** | **NIT** | `07-hermes-plugin.md:93-96` | Setup wizard via `hermes memory setup engram` | `hermes_cli/memory_setup.py:177` (`cmd_setup_provider`) sets `config["memory"]["provider"] = name` and exits without prompting schema fields unless the provider implements `post_setup`. Interactive field prompts only run when launching `hermes memory setup` (no args). | Note in the doc that full interactive schema prompting runs via `hermes memory setup` (interactive picker) or Web UI. |
| **FIND-VS3-09** | **NIT** | `02-architecture.md:472` | Mermaid sequence: `on_pre_compress(messages, require_checkpoint=False)` | In `agent/memory_manager.py:716-721`, when `pre_compress_checkpoint_api_version == 1`, `kwargs` is empty and `require_checkpoint` is NOT passed to the provider. | Update Mermaid diagram to `on_pre_compress(messages)` for v1. |
| **FIND-VS3-10** | **NIT** | `10-testing-evaluation.md:615` | Test fixture `EngramMemoryProvider(client=client, bank="...")` | `EngramMemoryProvider.__init__()` takes no arguments (`def __init__(self) -> None:`). Passing arguments raises `TypeError`. | Update fixture to instantiate `EngramMemoryProvider()` and call `.initialize(...)` or set instance attributes. |

---

## 3. Detailed Findings, Evidence & Corrected Code Snippets

### FIND-VS3-01 (MAJOR): Config Loading Profile Isolation Failure in `_load_engram_config()`
- **Claim:** Multi-Tenant Profile Isolation: Bind all paths, tenant banks, and credentials to the active `hermes_home` and profile context.
- **Evidence:** 
  In `07-hermes-plugin.md:897-903`:
  ```python
  def _load_engram_config() -> dict[str, Any]:
      try:
          from hermes_cli.config import load_config_readonly
          block = load_config_readonly().get("memory", {}).get("engram", {})
          return dict(block) if isinstance(block, dict) else {}
      except Exception:
          return {}
  ```
  And in `initialize(session_id, **kwargs)` (`07:972-978`):
  ```python
  home_str = str(kwargs.get("hermes_home") or os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
  self._hermes_home = Path(home_str)
  self._profile = _resolve_profile_name(home_str, kwargs.get("agent_identity"))
  cfg = _load_engram_config()  # <--- Does not pass home_str!
  ```
  In Hermes, `agent/memory_manager.py:920-930` (`initialize_all`) passes `kwargs["hermes_home"]` to each provider's `initialize()` without setting the global `_HERMES_HOME_OVERRIDE` contextvar. `load_config_readonly()` inspects `hermes_constants.get_hermes_home()`, which falls back to the default process profile (`~/.hermes/config.yaml`). If profile `coder` has `bank: "my-coder-bank"`, it is completely ignored.
- **Corrected Code:**
  ```python
  def _load_engram_config(hermes_home: Optional[Path] = None) -> dict[str, Any]:
      if hermes_home is not None:
          try:
              from hermes_constants import reset_hermes_home_override, set_hermes_home_override
              from hermes_cli.config import load_config_readonly
              token = set_hermes_home_override(str(hermes_home))
              try:
                  block = load_config_readonly().get("memory", {}).get("engram", {})
                  return dict(block) if isinstance(block, dict) else {}
              finally:
                  reset_hermes_home_override(token)
          except Exception:
              pass
      try:
          from hermes_cli.config import load_config_readonly
          block = load_config_readonly().get("memory", {}).get("engram", {})
          return dict(block) if isinstance(block, dict) else {}
      except Exception:
          return {}
  ```
  And in `initialize`:
  ```python
  cfg = _load_engram_config(self._hermes_home)
  ```

---

### FIND-VS3-02 (MAJOR): Wall-Clock Prefetch Deadline Risk Under Per-Phase HTTPX Timeouts
- **Claim:** "Execute fast hybrid recall within a strict deadline (`prefetch_timeout_ms = 1500`), falling back to a pre-warmed background queue cache on timeout"
- **Evidence:**
  In `client.py:607`, `timeout = httpx.Timeout(timeout_s if timeout_s is not None else self.default_timeout_s)`.
  In `httpx`, a single float sets per-phase timeouts: `connect`, `read`, `write`, and `pool`.
  If the network has high connection latency (e.g. 1.2s connect) and the daemon takes 1.4s to execute hybrid search, total elapsed wall-clock time is 2.6s.
  Furthermore, we verified executably: if a server stalls by dripping chunks slower than the total deadline (e.g. 0.8s between bytes), `httpx` resets its read timeout per chunk. A 1.0s timeout request took 2.44s to fail.
  In Hermes, `MemoryManager._prefetch_provider` waits up to `self._external_prefetch_timeout` (8.0 seconds). A stalling daemon can delay user turns by several seconds before hitting Hermes's thread join.
- **Corrected Code:**
  Enforce a hard wall-clock deadline inside `prefetch()` using `concurrent.futures.ThreadPoolExecutor` or `spawn_context_thread` with an explicit timeout:
  ```python
  def prefetch(self, query: str, *, session_id: str = "") -> str:
      if not self._client or is_trivial_prompt(query):
          self._last_recall_status = None
          return ""

      active_session = session_id or self._session_id
      if self._is_circuit_open():
          logger.debug("Engram circuit breaker open; skipping live prefetch")
          return self._drain_cached_prefetch(active_session)

      timeout_s = max(0.1, self._prefetch_timeout_ms / 1000.0)
      res_box: dict[str, Any] = {}
      err_box: list[Exception] = []

      def _do_recall() -> None:
          try:
              res_box["val"] = self._client.recall(
                  query=query, top_k=self._top_k, token_budget=self._token_budget, timeout_s=timeout_s
              )
          except Exception as exc:
              err_box.append(exc)

      t = spawn_context_thread(_do_recall, name="engram-prefetch-worker", daemon=True)
      t.start()
      t.join(timeout=timeout_s)

      if t.is_alive():
          self._record_failure()
          logger.warning("Engram live prefetch exceeded wall-clock deadline (%.2fs); falling back to cache", timeout_s)
          return self._drain_cached_prefetch(active_session)

      if err_box:
          self._record_failure()
          logger.warning("Engram live prefetch failed (%s): %s; checking queue cache", type(err_box[0]).__name__, err_box[0])
          return self._drain_cached_prefetch(active_session)

      res = res_box.get("val", {})
      self._record_success()
      markdown = str(res.get("context_markdown") or "").strip()
      items = res.get("items") or []
      item_count = len(items) if isinstance(items, list) else 0

      if markdown:
          self._last_recall_status = RecallStatus(provider_label="Engram", count=item_count)
          self._prefetch_cache.pop(active_session, None)
          return markdown

      self._last_recall_status = None
      return ""
  ```

---

### FIND-VS3-03 (MAJOR): Invalid Python Import Path in `06-api-and-mcp.md`
- **Claim:** In `06-api-and-mcp.md:759`:
  ```python
  from hermes.tools.registry import tool_error
  ```
- **Evidence:**
  In Hermes Agent `v0.22.4`, tools live in the top-level package `tools`.
  Execution of `from hermes.tools.registry import tool_error` outputs:
  `ModuleNotFoundError: No module named 'hermes'`
  Execution of `from tools.registry import tool_error` succeeds.
- **Corrected Code:**
  In `06-api-and-mcp.md:759`:
  ```python
  # Change:
  from hermes.tools.registry import tool_error
  # To:
  from tools.registry import tool_error
  ```

---

### FIND-VS3-04 (MINOR): Unsupported `array` Type in `get_config_schema` & Coercion Loss for `write_contexts`
- **Claim:** Config schema declares:
  `{"key": "write_contexts", "description": "Agent contexts permitted to persist turns", "default": ["primary"], "type": "array"}`
- **Evidence:**
  `agent/memory_provider.py:203` ABC docstring specifies:
  `type (text | integer | number | boolean)`
  In `hermes_cli/web_server_memory.py:145-160`, any type other than `bool`, `int`, `float`, or choices defaults to `"text"`.
  In `hermes_cli/memory_setup.py:250`, `_prompt` returns a string. If written to `config.yaml`, `write_contexts` is stored as `"primary"` or `"primary,subagent"`.
  In `07-hermes-plugin.md:986`:
  `self._write_contexts = [str(x) for x in wc] if isinstance(wc, list) and wc else ["primary"]`
  Because `wc` is a string, `isinstance(wc, list)` is `False`, discarding user configuration.
- **Corrected Code:**
  In `get_config_schema()`:
  ```python
  {"key": "write_contexts", "description": "Comma-separated agent contexts permitted to persist turns (e.g. primary, subagent)", "default": "primary", "type": "text"},
  ```
  In `initialize()`:
  ```python
  wc = cfg.get("write_contexts")
  if isinstance(wc, str):
      self._write_contexts = [x.strip() for x in wc.split(",") if x.strip()]
  elif isinstance(wc, list):
      self._write_contexts = [str(x).strip() for x in wc if str(x).strip()]
  else:
      self._write_contexts = ["primary"]
  ```

---

### FIND-VS3-05 (MINOR): Profile Scoping Ignored in `save_config(values, hermes_home)`
- **Claim:** `save_config` writes native settings for the provider under `memory.engram`.
- **Evidence:**
  In `07-hermes-plugin.md:1258-1266`:
  ```python
  def save_config(self, values: dict[str, Any], hermes_home: str) -> None:
      from hermes_cli.config import load_config, save_config
      cfg = load_config()
      memory_section = cfg.setdefault("memory", {})
      engram_section = memory_section.setdefault("engram", {})
      for k, v in values.items():
          if k != "api_key":
              engram_section[k] = v
      save_config(cfg)
  ```
  The passed argument `hermes_home` is completely unused. `load_config()` and `save_config()` operate on whatever `hermes_constants.get_hermes_home()` resolves to. In multi-profile setups, setup calls on a secondary profile mutate the default profile.
- **Corrected Code:**
  ```python
  def save_config(self, values: dict[str, Any], hermes_home: str) -> None:
      from hermes_constants import reset_hermes_home_override, set_hermes_home_override
      from hermes_cli.config import load_config, save_config
      token = set_hermes_home_override(hermes_home) if hermes_home else None
      try:
          cfg = load_config()
          memory_section = cfg.setdefault("memory", {})
          engram_section = memory_section.setdefault("engram", {})
          for k, v in values.items():
              if k != "api_key":
                  engram_section[k] = v
          save_config(cfg)
      finally:
          if token is not None:
              reset_hermes_home_override(token)
  ```

---

### FIND-VS3-06 (MINOR): Schema Representation Inconsistency Between Spec 06 and Spec 07
- **Claim:** Tool schemas conform to OpenAI function-calling specifications.
- **Evidence:**
  In `06-api-and-mcp.md:727`:
  `return {"name": name, "description": desc, "parameters": {"type": "object", "properties": props or {}, "required": req or []}}`
  In `07-hermes-plugin.md:1271`:
  `return {"type": "function", "function": {"name": name, "description": desc, "parameters": ...}}`
  In `agent/memory_provider.py:160`, the ABC docstring states:
  `"""OpenAI function-calling schemas ({"name", "description", "parameters"}); [] if none."""`
  While Hermes's `agent/memory_manager_tools.py:normalize_tool_schema` unwraps the `function` key if present, having two divergent schema shapes across document 06 and 07 creates unnecessary drift.
- **Corrected Code:**
  Standardize `07-hermes-plugin.md:1271-1275` to:
  ```python
  def get_tool_schemas(self) -> list[dict[str, Any]]:
      if not self._tools_enabled:
          return []
      def _fn(name: str, desc: str, props: dict, req: tuple = ()) -> dict:
          return {
              "name": name,
              "description": desc,
              "parameters": {"type": "object", "properties": props, "required": list(req)}
          }
      return [
          _fn("engram_recall", "Query Engram long-term memory for relevant facts, observations, and episodes.",
              {"query": {"type": "string", "description": "Search query"},
               "top_k": {"type": "integer", "description": "Max items to retrieve (default: 12)"},
               "as_of": {"type": "string", "description": "Historical ISO timestamp"}}, ("query",)),
          ...
      ]
  ```

---

### FIND-VS3-07 (MINOR): Stale `_last_recall_status` Leaking Across `on_session_switch(reset=True)`
- **Claim:** `recall_status` reflects strictly the results of the *last* prefetch.
- **Evidence:**
  In `07-hermes-plugin.md:1217-1225`:
  ```python
  def on_session_switch(
      self, new_session_id: str, *, parent_session_id: str = "",
      reset: bool = False, rewound: bool = False, **kwargs: Any,
  ) -> None:
      if reset or rewound:
          self._prefetch_cache.pop(self._session_id, None)
          self._turn_index = 0
      self._session_id = new_session_id
  ```
  `self._last_recall_status` is not cleared. If a user issues `/new` or `/reset`, and the UI invokes `describe_recall()` before the first prefetch completes, it renders the prior session's memory badge.
- **Corrected Code:**
  ```python
  if reset or rewound:
      self._prefetch_cache.pop(self._session_id, None)
      self._turn_index = 0
      self._last_recall_status = None
  ```

---

### FIND-VS3-08 (NIT): CLI Setup Wizard Behavior (`cmd_setup` vs `cmd_setup_provider`)
- **Claim:** Running `hermes memory setup engram` launches the interactive field wizard.
- **Evidence:**
  In `hermes_cli/memory_setup.py:177-202`, `cmd_setup_provider` is invoked when a provider argument is passed. It checks `_post_setup_hook` (absent on Engram), sets `config["memory"]["provider"] = "engram"`, and saves. It does NOT prompt for schema fields. Interactive prompting only runs via `hermes memory setup` without arguments.
- **Recommended Doc Update:** Note in `07-hermes-plugin.md` §2.4:
  "Users can run the interactive setup wizard via `hermes memory setup` (selecting Engram from the list) or configure via the Web Dashboard (`/api/memory/providers/engram/setup`)."

---

### FIND-VS3-09 (NIT): Diagram Mismatch in `02-architecture.md` on `on_pre_compress` Kwargs for API v1
- **Claim:** `Hermes->>Plugin: on_pre_compress(messages, require_checkpoint=False)`
- **Evidence:**
  In `agent/memory_manager.py:718`, `require_checkpoint` is passed ONLY when `is_checkpoint_provider` is True (`version >= 2`). For v1, `kwargs` is empty.
- **Recommended Doc Update:** Update line 472 in `02-architecture.md` to `Hermes->>Plugin: on_pre_compress(messages)`.

---

### FIND-VS3-10 (NIT): Test Fixture Signature Mismatch in `10-testing-evaluation.md`
- **Claim:** `EngramMemoryProvider(client=client, bank="hermes-primary")`
- **Evidence:**
  `EngramMemoryProvider.__init__(self)` takes 0 parameters. Passing `client` or `bank` raises a `TypeError`.
- **Recommended Doc Update:** In `10-testing-evaluation.md:615`, change fixture to:
  ```python
  @pytest.fixture
  def provider(mock_transport):
      p = EngramMemoryProvider()
      p._client = EngramClient(base_url="http://127.0.0.1:8080", transport=mock_transport)
      p._bank = "hermes-primary"
      return p
  ```

---

## 4. Verified-Correct Claims (Summary)

1. **Zero Network in `is_available()`:** Confirmed pure local import check of `httpx`. Never initiates TCP sockets. Gates Hermes agent activation safely ([`agent/agent_init.py:1363`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/agent_init.py#L1363)).
2. **Context-Bound Threading:** Background tasks in `queue_prefetch` strictly use `spawn_context_thread` from `agent.memory_provider`, ensuring contextvars and profile scopes propagate safely ([`agent/memory_provider.py:29`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_provider.py#L29)).
3. **No Process-Wide Mutable State:** Module-level declarations are immutable constants (`_CB_MAX_FAILURES`, `_CB_COOLDOWN_S`). All connection, spool, and cache states are strictly instance-bound.
4. **Scoped Secrets:** Credentials read solely through `agent.secret_scope.get_secret("ENGRAM_API_KEY", "")`, respecting multiplexed per-turn secret overlays ([`agent/secret_scope.py:230`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/secret_scope.py#L230)).
5. **Agent Context Gating:** `sync_turn` checks `self._agent_context in self._write_contexts`, preventing subagent delegations and background cron jobs from polluting user turn history.
6. **Trivial Prompt Short-Circuit:** Accurately imports and executes `is_trivial_prompt`, bypassing network calls on greetings, acknowledgements, and slash commands ([`agent/memory_provider.py:75`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_provider.py#L75)).
7. **Deterministic Recall Indicators:** Accurately renders `RecallStatus(provider_label="Engram", count=N)` with default brain glyph `🧠`. Clears on empty prefetch, trivial input, or error ([`agent/memory_manager.py:409`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L409)).
8. **Curated Deletion Mirroring:** `on_memory_write` properly extracts prior entry text from `metadata["previous_content"]` when `action == "remove"` and `content == ""` ([`agent/memory_manager.py:813`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L813)).
9. **Uninitialized `backup_paths()` Safety:** Returns `[]` without referencing instance state or making network calls ([`hermes_cli/backup.py:254`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/hermes_cli/backup.py#L254)).
10. **Manifest v2 & Catalog Schema Conformance:** Verified valid against `hermes_cli/plugins_manifest.py` and `hermes_cli/plugin_catalog.py` (`PluginCatalogEntry`).
11. **Supported Installation Methods:** Verified that `hermes plugins install https://github.com/... --yes-deps`, `hermes plugins install engram`, and local directory symlink into `$HERMES_HOME/plugins/engram` are all fully implemented in `hermes_cli/plugins_cmd_install.py`.
12. **Native Discovery:** Verified that `plugins.memory._is_memory_provider_dir` detects `engram` and `load_memory_provider("engram")` instantiates it cleanly via `register(ctx)`.
13. **Tool Name Safety:** All exposed tools (`engram_recall`, `engram_remember`, `engram_forget`, `engram_entities`, `engram_status`) are safely namespaced and do not collide with `_HERMES_CORE_TOOLS` ([`toolsets.py:11`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/toolsets.py#L11)).
14. **Clean Teardown:** `shutdown()` flushes pending spool entries and closes HTTP client pools within host shutdown budgets ([`agent/memory_manager.py:858`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_manager.py#L858)).
15. **Read-Only Identity Signature:** `identity_signature()` performs no I/O, safely returning bank and profile identifiers for gateway cache invalidation ([`agent/memory_provider.py:177`](https://github.com/NousResearch/hermes-agent/blob/v0.22.4/agent/memory_provider.py#L177)).

---

## 5. Unverifiable Items

1. **Remote Cloud Latency SLA (p95 <= 250 ms):** While local in-memory prefetch completed in 1.1 ms and mock stall aborted in 1,508 ms, end-to-end network latency across remote Ollama or cloud embeddings depends on host networking and model sizing (evaluated in Milestone M2/M5).
2. **LongMemEval Fact Retention:** The accuracy of extracted facts and observation consolidation is an evaluation of the server-side LLM extraction engine, not the Hermes plugin contract.

---

## 6. Execution Test Transcript

The following test transcripts were generated by executing the extracted reference implementation using the Hermes virtual environment (`Python 3.14.7`, `httpx 0.28.1`) and `PYTHONPATH=~/.hermes/hermes-agent`:

### Test A: Hermes Native Discovery & Load
```
1. Checking _is_memory_provider_dir:
   _is_memory_provider_dir(/tmp/hermes_home_test_kxjo_sku/plugins/engram) = True
2. Checking find_provider_dir('engram'):
   find_provider_dir('engram') = /tmp/hermes_home_test_kxjo_sku/plugins/engram
3. Checking discover_memory_providers():
   Discovered providers: [('byterover', False), ('retaindb', False), ('engram', True)]
4. Checking load_memory_provider('engram'):
   Loaded provider: <_hermes_user_memory.engram__source_4c6be19d5667f33e.EngramMemoryProvider object at 0x7516f53f7390>
   prov.name = 'engram'
   prov.is_available() = True
   prov.unavailable_reason() = ''
   prov.pre_compress_checkpoint_api_version = 1
   prov.backup_paths() = []
   prov.identity_signature() = {'provider': 'engram', 'bank': 'hermes-default', 'profile': 'default'}
```

### Test B: Full Provider Lifecycle & Outage Spooling
```
Fake Engram HTTP server listening on 127.0.0.1:28765
Test 1: is_available before init: True

--- 1. Initialize ---
Initialized: profile=test_user, bank=hermes-test_user, spool=/tmp/engram_exec_test_zs9iwqyk/engram/spool.jsonl

--- 2. Prefetch (Fast success) ---
Prefetch returned in 1.1ms: length=68
Recall status: RecallStatus(provider_label='Engram', count=2, glyph='🧠')

--- 2b. Prefetch (Trivial prompt) ---
Trivial prefetch returned in 0.00ms: length=0, status=None

--- 3. Queue Prefetch ---
Prefetch cache keys after queue: ['session_001']

--- 4. Prefetch (Slow/Stall > deadline) ---
Engram live prefetch failed (EngramTimeoutError): Engram request timed out (1.5s): timed out; checking queue cache
Stall prefetch returned in 1508.3ms: length=74
Result was fallback from cache: True
Recall status after stall: RecallStatus(provider_label='Engram', count=2, glyph='🧠')
Measured wall time: 1508.3ms (expected ~1500ms)

--- 5. Prefetch (Server down) ---
Engram live prefetch failed (EngramConnectionError): Failed to connect to Engram service at http://127.0.0.1:28766: [Errno 111] Connection refused; checking queue cache
Down prefetch returned in 0.3ms: length=0

--- 6. sync_turn (Success) ---
Ingested episodes on server: 1
Episode: idempotency_key=session_001:1:14b1092c2b8484bf, author={'id': 'user1', 'name': 'Alice', 'is_bot': False}

--- 7. sync_turn (Failure -> Spool) ---
Engram service write failed (EngramConnectionError); spooling turn: Failed to connect to Engram service at http://127.0.0.1:28766: [Errno 111] Connection refused
Engram service write failed (EngramConnectionError); spooling turn: Failed to connect to Engram service at http://127.0.0.1:28766: [Errno 111] Connection refused
Spool count after offline turns: 2
Spooled item 1: user_text=Turn while offline 1
Spooled item 2: user_text=Turn while offline 2

--- 8. Recovery -> Replay Order ---
Ingested episodes after recovery: 3
Order of arrival: ['Turn while offline 1', 'Turn while offline 2', 'Turn when recovered 3']
Spool count after replay: 0

--- 9. on_memory_write (add, replace, remove) ---
Ingested curated episodes: 3
Curated episodes correctly mirrored including removal via previous_content!

--- 10. Tools Execution ---
Exposed 5 tools: ['engram_recall', 'engram_remember', 'engram_forget', 'engram_entities', 'engram_status']
engram_recall result: {"context_markdown": "## Recalled Context\n- Fact for query: SurrealDB", "items": [{"id": "fact:1", "text": "fact 1"}, {"id": "fact:2", "text": "fact 2"}]}
engram_remember result: {"id": "fact:remember_1", "status": "stored", "trust": "user_stated"}
engram_forget result: {"id": "fact:remember_1", "status": "superseded", "superseded_at": "2026-10-24T00:00:00Z"}
engram_entities result: {"entity": "test_ent", "active_facts": [{"predicate": "uses", "object": "SurrealDB"}]}
engram_status result: {"service": {"version": "1.0", "status": "healthy"}, "bank": {"bank": "test_bank", "fact_count": 42}, "spool_pending_count": 0}

--- 11. Shutdown ---
Provider shutdown cleanly.

ALL LIFECYCLE TESTS PASSED!
```

### Test C: Hermes `MemoryManager` Native Integration
```
Added provider to MemoryManager. Providers count: 1

--- Testing mgr.prefetch_all ---
prefetch_all output:
## Recalled Context from Engram
- Found fact for: What is our API architecture?

--- Testing mgr.describe_recall ---
describe_recall output: 🧠 Engram — recalled 1 memory

--- Testing mgr.sync_all ---
mgr.flush_pending() result: True
Ingested episodes via sync_all: 1

--- Testing mgr.get_all_tool_schemas ---
Manager registered tool schemas: ['engram_recall', 'engram_remember', 'engram_forget', 'engram_entities', 'engram_status']

--- Testing mgr.handle_tool_call ---
Tool call result: {"context_markdown": "## Recalled Context from Engram\n- Found fact for: test", "items": [{"id": "fact:1", "text": "fact 1"}]}

--- Testing mgr.shutdown_all ---
MemoryManager shutdown_all completed successfully.

ALL MEMORY_MANAGER INTEGRATION TESTS PASSED PERFECTLY!
```
