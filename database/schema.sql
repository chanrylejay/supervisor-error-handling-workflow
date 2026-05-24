-- ═══════════════════════════════════════════════════════════════
-- SUPERVISOR V1 LEAN — DATABASE SCHEMA
-- ═══════════════════════════════════════════════════════════════
--
-- Project:     Supervisor V1 Lean
-- Author:      Chan (Chanryle Jay Cagara)
-- Created:     2026-05-24
-- Database:    Neon PostgreSQL free tier (Singapore, pooled, PG 17)
--
-- Tables:      3  (down from 7 in V23)
-- Indexes:     6  (down from 17 in V23)
-- Constraints: 3  (down from 6 in V23)
--
-- V23 tables removed:
--   ❌ error_logs        — Only consumer was AI SearchLogsTool
--   ❌ alert_log         — Dedup handled by staticData debounce
--   ❌ pending_approvals — Approval buttons never worked (n8n limitation)
--   ❌ dead_letter_queue — Cache + heartbeat replaces DLQ
--
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────
-- TABLE 1: circuit_state
-- ─────────────────────────────────────────────────────────────
-- Purpose: Postgres-backed circuit breaker (single row).
--          Tracks error count and state transitions.
--
-- States:
--   closed    → Normal operation. Errors increment error_count.
--   open      → Triggered at 5 errors. All new errors suppressed.
--   half_open → Recovery probe. Next error reopens, silence closes.
--
-- Recovery:
--   open → half_open:  Heartbeat probe after 5 min without errors
--   half_open → closed: Heartbeat probe after 10 min without errors
--   open → closed:     Data Retention safety valve after 1 hour
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS circuit_state (
    circuit_key   TEXT        PRIMARY KEY,
    status        TEXT        NOT NULL DEFAULT 'closed',
    error_count   INTEGER     NOT NULL DEFAULT 0,
    opened_at     TIMESTAMPTZ,
    half_open_at  TIMESTAMPTZ,
    last_error_at TIMESTAMPTZ,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT circuit_status_valid
        CHECK (status IN ('closed', 'open', 'half_open'))
);


-- ─────────────────────────────────────────────────────────────
-- TABLE 2: supervisor_events
-- ─────────────────────────────────────────────────────────────
-- Purpose: Lightweight audit trail for all supervisor activity.
--          Used for trend detection, debugging, and reporting.
--
-- Event types:
--   error_alert        — Error received and Telegram alert sent
--   error_debounced    — Error suppressed by 30s debounce window
--   error_self_loop    — Error from monitoring workflow, suppressed
--   circuit_transition — Circuit state changed (e.g. closed→open)
--   circuit_breaker    — Circuit opened, all errors now suppressed
--   orphan_detected    — Long-running execution found (>30 min)
--   heartbeat          — System status report (logged on change)
--   retention_completed— Data cleanup finished
--   alert_failed       — Telegram delivery failed (cached)
--
-- Retention: 90 days (enforced by Data Retention workflow)
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS supervisor_events (
    id            BIGSERIAL   PRIMARY KEY,
    trace_id      TEXT,
    event_type    TEXT        NOT NULL,
    workflow_name TEXT,
    execution_id  TEXT,
    failed_node   TEXT,
    severity      TEXT        NOT NULL DEFAULT 'info',
    status        TEXT,
    fingerprint   TEXT,
    payload       JSONB,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT events_severity_valid
        CHECK (severity IN ('info', 'warning', 'error', 'critical')),

    CONSTRAINT events_type_valid
        CHECK (event_type IN (
            'error_alert',
            'error_debounced',
            'error_self_loop',
            'circuit_transition',
            'circuit_breaker',
            'orphan_detected',
            'heartbeat',
            'retention_completed',
            'alert_failed'
        ))
);


-- ─────────────────────────────────────────────────────────────
-- TABLE 3: schema_versions
-- ─────────────────────────────────────────────────────────────
-- Purpose: Migration tracking. One row per deployed version.
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS schema_versions (
    version     TEXT        PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    description TEXT
);


-- ─────────────────────────────────────────────────────────────
-- INDEXES
-- ─────────────────────────────────────────────────────────────
-- 6 indexes (down from 17 in V23)
--
-- Design principles:
--   - created_at DESC for retention cleanup and trend queries
--   - event_type for heartbeat trend detection subqueries
--   - fingerprint for debounce-related lookups
--   - trace_id for debugging specific error chains
--   - execution_id for per-execution event history
--   - Partial unique index on orphan_detected for dedup
-- ─────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_events_created_at
    ON supervisor_events (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_events_event_type
    ON supervisor_events (event_type);

CREATE INDEX IF NOT EXISTS idx_events_fingerprint
    ON supervisor_events (fingerprint);

CREATE INDEX IF NOT EXISTS idx_events_trace_id
    ON supervisor_events (trace_id);

CREATE INDEX IF NOT EXISTS idx_events_execution_id
    ON supervisor_events (execution_id);

-- Partial unique index: prevents duplicate orphan events
-- for the same execution within a single detection cycle
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_orphan_dedup
    ON supervisor_events (event_type, execution_id)
    WHERE event_type = 'orphan_detected';


-- ─────────────────────────────────────────────────────────────
-- INITIAL DATA
-- ─────────────────────────────────────────────────────────────

-- Initialize circuit breaker in closed state
INSERT INTO circuit_state (circuit_key, status, error_count)
VALUES ('supervisor', 'closed', 0)
ON CONFLICT (circuit_key) DO NOTHING;

-- Record schema version
INSERT INTO schema_versions (version, description)
VALUES (
    'v1_lean',
    'Supervisor V1 Lean: clean rebuild from V23. 3 workflows, 46 nodes, 3 tables. Zero AI cost.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- POST-DEPLOY VERIFICATION
-- ═══════════════════════════════════════════════════════════════
-- Run these queries to verify successful deployment:
--
--   SELECT * FROM circuit_state;
--   -- Expected: 1 row, status='closed', error_count=0
--
--   SELECT * FROM schema_versions;
--   -- Expected: 1 row, version='v1_lean'
--
--   SELECT COUNT(*) FROM supervisor_events;
--   -- Expected: 0 (fresh install)
--
--   SELECT indexname FROM pg_indexes
--   WHERE tablename = 'supervisor_events'
--   ORDER BY indexname;
--   -- Expected: 6 indexes
--
-- ═══════════════════════════════════════════════════════════════
-- END OF SCHEMA
-- ═══════════════════════════════════════════════════════════════
