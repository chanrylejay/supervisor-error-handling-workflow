-- ═══════════════════════════════════════════════════════════════
-- SUPERVISOR V1 LEAN — COMPLETE DATABASE SCHEMA (R22 FINAL)
-- FOR: Neon PostgreSQL (free tier compatible)
-- LAST UPDATED: 2026-05-26
-- ═══════════════════════════════════════════════════════════════

-- TABLE 1: circuit_state
CREATE TABLE IF NOT EXISTS circuit_state (
  circuit_key    TEXT PRIMARY KEY,
  status         TEXT NOT NULL DEFAULT 'closed'
                   CHECK (status IN ('closed', 'open', 'half_open')),
  error_count    INTEGER NOT NULL DEFAULT 0,
  opened_at      TIMESTAMPTZ,
  half_open_at   TIMESTAMPTZ,
  last_error_at  TIMESTAMPTZ,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO circuit_state (circuit_key, status, error_count)
VALUES ('supervisor', 'closed', 0)
ON CONFLICT (circuit_key) DO NOTHING;

-- TABLE 2: supervisor_events
CREATE TABLE IF NOT EXISTS supervisor_events (
  id             BIGSERIAL PRIMARY KEY,
  trace_id       TEXT NOT NULL,
  event_type     TEXT NOT NULL
                   CHECK (event_type IN (
                     'error_alert',
                     'error_self_loop',
                     'error_debounced',
                     'circuit_transition',
                     'heartbeat',
                     'orphan_detected',
                     'retention_completed',
                     'delivery_failure'
                   )),
  workflow_name   TEXT,
  execution_id    TEXT,
  failed_node     TEXT,
  severity        TEXT NOT NULL DEFAULT 'info'
                   CHECK (severity IN ('info', 'warning', 'error', 'critical')),
  status          TEXT NOT NULL DEFAULT 'processed',
  fingerprint     TEXT,
  payload         JSONB DEFAULT '{}'::jsonb,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- TABLE 3: schema_versions
CREATE TABLE IF NOT EXISTS schema_versions (
  version     TEXT PRIMARY KEY,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO schema_versions (version)
VALUES ('v1_lean')
ON CONFLICT (version) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════
-- INDEXES (7 total)
-- ═══════════════════════════════════════════════════════════════

-- 1: event type + time (System Status agg, Retention cleanup)
CREATE INDEX IF NOT EXISTS idx_supervisor_events_type_created
  ON supervisor_events (event_type, created_at DESC);

-- 2: fingerprint lookup (Atomic Circuit Update fp_context)
CREATE INDEX IF NOT EXISTS idx_supervisor_events_fingerprint
  ON supervisor_events (fingerprint, created_at DESC)
  WHERE fingerprint IS NOT NULL;

-- 3: status filtering (error aggregation)
CREATE INDEX IF NOT EXISTS idx_supervisor_events_status
  ON supervisor_events (status, created_at DESC);

-- 4: workflow grouping (top error sources)
CREATE INDEX IF NOT EXISTS idx_supervisor_events_workflow
  ON supervisor_events (workflow_name, failed_node, created_at DESC)
  WHERE event_type = 'error_alert';

-- 5: trace ID forensics
CREATE INDEX IF NOT EXISTS idx_supervisor_events_trace_id
  ON supervisor_events (trace_id);

-- 6: orphan dedup
CREATE UNIQUE INDEX IF NOT EXISTS idx_supervisor_events_orphan_dedup
  ON supervisor_events (event_type, execution_id, trace_id)
  WHERE event_type = 'orphan_detected';

-- 7: fp_context performance (R18)
-- NOTE: CONCURRENTLY cannot run inside a transaction.
-- Run this statement SEPARATELY if your client auto-wraps in BEGIN/COMMIT.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_supervisor_events_fp_context
  ON supervisor_events (fingerprint, event_type, status, created_at DESC)
  WHERE event_type = 'error_alert' AND status = 'processed';

-- ═══════════════════════════════════════════════════════════════
-- VERIFICATION QUERY — run after deployment
-- Expected: 3 tables, v1_lean present, closed circuit, 7+ indexes
-- ═══════════════════════════════════════════════════════════════

SELECT
  (SELECT COUNT(*) FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN ('circuit_state', 'supervisor_events', 'schema_versions')
  ) AS tables_found,
  (SELECT COUNT(*) FROM schema_versions WHERE version = 'v1_lean') AS schema_version_present,
  (SELECT status FROM circuit_state WHERE circuit_key = 'supervisor') AS circuit_status,
  (SELECT COUNT(*) FROM pg_indexes
   WHERE schemaname = 'public'
     AND tablename IN ('supervisor_events', 'circuit_state')
  ) AS index_count;
