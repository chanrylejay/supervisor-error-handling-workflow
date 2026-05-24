-- ═══════════════════════════════════════════════════════════════
-- SUPERVISOR V1 LEAN — DATABASE SCHEMA (FINAL BUILD)
-- ═══════════════════════════════════════════════════════════════
--
-- Project:     Supervisor V1 Lean
-- Author:      Chan (Chanryle Jay Cagara)
-- Created:     2026-05-24
-- Updated:     2026-05-25 (Final Build — 10 review cycles)
-- Database:    Neon PostgreSQL free tier (Singapore, pooled, PG 17)
--
-- Tables:      3  (down from 7 in V23)
-- Indexes:     6  (down from 17 in V23)
-- Constraints: 3  (down from 6 in V23)
--
-- Changes from original V1 Lean schema:
--   ✅ Orphan dedup index uses hourly time-bucketing
--      (allows one orphan event per execution per hour
--      instead of one per execution forever)
--   ✅ All other structures unchanged — the 114 approved
--      workflow changes use jsonb_build_object() and
--      ($1::jsonb)->>'field' patterns that write standard
--      JSONB to the existing payload column
--
-- V23 tables removed (not needed):
--   ❌ error_logs        — Only consumer was AI SearchLogsTool
--   ❌ alert_log         — Dedup handled by staticData debounce
--   ❌ pending_approvals — Approval buttons never worked (n8n limitation)
--   ❌ dead_letter_queue — Local cache + delivery-independent logging replaces DLQ
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
--               Count resets to 1 if last_error_at is >15 min ago
--               (rolling decay — burst detector, not accumulator).
--   open      → Triggered at 5 errors within 15-min window.
--               All new errors suppressed (Merge Circuit Result
--               returns empty array).
--   half_open → Recovery probe. Next error reopens circuit.
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
--   error_alert        — Error received and alert processed
--                        status: 'processed' (normal alert)
--                                'retry_submitted' (auto-retry receipt)
--   error_debounced    — Error suppressed by 30s debounce window
--   error_self_loop    — Error from monitoring workflow, suppressed
--   circuit_transition — Circuit state changed (e.g. closed→open)
--                        Logged inside Atomic Circuit Update CTE
--                        and by Heartbeat recovery probe
--   circuit_breaker    — RESERVED (circuit-open alerts now use
--                        unified path via error_alert with
--                        is_newly_open in payload)
--   orphan_detected    — Long-running execution found (>30 min)
--   heartbeat          — System status report (logged on send)
--   retention_completed— Data cleanup finished
--   alert_failed       — RESERVED (delivery failures handled by
--                        local staticData cache per workflow)
--
-- Retention: 90 days (enforced by Data Retention workflow)
--
-- Insert pattern: All workflows use single-JSON-parameter
--   ($1::jsonb)->>'field' extraction to avoid n8n's
--   queryReplacement comma-split bug (GitHub #14955, #16354)
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
--          Checked by Data Retention workflow for schema
--          presence verification (v1_lean + 3/3 tables).
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
--   - event_type for heartbeat System Status CTE FILTER clauses
--   - fingerprint for debounce-related lookups
--   - trace_id for debugging specific error chains
--   - execution_id for per-execution event history
--   - Partial unique index on orphan_detected with hourly
--     time-bucketing for dedup (allows re-detection per hour)
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
-- for the same execution within the same hour. Allows
-- re-detection hourly so persistent orphans re-alert
-- instead of being silently forgotten after first detection.
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_orphan_dedup
    ON supervisor_events (event_type, execution_id, date_trunc('hour', created_at))
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
    'Supervisor V1 Lean: final build from V23 rebuild. 3 workflows, 50 nodes, 3 tables. Zero AI. $0/month. 114 approved changes across 10 review cycles by 2 independent AI agents.'
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
--   -- Expected: 7 indexes (6 custom + 1 PK)
--   --   idx_events_created_at
--   --   idx_events_event_type
--   --   idx_events_execution_id
--   --   idx_events_fingerprint
--   --   idx_events_orphan_dedup
--   --   idx_events_trace_id
--   --   supervisor_events_pkey
--
--   -- Verify orphan dedup index uses time-bucketing:
--   SELECT indexdef FROM pg_indexes
--   WHERE indexname = 'idx_events_orphan_dedup';
--   -- Expected: contains "date_trunc('hour'::text, created_at)"
--
--   -- Verify CHECK constraints:
--   SELECT conname, consrc FROM pg_constraint
--   WHERE conrelid = 'supervisor_events'::regclass
--   AND contype = 'c';
--   -- Expected: events_severity_valid, events_type_valid
--
-- ═══════════════════════════════════════════════════════════════
-- SECURITY ADVISORY
-- ═══════════════════════════════════════════════════════════════
-- CVE-2026-44789, CVE-2026-44790, CVE-2026-44791 affect
-- n8n versions below 2.20.7. If running n8n 2.12.3, evaluate
-- upgrading before or shortly after deployment. The HTTP
-- Request prototype pollution vulnerability affects 4 HTTP
-- nodes across the supervisor workflows.
--
-- ═══════════════════════════════════════════════════════════════
-- END OF SCHEMA
-- LAST UPDATED: 2026-05-25
-- FINAL BUILD: 10 review cycles, 114 approved changes
-- ═══════════════════════════════════════════════════════════════
