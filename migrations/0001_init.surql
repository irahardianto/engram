-- ==============================================================================
-- Engram Database Migration: 0001_init.surql
-- Target Engine: SurrealDB 3.3.4
-- Description: Core schema definition for per-bank database in Engram.
-- Templated Parameters:
--   {{EMBED_DIM}} - Fixed vector dimension for HNSW indexes (default: 1024)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Full-Text BM25 Analyzer
-- Language-neutral analyzer supporting English and Indonesian.
-- Omits language-specific stemmers (such as snowball(english)) to prevent
-- phonetic/morphological corruption of Indonesian stems and compound technical terms.
-- ------------------------------------------------------------------------------
DEFINE ANALYZER OVERWRITE engram_analyzer 
  TOKENIZERS class 
  FILTERS lowercase, ascii;

-- ------------------------------------------------------------------------------
-- 2. Metadata Singleton Table (`meta:bank`)
-- Records per-bank configuration, schema level, embedding dimension, and
-- active index pointers for seamless re-embedding migrations.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE meta SCHEMAFULL;
DEFINE FIELD OVERWRITE schema_version     ON meta TYPE int;
DEFINE FIELD OVERWRITE bank_id            ON meta TYPE string;
DEFINE FIELD OVERWRITE embedding_model    ON meta TYPE string;
DEFINE FIELD OVERWRITE embedding_dim      ON meta TYPE int;
DEFINE FIELD OVERWRITE vocabulary_version ON meta TYPE string;
DEFINE FIELD OVERWRITE timezone           ON meta TYPE string DEFAULT "UTC";
DEFINE FIELD OVERWRITE maintenance        ON meta TYPE option<string>;
DEFINE FIELD OVERWRITE created_at         ON meta TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE updated_at         ON meta TYPE datetime DEFAULT time::now();

-- ------------------------------------------------------------------------------
-- 3. Schema Migrations Ledger Table (`schema_migration`)
-- Tracks applied schema migration scripts per database.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE schema_migration SCHEMAFULL;
DEFINE FIELD OVERWRITE version     ON schema_migration TYPE int;
DEFINE FIELD OVERWRITE name        ON schema_migration TYPE string;
DEFINE FIELD OVERWRITE checksum    ON schema_migration TYPE string;
DEFINE FIELD OVERWRITE applied_at  ON schema_migration TYPE datetime DEFAULT time::now() READONLY;

DEFINE INDEX OVERWRITE schema_migration_version ON schema_migration FIELDS version UNIQUE;

-- ------------------------------------------------------------------------------
-- 4. Session Tracking Table (`session`)
-- Tracks conversational interaction sessions and turn statistics.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE session SCHEMAFULL;
DEFINE FIELD OVERWRITE session_id     ON session TYPE string;
DEFINE FIELD OVERWRITE created_at     ON session TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE last_active_at ON session TYPE datetime DEFAULT time::now();
DEFINE FIELD OVERWRITE ended_at       ON session TYPE option<datetime>;
DEFINE FIELD OVERWRITE turn_count     ON session TYPE int DEFAULT 0 ASSERT $value >= 0;
DEFINE FIELD OVERWRITE metadata       ON session TYPE object FLEXIBLE DEFAULT {};

DEFINE INDEX OVERWRITE session_id_idx     ON session FIELDS session_id UNIQUE;
DEFINE INDEX OVERWRITE session_active_idx ON session FIELDS last_active_at;

-- ------------------------------------------------------------------------------
-- 5. Episode Table (`episode`)
-- Append-only interaction trace and raw context items.
-- Immutable across core content, cryptographic hash, and creation timestamps.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE episode SCHEMAFULL;
DEFINE FIELD OVERWRITE session_id       ON episode TYPE string;
DEFINE FIELD OVERWRITE kind             ON episode TYPE string ASSERT $value IN ["turn", "note", "curated", "delegation", "document"];
DEFINE FIELD OVERWRITE user_text        ON episode TYPE option<string>;
DEFINE FIELD OVERWRITE assistant_text   ON episode TYPE option<string>;
DEFINE FIELD OVERWRITE text             ON episode TYPE string READONLY;
DEFINE FIELD OVERWRITE author           ON episode TYPE option<string>;
DEFINE FIELD OVERWRITE occurred_at      ON episode TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE recorded_at      ON episode TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE content_hash     ON episode TYPE string READONLY;
DEFINE FIELD OVERWRITE idempotency_key  ON episode TYPE string;
DEFINE FIELD OVERWRITE trust            ON episode TYPE string ASSERT $value IN ["user_stated", "user_implied", "assistant_stated", "tool_output", "inferred"];
DEFINE FIELD OVERWRITE embedding        ON episode TYPE option<array<float>>;
DEFINE FIELD OVERWRITE extraction_state ON episode TYPE string DEFAULT "pending" ASSERT $value IN ["pending", "done", "skipped", "failed"];
DEFINE FIELD OVERWRITE metadata         ON episode TYPE object FLEXIBLE DEFAULT {};
DEFINE FIELD OVERWRITE retracted_at     ON episode TYPE option<datetime>;

