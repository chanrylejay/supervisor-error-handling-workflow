# Supervisor V1 Lean — Deployment Guide

**Project:** Supervisor V1 Lean (Final Build)  
**Author:** Chan (Chanryle Jay Cagara)  
**Last Updated:** 2026-05-25  
**n8n Version:** 2.12.3 (self-hosted, Windows/PowerShell)  
**Audit History:** 10 review cycles, 114 approved changes, 2 AI agents

---

## Overview

This guide covers everything needed to deploy Supervisor V1 Lean from scratch. It incorporates deployment lessons from V23 and all findings from 10 audit rounds.

**Estimated time:** 30–45 minutes for first deployment.

---

## 1. Prerequisites

Before starting, ensure you have:

- [ ] **n8n** self-hosted and running on `http://localhost:5678`
- [ ] **Neon** account (https://neon.tech) with free tier
  - Region: Singapore (aws-ap-southeast-1) recommended for Philippines
  - Use the **pooled** endpoint (not direct)
- [ ] **Telegram Bot** (https://t.me/BotFather)
  - Bot token saved
  - Your chat ID known (use https://t.me/userinfobot to get it)
- [ ] **Healthchecks.io** account (https://healthchecks.io) with free tier
  - Create a check with **Period: 5 minutes** and **Grace: 30 minutes**
  - Copy the ping URL

---

## 2. Database Setup

### Option A: Fresh Install

Run `database/schema.sql` against your Postgres instance:

**Via Neon SQL Editor:**
1. Open your Neon project dashboard
2. Go to **SQL Editor**
3. Paste the contents of `database/schema.sql`
4. Click **Run**

**Via psql:**
```powershell
psql "postgresql://user:pass@your-neon-host/dbname?sslmode=require" -f database/schema.sql
```

### Option B: Existing V23 Database

Just run schema.sql as-is. All statements are idempotent (CREATE IF NOT EXISTS). V23 tables remain but are never touched.

**Optional cleanup** (only after V1 Lean is confirmed stable):
```sql
DROP TABLE IF EXISTS error_logs CASCADE;
DROP TABLE IF EXISTS alert_log CASCADE;
DROP TABLE IF EXISTS pending_approvals CASCADE;
DROP TABLE IF EXISTS dead_letter_queue CASCADE;
```

### Verification

Run these queries to verify deployment:

```sql
-- Should return 1 row: status='closed', error_count=0
SELECT * FROM circuit_state;

-- Should contain: date_trunc('hour'::text, created_at)
SELECT indexdef FROM pg_indexes
WHERE indexname = 'idx_events_orphan_dedup';

-- Should return 1 row: version='v1_lean'
SELECT * FROM schema_versions;

-- Should return 0
SELECT COUNT(*) FROM supervisor_events;

-- Should return 7 indexes (6 custom + 1 PK)
SELECT indexname FROM pg_indexes
WHERE tablename = 'supervisor_events'
ORDER BY indexname;
```

---

## 3. Environment Variables

### Variable Reference

| Variable | Required | Purpose |
|----------|----------|---------|
| NODE_FUNCTION_ALLOW_BUILTIN | Yes | Enables require('crypto') in Code nodes |
| N8N_BLOCK_ENV_ACCESS_IN_NODE | Yes | Enables $env.VARIABLE in Code nodes |
| HEALTHCHECKS_PING_URL | Yes | Dead Man's Switch ping URL |
| SUPERVISOR_WORKFLOW_ID | Yes | Self-loop guard + orphan exclusion |
| HEARTBEAT_WORKFLOW_ID | Yes | Self-loop guard + orphan exclusion |
| RETENTION_WORKFLOW_ID | Yes | Self-loop guard + orphan exclusion |
| TELEGRAM_CHAT_ID | Yes | All Telegram alerts |
| CRITICAL_WORKFLOW_IDS | Yes | Activation monitoring (comma-separated) |
| LONG_RUNNING_WORKFLOW_IDS | Optional | Orphan detection exclusion (comma-separated) |
| NEVER_RETRY_WORKFLOW_IDS | Optional | Auto-retry safety denylist (comma-separated) |
| N8N_CONCURRENCY_PRODUCTION_LIMIT | Optional | Limits concurrent executions (default: 3) |

### Setting Variables

**PowerShell:**
```powershell
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
$env:HEALTHCHECKS_PING_URL = "https://hc-ping.com/your-uuid-here"
$env:TELEGRAM_CHAT_ID = "your-chat-id"
$env:CRITICAL_WORKFLOW_IDS = "id1,id2,id3"
$env:SUPERVISOR_WORKFLOW_ID = "FILL_AFTER_IMPORT"
$env:HEARTBEAT_WORKFLOW_ID = "FILL_AFTER_IMPORT"
$env:RETENTION_WORKFLOW_ID = "FILL_AFTER_IMPORT"

npx n8n
```

> **IMPORTANT:** Use PowerShell `$env:VAR = "value"` syntax. NOT Bash `export`.

> **NOTE:** Workflow IDs are only known after importing. See Section 5.

### PowerShell Execution Policy

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass
```

---

## 4. n8n Credential Setup

### Postgres Credential

| Setting | Value |
|---------|-------|
| Host | Your Neon pooled endpoint |
| Port | 5432 |
| Database | Your database name |
| User | Your Neon username |
| Password | Your Neon password |
| SSL | Allow |

> **Neon gotcha:** Add `connectionTimeout: 10` in Connection Options for cold-start tolerance.

### Telegram Bot Credential

| Setting | Value |
|---------|-------|
| Access Token | Your bot token from BotFather |

### HTTP Header Auth Credential

Used by Heartbeat's orphan detection and activation monitoring to query the n8n API.

| Setting | Value |
|---------|-------|
| Name | X-N8N-API-KEY |
| Value | Your n8n API key (create at localhost:5678/settings/api) |

---

## 5. Workflow Import

### Import Order

1. `workflows/workflow_1_supervisor_core.json`
2. `workflows/workflow_2_heartbeat_monitor.json`
3. `workflows/workflow_3_data_retention.json`

### After Import: Note Workflow IDs

```
http://localhost:5678/workflow/AbCdE123  ← "AbCdE123" is the ID
```

Record all three and update your startup script:

```powershell
$env:SUPERVISOR_WORKFLOW_ID = "AbCdE123"
$env:HEARTBEAT_WORKFLOW_ID = "FgHiJ456"
$env:RETENTION_WORKFLOW_ID = "KlMnO789"
```

Restart n8n after updating env vars.

### Assign Credentials

Open each workflow and assign:

- All Postgres nodes → your Neon credential
- All Telegram nodes → your Telegram Bot credential
- All HTTP Request nodes with auth → your HTTP Header Auth credential

### ⚠️ CRITICAL: Import Corruption Warning

n8n can corrupt IF node output mappings during JSON import. Wires may look correct but route wrong.

**Symptoms:** IF node always takes the wrong branch.

**Fix:** Delete the corrupted IF node, add a new one, recreate conditions and connections.

**Watch these nodes:**

- Is Self Loop? (WF1)
- Is Debounced? (WF1)
- Should Alert Orphans? (WF2)
- Has Recovery Transition? (WF2)
- Has Activation Issue? (WF2)
- Should Send? (WF2)
- Should Notify? (WF3)

---

## 6. Workflow Activation

### Activation Order

1. Data Retention V1 Lean (background cleanup)
2. Heartbeat Monitor V1 Lean (health monitoring)
3. Supervisor Core V1 Lean (error catching)

Within 5 minutes, you should receive your first heartbeat:

```
💓 SUPERVISOR — 🟢 HEALTHY

🟢 Circuit: closed (0/5)
🟢 DMS: ok
...
```

---

## 7. Setting Error Workflows

For every monitored workflow: **Settings → Error Workflow → Supervisor Core V1 Lean**

> **Note:** Error Trigger only fires on PRODUCTION runs, NOT manual test executions. The monitored workflow must be activated.

---

## 8. Smoke Tests

### Test 1: Heartbeat ✅

Activate Heartbeat Monitor. Wait 5 minutes. Check Telegram.

### Test 2: Dead Man's Switch ✅

Check Healthchecks.io dashboard — should show UP with recent ping.

### Test 3: Database ✅

```sql
SELECT * FROM circuit_state;
SELECT * FROM schema_versions;
SELECT COUNT(*) FROM supervisor_events;
```

### Test 4: Error Alert ✅

Create test workflow with `throw new Error('Supervisor smoke test')`. Set Error Workflow to Supervisor Core. Activate and trigger. Check Telegram for alert with probable cause advice.

### Test 5: Debounce ✅

Trigger the test workflow twice within 30 seconds. Only one alert should arrive.

```sql
SELECT event_type, COUNT(*) FROM supervisor_events
WHERE created_at > NOW() - INTERVAL '5 minutes'
GROUP BY event_type;
-- Should show: error_alert (1), error_debounced (1+)
```

### Test 6: Circuit Breaker ✅

Let test workflow fire 5+ times (spaced >30s apart). Watch for escalating "Error X of 5" alerts, then circuit-open banner on the 5th error.

**After test:**
```sql
UPDATE circuit_state SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';
```

### Test 7: Self-Loop Detection ✅

Temporarily set Supervisor Core's Error Workflow to itself. Trigger an error. Check for self-loop alert with execution URL.

### Test 8: Data Retention ✅

Manually execute Data Retention. Check Telegram for retention report (or verify `retention_completed` event in database if report was suppressed as routine).

```sql
SELECT * FROM supervisor_events WHERE event_type = 'retention_completed'
ORDER BY created_at DESC LIMIT 1;
```

### Post-Test Cleanup

```sql
UPDATE circuit_state SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';
```

Deactivate or delete the test workflow.

---

## 9. Troubleshooting

### "No Telegram alert received"

| Check | How |
|-------|-----|
| Bot token correct? | Send a test message via BotFather |
| Chat ID correct? | Use https://t.me/userinfobot |
| Workflow active? | Green toggle must be ON |
| Error Workflow set? | Monitored workflow → Settings → Error Workflow |
| Production run? | Manual executions don't trigger Error Trigger |
| Credentials assigned? | Check each Telegram node has a credential |

### "Heartbeat not sending"

Heartbeat uses MD5 dedup. Identical state = suppressed. A heartbeat sends when:

- State changes (circuit, errors, orphans, DMS, activation)
- Database is unreachable
- Recovery from DEGRADED/CRITICAL to HEALTHY
- First message of the hour (healthy pulse)

**Force a heartbeat:**
```sql
UPDATE circuit_state SET error_count = 1 WHERE circuit_key = 'supervisor';
-- Wait up to 5 min, then reset:
UPDATE circuit_state SET error_count = 0 WHERE circuit_key = 'supervisor';
```

### "Circuit stuck open"

```sql
UPDATE circuit_state SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';
```

The Heartbeat auto-recovers after 5 min, and Retention resets after 1 hour. If stuck, check both are active.

### "Events not being logged"

If `supervisor_events` is empty despite Telegram alerts arriving, check for the queryReplacement comma-split bug. All INSERT nodes should use the single-JSON-parameter pattern (`$1::jsonb`).

**Verify:**
```sql
SELECT event_type, COUNT(*) FROM supervisor_events GROUP BY event_type ORDER BY count DESC;
```

### "$env not accessible" or "crypto is not defined"

```powershell
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
```

Restart n8n after setting these.

### "IF node routes everything to wrong branch"

n8n import corruption. Delete the IF node, add a new one, recreate conditions and connections.

---

## 10. Useful SQL Commands

```sql
-- View circuit state
SELECT * FROM circuit_state WHERE circuit_key = 'supervisor';

-- Reset circuit
UPDATE circuit_state SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';

-- Recent events
SELECT event_type, workflow_name, severity, status, created_at
FROM supervisor_events WHERE created_at > NOW() - INTERVAL '1 hour'
ORDER BY created_at DESC;

-- Error trends
SELECT 
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 hour') AS errors_1h,
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '24 hours') AS errors_24h
FROM supervisor_events WHERE event_type = 'error_alert';

-- Retry activity
SELECT COUNT(*) FROM supervisor_events
WHERE event_type = 'error_alert' AND status = 'retry_submitted'
AND created_at > NOW() - INTERVAL '24 hours';

-- Event distribution
SELECT event_type, status, COUNT(*), MAX(created_at) AS last_seen
FROM supervisor_events GROUP BY event_type, status ORDER BY count DESC;

-- Table health
SELECT pg_size_pretty(pg_total_relation_size('supervisor_events')) AS table_size,
       pg_size_pretty(pg_indexes_size('supervisor_events')) AS index_size,
       (SELECT COUNT(*) FROM supervisor_events) AS total_rows;
```

---

## 11. Startup Script

Save as `start-n8n.ps1`:

```powershell
# ═══════════════════════════════════════════════════════════
# Supervisor V1 Lean + Shiny Gmail — n8n Startup Script
# ═══════════════════════════════════════════════════════════

# n8n runtime — Supervisor V1 Lean
$env:SUPERVISOR_WORKFLOW_ID = "YOUR-SUPERVISOR-ID"
$env:HEARTBEAT_WORKFLOW_ID = "YOUR-HEARTBEAT-ID"
$env:RETENTION_WORKFLOW_ID = "YOUR-RETENTION-ID"
$env:TELEGRAM_CHAT_ID = "YOUR-CHAT-ID"
$env:CRITICAL_WORKFLOW_IDS = "ID1,ID2,ID3"
# $env:LONG_RUNNING_WORKFLOW_IDS = ""
# $env:NEVER_RETRY_WORKFLOW_IDS = ""

# Shiny Gmail (if using)
$env:GMAIL_ACCOUNT = "primary"
$env:GEMINI_API_KEY = "YOUR-GEMINI-API-KEY"
$env:GEMINI_MODEL = "gemini-3.1-flash-lite"
$env:TELEGRAM_ALLOW_GROUP_RULES = "false"
$env:WEBHOOK_URL = "https://plywood-visor-plutonium.ngrok-free.dev"

# Start ngrok (for Shiny Gmail Telegram webhook)
Start-Process -FilePath "ngrok" -ArgumentList "http", "5678", "--domain", "plywood-visor-plutonium.ngrok-free.dev" -WindowStyle Minimized
Start-Sleep -Seconds 3

# Start n8n
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
$env:N8N_CONCURRENCY_PRODUCTION_LIMIT = "3"

# Healthchecks.io
$env:HEALTHCHECKS_PING_URL = "https://hc-ping.com/YOUR-UUID"

npx n8n
```

---

## 12. Production Checklist

### Database

- [ ] Schema deployed (3 tables)
- [ ] circuit_state initialized (closed, 0)
- [ ] schema_versions shows 'v1_lean'
- [ ] Orphan dedup index uses time-bucketing

### Environment

- [ ] NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
- [ ] N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
- [ ] HEALTHCHECKS_PING_URL set
- [ ] SUPERVISOR_WORKFLOW_ID set (actual ID)
- [ ] HEARTBEAT_WORKFLOW_ID set (actual ID)
- [ ] RETENTION_WORKFLOW_ID set (actual ID)
- [ ] TELEGRAM_CHAT_ID set
- [ ] CRITICAL_WORKFLOW_IDS set

### Credentials

- [ ] Postgres credential on all Postgres nodes
- [ ] Telegram Bot credential on all Telegram nodes
- [ ] HTTP Header Auth on all HTTP Request nodes with auth

### Workflows

- [ ] All 3 workflows activated
- [ ] All monitored workflows have Error Workflow set to Supervisor Core

### Smoke Tests

- [ ] Test 1: Heartbeat received ✅
- [ ] Test 2: Healthchecks.io shows UP ✅
- [ ] Test 3: Database verified ✅
- [ ] Test 4: Error alert with probable cause ✅
- [ ] Test 5: Debounce working ✅
- [ ] Test 6: Circuit breaker opens at 5 ✅
- [ ] Test 7: Self-loop detected ✅
- [ ] Test 8: Retention completed ✅

### Security

- [ ] n8n version checked against CVE-2026-44789/44790/44791 (affects < 2.20.7)

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────┐
│         SUPERVISOR V1 LEAN — QUICK REF          │
├─────────────────────────────────────────────────┤
│                                                 │
│  Workflows:    3                                │
│  Nodes:        50 executable + 3 sticky = 53    │
│  DB Tables:    3                                │
│  AI Cost:      $0                               │
│  Audit Rounds: 10 (114 approved changes)        │
│                                                 │
│  Schedules:                                     │
│    Heartbeat:  every 5 minutes                  │
│    Retention:  every 12 hours                   │
│    Supervisor: on-demand (Error Trigger)        │
│                                                 │
│  Circuit Breaker:                               │
│    Opens at:   5 errors within 15 min           │
│    Recovery:   5 min → half_open                │
│                10 min → closed                  │
│    Safety:     1 hour → auto-reset (retention)  │
│    Decay:      count resets if last error >15m  │
│                                                 │
│  Debounce:     30 seconds                       │
│  Retention:    90 days                          │
│  DMS Grace:    30 minutes                       │
│  Orphan:       >30 min running                  │
│  Auto-Retry:   max 2/fingerprint/hour           │
│  Backoff:      15s base, 2^n, 120s cap          │
│                                                 │
│  Reset Circuit:                                 │
│    UPDATE circuit_state                         │
│    SET status='closed', error_count=0,          │
│        updated_at=NOW()                         │
│    WHERE circuit_key='supervisor';              │
│                                                 │
└─────────────────────────────────────────────────┘
```

---

## End of Deployment Guide

Last updated: 2026-05-25  
Supervisor V1 Lean — 3 workflows, 50 nodes, $0/month  
10 review cycles, 114 approved changes