DEFINE INDEX OVERWRITE episode_session         ON episode FIELDS session_id, occurred_at;
DEFINE INDEX OVERWRITE episode_idempotency_key ON episode FIELDS idempotency_key UNIQUE;
DEFINE INDEX OVERWRITE episode_content_hash    ON episode FIELDS content_hash;
DEFINE INDEX OVERWRITE episode_occurred        ON episode FIELDS occurred_at;
DEFINE INDEX OVERWRITE episode_fts             ON episode FIELDS text FULLTEXT ANALYZER engram_analyzer BM25 HIGHLIGHTS;
DEFINE INDEX OVERWRITE episode_vec             ON episode FIELDS embedding HNSW DIMENSION {{EMBED_DIM}} DIST COSINE TYPE F32 EFC 150 M 12;

-- ------------------------------------------------------------------------------
-- 6. Entity Table (`entity`)
-- Extracted concepts, actors, tools, projects, and entities in the world.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE entity SCHEMAFULL;
DEFINE FIELD OVERWRITE name                 ON entity TYPE string;
DEFINE FIELD OVERWRITE name_key             ON entity TYPE string;
DEFINE FIELD OVERWRITE kind                 ON entity TYPE string DEFAULT "concept" ASSERT $value IN ["person", "organization", "project", "software", "tool", "account", "place", "concept", "event"];
DEFINE FIELD OVERWRITE aliases              ON entity TYPE array<string> DEFAULT [];
DEFINE FIELD OVERWRITE alias_keys           ON entity TYPE array<string> DEFAULT [];
DEFINE FIELD OVERWRITE summary              ON entity TYPE string DEFAULT "";
DEFINE FIELD OVERWRITE embedding            ON entity TYPE option<array<float>>;
DEFINE FIELD OVERWRITE first_seen           ON entity TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE last_seen            ON entity TYPE datetime DEFAULT time::now();
DEFINE FIELD OVERWRITE last_updated         ON entity TYPE datetime DEFAULT time::now();
DEFINE FIELD OVERWRITE mention_count        ON entity TYPE int DEFAULT 1 ASSERT $value >= 0;
DEFINE FIELD OVERWRITE unconsolidated_facts ON entity TYPE int DEFAULT 0 ASSERT $value >= 0;
DEFINE FIELD OVERWRITE confidence           ON entity TYPE float DEFAULT 0.7 ASSERT $value >= 0.0 AND $value <= 1.0;

DEFINE INDEX OVERWRITE entity_name_key     ON entity FIELDS name_key UNIQUE;
DEFINE INDEX OVERWRITE entity_alias_keys   ON entity FIELDS alias_keys;
DEFINE INDEX OVERWRITE entity_name_fts     ON entity FIELDS name FULLTEXT ANALYZER engram_analyzer BM25 HIGHLIGHTS;
DEFINE INDEX OVERWRITE entity_aliases_fts  ON entity FIELDS aliases FULLTEXT ANALYZER engram_analyzer BM25;
DEFINE INDEX OVERWRITE entity_summary_fts  ON entity FIELDS summary FULLTEXT ANALYZER engram_analyzer BM25 HIGHLIGHTS;
DEFINE INDEX OVERWRITE entity_vec          ON entity FIELDS embedding HNSW DIMENSION {{EMBED_DIM}} DIST COSINE TYPE F32 EFC 150 M 12;

-- ------------------------------------------------------------------------------
-- 7. Fact Table (`fact`)
-- Bi-temporal knowledge graph edges connecting entities.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE fact SCHEMAFULL TYPE RELATION IN entity OUT entity ENFORCED;
DEFINE FIELD OVERWRITE predicate          ON fact TYPE string ASSERT $value IN ["is_a", "works_at", "has_role", "reports_to", "located_in", "member_of", "part_of", "owns", "uses", "written_in", "depends_on", "prefers", "scheduled_for", "credentials_for", "related_to"];
DEFINE FIELD OVERWRITE label              ON fact TYPE option<string>;
DEFINE FIELD OVERWRITE polarity           ON fact TYPE string DEFAULT "positive" ASSERT $value IN ["positive", "negative"];
DEFINE FIELD OVERWRITE statement          ON fact TYPE string;
DEFINE FIELD OVERWRITE embedding          ON fact TYPE option<array<float>>;
DEFINE FIELD OVERWRITE valid_from         ON fact TYPE datetime DEFAULT time::now();
DEFINE FIELD OVERWRITE valid_to           ON fact TYPE option<datetime>;
DEFINE FIELD OVERWRITE time_precision     ON fact TYPE string DEFAULT "day" ASSERT $value IN ["exact", "day", "month", "year", "unknown"];
DEFINE FIELD OVERWRITE recorded_at        ON fact TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE expired_at         ON fact TYPE option<datetime>;
DEFINE FIELD OVERWRITE status             ON fact TYPE string DEFAULT "active" ASSERT $value IN ["active", "superseded", "retracted", "pending"];
DEFINE FIELD OVERWRITE contested          ON fact TYPE bool DEFAULT false;
DEFINE FIELD OVERWRITE conflicts_with     ON fact TYPE array<record<fact>> DEFAULT [];
DEFINE FIELD OVERWRITE supersedes         ON fact TYPE option<record<fact>>;
DEFINE FIELD OVERWRITE superseded_by      ON fact TYPE option<record<fact>>;
DEFINE FIELD OVERWRITE trust              ON fact TYPE string ASSERT $value IN ["user_stated", "user_implied", "assistant_stated", "tool_output", "inferred"];
DEFINE FIELD OVERWRITE support            ON fact TYPE int DEFAULT 1 ASSERT $value >= 1;
DEFINE FIELD OVERWRITE confidence         ON fact TYPE float DEFAULT 0.90 ASSERT $value >= 0.0 AND $value <= 1.0;
DEFINE FIELD OVERWRITE source_episodes    ON fact TYPE array<record<episode>> DEFAULT [];
DEFINE FIELD OVERWRITE extractor_version  ON fact TYPE string DEFAULT "v1";

DEFINE INDEX OVERWRITE fact_lookup        ON fact FIELDS in, predicate, status;
DEFINE INDEX OVERWRITE fact_out_lookup    ON fact FIELDS out, predicate, status;
DEFINE INDEX OVERWRITE fact_live          ON fact FIELDS status, valid_to;
DEFINE INDEX OVERWRITE fact_fts           ON fact FIELDS statement FULLTEXT ANALYZER engram_analyzer BM25 HIGHLIGHTS;
DEFINE INDEX OVERWRITE fact_vec           ON fact FIELDS embedding HNSW DIMENSION {{EMBED_DIM}} DIST COSINE TYPE F32 EFC 150 M 12;
DEFINE INDEX OVERWRITE fact_supersedes    ON fact FIELDS supersedes;
DEFINE INDEX OVERWRITE fact_superseded_by ON fact FIELDS superseded_by;
DEFINE INDEX OVERWRITE fact_conflicts     ON fact FIELDS conflicts_with;

-- ------------------------------------------------------------------------------
-- 8. Mentions Table (`mentions`)
-- Provenance graph edges connecting episodes to referenced entities.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE mentions SCHEMAFULL TYPE RELATION IN episode OUT entity ENFORCED;
DEFINE FIELD OVERWRITE created_at ON mentions TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE count      ON mentions TYPE int DEFAULT 1 ASSERT $value >= 1;

DEFINE INDEX OVERWRITE mentions_lookup ON mentions FIELDS in, out;

-- ------------------------------------------------------------------------------
-- 9. Observation Table (`observation`)
-- Higher-level consolidated beliefs synthesized across episodes and facts.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE observation SCHEMAFULL;
DEFINE FIELD OVERWRITE text              ON observation TYPE string;
DEFINE FIELD OVERWRITE embedding         ON observation TYPE option<array<float>>;
DEFINE FIELD OVERWRITE subject           ON observation TYPE option<record<entity>>;
DEFINE FIELD OVERWRITE support           ON observation TYPE int DEFAULT 1 ASSERT $value >= 1;
DEFINE FIELD OVERWRITE evidence          ON observation TYPE array<record<fact | episode>> DEFAULT [];
DEFINE FIELD OVERWRITE confidence        ON observation TYPE float DEFAULT 0.5 ASSERT $value >= 0.0 AND $value <= 1.0;
DEFINE FIELD OVERWRITE valid_from        ON observation TYPE datetime DEFAULT time::now();
DEFINE FIELD OVERWRITE valid_to          ON observation TYPE option<datetime>;
DEFINE FIELD OVERWRITE recorded_at       ON observation TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE expired_at        ON observation TYPE option<datetime>;
DEFINE FIELD OVERWRITE status            ON observation TYPE string DEFAULT "active" ASSERT $value IN ["active", "superseded", "retracted"];
DEFINE FIELD OVERWRITE supersedes        ON observation TYPE option<record<observation>>;
DEFINE FIELD OVERWRITE superseded_by     ON observation TYPE option<record<observation>>;
DEFINE FIELD OVERWRITE extractor_version ON observation TYPE string DEFAULT "v1";

DEFINE INDEX OVERWRITE observation_fts     ON observation FIELDS text FULLTEXT ANALYZER engram_analyzer BM25 HIGHLIGHTS;
DEFINE INDEX OVERWRITE observation_vec     ON observation FIELDS embedding HNSW DIMENSION {{EMBED_DIM}} DIST COSINE TYPE F32 EFC 150 M 12;
DEFINE INDEX OVERWRITE observation_subject ON observation FIELDS subject;
DEFINE INDEX OVERWRITE observation_live    ON observation FIELDS status, valid_to;

-- ------------------------------------------------------------------------------
-- 10. Job Outbox Table (`job`)
-- Durable background task queue written in the same transaction as state changes.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE job SCHEMAFULL;
DEFINE FIELD OVERWRITE kind         ON job TYPE string ASSERT $value IN ["embed", "extract", "consolidate", "reembed"];
DEFINE FIELD OVERWRITE status       ON job TYPE string DEFAULT "pending" ASSERT $value IN ["pending", "running", "completed", "failed", "dead"];
DEFINE FIELD OVERWRITE payload      ON job TYPE object FLEXIBLE DEFAULT {};
DEFINE FIELD OVERWRITE attempts     ON job TYPE int DEFAULT 0 ASSERT $value >= 0;
DEFINE FIELD OVERWRITE max_attempts ON job TYPE int DEFAULT 8 ASSERT $value >= 1;
DEFINE FIELD OVERWRITE priority     ON job TYPE int DEFAULT 0;
DEFINE FIELD OVERWRITE run_after    ON job TYPE datetime DEFAULT time::now();
DEFINE FIELD OVERWRITE lease_until  ON job TYPE option<datetime>;
DEFINE FIELD OVERWRITE claimed_by   ON job TYPE option<string>;
DEFINE FIELD OVERWRITE last_error   ON job TYPE option<string>;
DEFINE FIELD OVERWRITE created_at   ON job TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE updated_at   ON job TYPE datetime DEFAULT time::now();

DEFINE INDEX OVERWRITE job_dispatch ON job FIELDS status, run_after;
DEFINE INDEX OVERWRITE job_lease    ON job FIELDS status, lease_until;

-- ------------------------------------------------------------------------------
-- 11. Audit Log Table (`audit`)
-- Decision trace recording extraction, reconciliation, and administrative actions.
-- ------------------------------------------------------------------------------
DEFINE TABLE OVERWRITE audit SCHEMAFULL;
DEFINE FIELD OVERWRITE at           ON audit TYPE datetime DEFAULT time::now() READONLY;
DEFINE FIELD OVERWRITE actor        ON audit TYPE string DEFAULT "engram" ASSERT $value IN ["engram", "api", "mcp", "hermes", "system"];
DEFINE FIELD OVERWRITE action       ON audit TYPE string;
DEFINE FIELD OVERWRITE target_type  ON audit TYPE string;
DEFINE FIELD OVERWRITE target_id    ON audit TYPE option<string>;
DEFINE FIELD OVERWRITE job          ON audit TYPE option<record<job>>;
DEFINE FIELD OVERWRITE details      ON audit TYPE object FLEXIBLE DEFAULT {};
DEFINE FIELD OVERWRITE trace_id     ON audit TYPE option<string>;
DEFINE FIELD OVERWRITE session_id   ON audit TYPE option<string>;
DEFINE FIELD OVERWRITE reason       ON audit TYPE option<string>;

DEFINE INDEX OVERWRITE audit_retention ON audit FIELDS at;
DEFINE INDEX OVERWRITE audit_target    ON audit FIELDS target_type, target_id;
DEFINE INDEX OVERWRITE audit_action    ON audit FIELDS action;
