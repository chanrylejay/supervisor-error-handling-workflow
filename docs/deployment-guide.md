***

# Supervisor Error Handling Workflow — Deployment Guide

**Project:** Supervisor Error Handling Workflow (Final Build)
**Author:** Chan (Chanryle Jay Cagara)
**Last Updated:** 2026-05-26
**Audit History:** 22 review cycles, 2 independent AI agents, 136 DO NOT REPEAT items

***

## Overview

This guide covers everything needed to deploy the Supervisor Error Handling Workflow from scratch. It is a zero-AI, zero-cost, production-grade error monitoring system for self-hosted n8n.

**Estimated time:** 30–45 minutes for first deployment.

***

## 1. Prerequisites

Before starting, ensure you have:

* [ ] **n8n** self-hosted and running on `http://localhost:5678`
* [ ] **PostgreSQL** database (Neon free tier recommended: <https://neon.tech>)
  * Use the **pooled** endpoint (not direct)
* [ ] **Telegram Bot** (<https://t.me/BotFather>)
  * Bot token saved
  * Your chat ID known (use <https://t.me/userinfobot> to get it)
* [ ] **Healthchecks.io** account (<https://healthchecks.io>) with free tier
  * Create a check with **Period: 5 minutes** and **Grace: 30 minutes**
  * Copy the ping URL

***

## 2. Database Setup

Run `schema.sql` against your Postgres instance.

**Via Neon SQL Editor:**

1. Open your Neon project dashboard
2. Go to **SQL Editor**
3. Paste the contents of `schema.sql`
4. Click **Run**
5. **Important:** Index 7 (`idx_supervisor_events_fp_context`) uses `CREATE INDEX CONCURRENTLY` which cannot run inside a transaction block. If it fails, run that single statement separately.

**Via psql:**

```bash
psql "postgresql://user:pass@your-host/dbname?sslmode=require" -f schema.sql
```

### Verification

Run these queries to verify deployment:

```sql
-- Should return 1 row: status='closed', error_count=0
SELECT * FROM circuit_state;

-- Should return 1 row: version='v1_lean'
SELECT * FROM schema_versions;

-- Should return 0
SELECT COUNT(*) FROM supervisor_events;

-- Should return 7+ indexes
SELECT indexname FROM pg_indexes
WHERE tablename = 'supervisor_events'
ORDER BY indexname;
```

***

## 3. Environment Variables

### Variable Reference

| Variable                            | Required | Type                      | Purpose                                                              |
| ----------------------------------- | -------- | ------------------------- | -------------------------------------------------------------------- |
| NODE\_FUNCTION\_ALLOW\_BUILTIN      | Yes      | String: `"crypto"`        | Enables `require('crypto')` in Code nodes                            |
| N8N\_BLOCK\_ENV\_ACCESS\_IN\_NODE   | Yes      | String: `"false"`         | Enables `$env.VARIABLE` in Code nodes                                |
| N8N\_BASE\_URL                      | Yes      | String (URL)              | Base URL for execution/workflow links (e.g. `http://localhost:5678`) |
| HEALTHCHECKS\_PING\_URL             | Yes      | String (URL)              | Dead Man's Switch ping URL                                           |
| SUPERVISOR\_WORKFLOW\_ID            | Yes      | String (n8n workflow ID)  | Self-loop guard + orphan exclusion                                   |
| HEARTBEAT\_WORKFLOW\_ID             | Yes      | String (n8n workflow ID)  | Self-loop guard + orphan exclusion                                   |
| RETENTION\_WORKFLOW\_ID             | Yes      | String (n8n workflow ID)  | Self-loop guard + orphan exclusion                                   |
| TELEGRAM\_CHAT\_ID                  | Yes      | String (numeric)          | All Telegram alerts                                                  |
| CRITICAL\_WORKFLOW\_IDS             | Yes      | String (comma-separated)  | Activation monitoring (comma-separated)                              |
| LONG\_RUNNING\_WORKFLOW\_IDS        | Optional | String (comma-separated)  | Orphan detection exclusion (comma-separated)                         |
| NEVER\_RETRY\_WORKFLOW\_IDS         | Optional | String (comma-separated)  | Auto-retry safety denylist (comma-separated)                         |
| N8N\_CONCURRENCY\_PRODUCTION\_LIMIT | Optional | Integer: default `3`      | Limits concurrent executions (default: 3)                            |

### Setting Variables

Set these before starting n8n. Example for PowerShell:

```powershell
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
$env:N8N_BASE_URL = "http://localhost:5678"
$env:HEALTHCHECKS_PING_URL = "https://hc-ping.com/your-uuid-here"
$env:TELEGRAM_CHAT_ID = "your-chat-id"
$env:CRITICAL_WORKFLOW_IDS = "id1,id2,id3"
$env:SUPERVISOR_WORKFLOW_ID = "FILL_AFTER_IMPORT"
$env:HEARTBEAT_WORKFLOW_ID = "FILL_AFTER_IMPORT"
$env:RETENTION_WORKFLOW_ID = "FILL_AFTER_IMPORT"

npx n8n
```

Example for Bash/Linux:

```bash
export NODE_FUNCTION_ALLOW_BUILTIN="crypto"
export N8N_BLOCK_ENV_ACCESS_IN_NODE="false"
export N8N_BASE_URL="http://localhost:5678"
# ... set remaining variables
npx n8n
```

> **NOTE:** Workflow IDs are only known after importing. See Section 5.

***

## 4. n8n Credential Setup

### Postgres Credential

Create a new credential in n8n: **Credentials** → **New** → **Postgres**

| Setting | Value | Notes |
| ------- | ----- | ----- |
| Host | Your Postgres/Neon pooled endpoint | Do NOT use direct endpoint |
| Port | 5432 | Standard Postgres port |
| Database | Your database name | Must match schema.sql target |
| User | Your username | Verify permissions (create tables/indexes) |
| Password | Your password | Use strong password |
| SSL | Allow | Required for Neon; optional for local |
| **Connection Options** | `{"connectionTimeout": 10}` | Neon cold-start tolerance |

**Test connection** before saving.

### Telegram Bot Credential

Create a new credential in n8n: **Credentials** → **New** → **Telegram Bot API**

| Setting | Value | Notes |
| ------- | ----- | ----- |
| Access Token | Your bot token from BotFather | Format: `123456789:ABCdef...` |

**Test:** Send a message via the credential to verify token works.

### HTTP Header Auth Credential

Create a new credential in n8n: **Credentials** → **New** → **HTTP Header Auth**

Used by Heartbeat's orphan detection and activation monitoring to query the n8n API.

| Setting | Value | Notes |
| ------- | ----- | ----- |
| Name | `X-N8N-API-KEY` | Exact case required |
| Value | Your n8n API key | Create at `http://localhost:5678/settings/api` |

**To get n8n API key:**
1. Open `http://localhost:5678/settings/api`
2. Click **Generate API Key**
3. Copy the full token
4. Paste into credential value

***

## 5. Workflow Import

### Import Order

1. `workflow_1_supervisor_core.json`
2. `workflow_2_heartbeat_monitor.json`
3. `workflow_3_data_retention.json`

### After Import: Note Workflow IDs

```
http://localhost:5678/workflow/AbCdE123  ← "AbCdE123" is the ID
```

Record all three IDs and update your environment variables:

```
SUPERVISOR_WORKFLOW_ID = "AbCdE123"
HEARTBEAT_WORKFLOW_ID = "FgHiJ456"
RETENTION_WORKFLOW_ID = "KlMnO789"
```

Restart n8n after updating env vars.

### Assign Credentials

Open each workflow and assign:

* All Postgres nodes → your Postgres credential
* All Telegram nodes → your Telegram Bot credential
* All HTTP Request nodes with auth → your HTTP Header Auth credential

### ⚠️ CRITICAL: Import Corruption Warning

n8n can corrupt IF node output mappings during JSON import. Wires may look correct but route wrong.

**Symptoms:** IF node always takes the wrong branch.

**Fix:** Delete the corrupted IF node, add a new one, recreate conditions and connections.

**Watch these nodes:**

* Is Self Loop? (WF1)
* Should Alert Self-Loop? (WF1)
* Is Debounced? (WF1)
* Should Alert Orphans? (WF2)
* Has Activation Issue? (WF2)
* Should Send? (WF2)
* Should Notify? (WF3)

***

## 6. Workflow Activation

### Activation Order

1. **Data Retention** (background cleanup)
2. **Heartbeat Monitor** (health monitoring)
3. **Supervisor Core** (error catching)

Within 5 minutes, you should receive your first heartbeat:

```
💓 SUPERVISOR — 🟢 HEALTHY

🟢 Circuit: closed (0/5)
🧭 Control Plane: full
🟢 DMS: ok (last cycle)
🟢 Retention: ok (no record)
...
```

***

## 7. Setting Error Workflows

For every workflow you want monitored: **Settings → Error Workflow → Supervisor Core**

> **Note:** Error Trigger only fires on PRODUCTION runs, NOT manual test executions. The monitored workflow must be activated.

***

## 8. Smoke Tests

> **IMPORTANT:** Run tests in sequence. Each test validates a critical subsystem. Allow 5+ minutes between tests for Telegram/database latency.

### Test 1: Heartbeat ✅

**Expected outcome:** Receive Telegram message with `💓 SUPERVISOR — 🟢 HEALTHY` and 5-minute timestamp.

1. Activate Heartbeat Monitor
2. Wait 5 minutes exactly
3. Check Telegram for heartbeat message
4. **Verify:** Message includes current circuit state, DMS status, and all health indicators

**Troubleshoot:** If no message, check [Heartbeat not sending](#heartbeat-not-sending) section.

### Test 2: Dead Man's Switch ✅

**Expected outcome:** Healthchecks.io dashboard shows green UP status with recent ping timestamp.

1. Open [Healthchecks.io](https://healthchecks.io)
2. Locate your "Supervisor" check
3. Verify last ping occurred in last 5 minutes
4. **Verify:** Status is "UP", not "Down" or "Paused"

**Note:** If DMS shows "Down", Heartbeat cannot reach the ping URL. Verify `HEALTHCHECKS_PING_URL` is correct and the n8n instance has internet access.

### Test 3: Database ✅

**Expected outcome:** All three queries return expected initialization data.

```sql
SELECT * FROM circuit_state;
SELECT * FROM schema_versions;
SELECT COUNT(*) FROM supervisor_events;
```

| Query | Expected Result |
|-------|-----------------|
| `circuit_state` | 1 row: `status='closed'`, `error_count=0` |
| `schema_versions` | 1 row: `version='v1_lean'` |
| `supervisor_events` | `count=0` (no events yet) |

### Test 4: Error Alert ✅

**Expected outcome:** Single Telegram alert with error details, probable cause, and supervisor action.

1. Create a new test workflow with node: `Code` → `throw new Error('Supervisor smoke test')`
2. Open workflow settings → Error Workflow → select **Supervisor Core**
3. **Activate** the test workflow
4. **Trigger** the workflow manually or via schedule (must be production execution)
5. Check Telegram for error alert within 30 seconds
6. **Verify:** Alert includes workflow name, error message, and recommended action

**Troubleshoot:** If no alert after 60 seconds, see [No Telegram alert received](#no-telegram-alert-received).

### Test 5: Debounce ✅

**Expected outcome:** Duplicate errors within 30 seconds are combined into one alert.

1. Trigger the test workflow **twice** within 30 seconds (can be back-to-back)
2. Check Telegram — should receive **only one alert**
3. Run verification query:

```sql
SELECT event_type, COUNT(*) FROM supervisor_events
WHERE created_at > NOW() - INTERVAL '5 minutes'
GROUP BY event_type
ORDER BY event_type;
```

**Expected output:**
```
event_type       | count
─────────────────┼───────
error_alert      | 1
error_debounced  | 1 (or more)
```

### Test 6: Circuit Breaker ✅

**Expected outcome:** After 5 errors (spaced >30s apart), circuit opens and Telegram alerts escalate.

1. Trigger test workflow **5 times** (with 35+ second delays between each)
2. Watch Telegram for escalating alerts: "Error 1 of 5", "Error 2 of 5", ... "🔴 CIRCUIT OPEN"
3. After 5th error, verify circuit-open banner shows recovery timeline
4. Run verification query:

```sql
SELECT status, error_count FROM circuit_state WHERE circuit_key = 'supervisor';
```

**Expected output:** `status='open'`, `error_count=5`

**Recovery timeline:**
- **5 min:** Circuit transitions to `half_open` (probe attempt)
- **10 min:** Circuit auto-closes (if probe successful)
- **60 min:** Retention auto-resets if manually stuck

**After test — RESET CIRCUIT:**

```sql
UPDATE circuit_state SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';
```

Verify with Telegram heartbeat (should show circuit closed within 5 min).

### Test 7: Self-Loop Detection ✅

**Expected outcome:** If Supervisor Core's own Error Workflow is set to itself, a special self-loop alert fires.

1. Open **Supervisor Core** workflow
2. Open **Workflow Settings** → **Error Workflow** → select **Supervisor Core** (itself)
3. **Save** and **Activate**
4. Trigger an error in any monitored workflow
5. Check Telegram for **self-loop detection alert** with execution URL
6. **Important:** Immediately fix by setting Error Workflow back to blank or correct target

**Verify:**
```sql
SELECT * FROM supervisor_events WHERE event_type = 'self_loop_detected'
ORDER BY created_at DESC LIMIT 1;
```

### Test 8: Data Retention ✅

**Expected outcome:** Retention cleans old records and logs completion to database and/or Telegram.

1. Manually execute **Data Retention** workflow (run now button)
2. Check Telegram for retention report (includes data span and humanized summary)
   - *Or* if routine (no records deleted), report is suppressed to reduce noise
3. Verify `retention_completed` event in database:

```sql
SELECT * FROM supervisor_events WHERE event_type = 'retention_completed'
ORDER BY created_at DESC LIMIT 1;
```

**Expected output:** One row with `severity='info'` and recent `created_at` timestamp.

### Post-Test Cleanup

**REQUIRED:** Reset circuit and clean up test workflow.

```sql
UPDATE circuit_state SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';
```

1. Delete or deactivate the test workflow
2. Verify no stray events in database:

```sql
SELECT COUNT(*) FROM supervisor_events WHERE event_type LIKE '%test%' OR workflow_name LIKE '%test%';
```

Should return `0` after cleanup.

***

## 9. Troubleshooting

### "No Telegram alert received"

| Check                 | How                                            | Why It Matters |
| --------------------- | ---------------------------------------------- | -------------- |
| Bot token correct?    | Send a test message via BotFather              | Invalid token silently fails |
| Chat ID correct?      | Use <https://t.me/userinfobot>                 | Wrong ID sends to wrong chat |
| Workflow active?      | Green toggle must be ON                        | Inactive workflows ignore triggers |
| Error Workflow set?   | Monitored workflow → Settings → Error Workflow | Supervisor Core must be explicitly set |
| Production run?       | Manual executions don't trigger Error Trigger  | Only production/scheduled runs fire errors |
| Credentials assigned? | Check each Telegram node has a credential      | Missing credential = node silently fails |
| Network access?       | Verify n8n instance can reach Telegram API     | Firewall/proxy blocks outbound HTTPS |

**Quick fix:** Manually execute Telegram node with test message in a debug workflow.

### "Heartbeat not sending"

Heartbeat uses MD5 dedup. Identical state = suppressed. A heartbeat sends when:

* State changes (circuit, errors, orphans, DMS, activation, storm, control plane)
* Database is unreachable
* Recovery from DEGRADED/CRITICAL to HEALTHY
* Storm starts or resolves
* First message of the hour (healthy pulse)

**Diagnostic:** Check `circuit_state` to see when last update occurred:

```sql
SELECT * FROM circuit_state WHERE circuit_key = 'supervisor';
```

**Force a heartbeat:**

```sql
UPDATE circuit_state SET error_count = 1 WHERE circuit_key = 'supervisor';
-- Wait up to 5 min for heartbeat, then reset:
UPDATE circuit_state SET error_count = 0 WHERE circuit_key = 'supervisor';
```

**If still silent:** Verify Telegram credential is assigned to Telegram nodes. Check n8n logs for errors.

### "Circuit stuck open"

```sql
UPDATE circuit_state SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';
```

**Auto-recovery timeline:**
- Heartbeat auto-recovers after 5 minutes
- Retention resets after 1 hour
- If stuck beyond 1 hour, verify both workflows are active and database is reachable

**Verify workflows are active:**
```
Heartbeat Monitor → green toggle ON
Data Retention → green toggle ON
Supervisor Core → green toggle ON
```

### "Events not being logged"

If `supervisor_events` is empty despite Telegram alerts arriving, Postgres nodes cannot reach the database.

**Verify Postgres credentials:**

1. Go to **Credentials** in n8n
2. Find your Postgres credential
3. Test the connection (if available)
4. Assign it to ALL Postgres nodes across all workflows

**Verify data exists:**

```sql
SELECT event_type, COUNT(*) FROM supervisor_events 
GROUP BY event_type 
ORDER BY count DESC;
```

**Common causes:**
- Credential not assigned to Postgres node
- Connection pooling endpoint not used (Neon: use `pooled`, not `direct`)
- Connection timeout too short (Neon: add `connectionTimeout: 10` in Connection Options)
- Network firewall blocking n8n → Postgres

### "$env not accessible" or "crypto is not defined"

These errors indicate missing environment variables at n8n startup.

```
Error: crypto is not defined
```

**Fix:**
```
NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
```

**Steps:**
1. Stop n8n (Ctrl+C)
2. Set both variables in your shell/environment
3. Restart n8n with `npx n8n`
4. Verify variables with:

```powershell
$env:NODE_FUNCTION_ALLOW_BUILTIN
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE
```

### "IF node routes everything to wrong branch"

n8n import corruption. IF node conditions are reversed or output mappings are crossed.

**Symptoms:**
- All errors route to same branch regardless of condition
- Workflow logic seems backwards

**Fix:**
1. Open affected workflow
2. Delete the corrupted IF node
3. Add a new IF node
4. Recreate all conditions and connections manually
5. Save and retest

**Watch for corruption on these IF nodes:**
- Is Self Loop? (WF1)
- Should Alert Self-Loop? (WF1)
- Is Debounced? (WF1)
- Should Alert Orphans? (WF2)
- Has Activation Issue? (WF2)
- Should Send? (WF2)
- Should Notify? (WF3)

***

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
SELECT status, COUNT(*) FROM supervisor_events
WHERE event_type = 'error_alert' AND status IN ('retry_submitted', 'retry_submit_failed')
AND created_at > NOW() - INTERVAL '24 hours'
GROUP BY status;

-- Event distribution
SELECT event_type, status, COUNT(*), MAX(created_at) AS last_seen
FROM supervisor_events GROUP BY event_type, status ORDER BY count DESC;

-- Table health
SELECT pg_size_pretty(pg_total_relation_size('supervisor_events')) AS table_size,
       pg_size_pretty(pg_indexes_size('supervisor_events')) AS index_size,
       (SELECT COUNT(*) FROM supervisor_events) AS total_rows;

-- Data span
SELECT MIN(created_at) AS oldest, MAX(created_at) AS newest,
       ROUND(EXTRACT(EPOCH FROM MAX(created_at) - MIN(created_at)) / 86400) AS span_days
FROM supervisor_events;
```

***

## 11. Startup Script Template

Save as `start-n8n.ps1` (PowerShell) or adapt to your shell:

```powershell
# ═══════════════════════════════════════════════════════════
# Supervisor Error Handling Workflow — n8n Startup Script
# ═══════════════════════════════════════════════════════════

# n8n platform settings
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
$env:N8N_CONCURRENCY_PRODUCTION_LIMIT = "3"
$env:N8N_BASE_URL = "http://localhost:5678"

# Supervisor workflow IDs (fill after import)
$env:SUPERVISOR_WORKFLOW_ID = "YOUR-SUPERVISOR-ID"
$env:HEARTBEAT_WORKFLOW_ID = "YOUR-HEARTBEAT-ID"
$env:RETENTION_WORKFLOW_ID = "YOUR-RETENTION-ID"

# Telegram
$env:TELEGRAM_CHAT_ID = "YOUR-CHAT-ID"

# Healthchecks.io Dead Man's Switch
$env:HEALTHCHECKS_PING_URL = "https://hc-ping.com/YOUR-UUID"

# Activation monitoring (comma-separated workflow IDs to watch)
$env:CRITICAL_WORKFLOW_IDS = "ID1,ID2,ID3"

# Optional: exclude from orphan detection
# $env:LONG_RUNNING_WORKFLOW_IDS = ""

# Optional: never auto-retry these workflows
# $env:NEVER_RETRY_WORKFLOW_IDS = ""

# Start n8n
npx n8n
```

***

## 12. Production Checklist

### Database

* [ ] Schema deployed (3 tables, 7 indexes)
* [ ] `circuit_state` initialized (closed, 0)
* [ ] `schema_versions` shows `v1_lean`
* [ ] fp\_context index created (run separately if needed)

### Environment

* [ ] NODE\_FUNCTION\_ALLOW\_BUILTIN = "crypto"
* [ ] N8N\_BLOCK\_ENV\_ACCESS\_IN\_NODE = "false"
* [ ] N8N\_BASE\_URL set
* [ ] HEALTHCHECKS\_PING\_URL set
* [ ] SUPERVISOR\_WORKFLOW\_ID set (actual ID)
* [ ] HEARTBEAT\_WORKFLOW\_ID set (actual ID)
* [ ] RETENTION\_WORKFLOW\_ID set (actual ID)
* [ ] TELEGRAM\_CHAT\_ID set
* [ ] CRITICAL\_WORKFLOW\_IDS set

### Credentials

* [ ] Postgres credential on all Postgres nodes
* [ ] Telegram Bot credential on all Telegram nodes
* [ ] HTTP Header Auth on all HTTP Request nodes with auth

### Workflows

* [ ] All 3 workflows activated (in order: Retention → Heartbeat → Core)
* [ ] All monitored workflows have Error Workflow set to Supervisor Core

### Smoke Tests

* [ ] Test 1: Heartbeat received ✅
* [ ] Test 2: Healthchecks.io shows UP ✅
* [ ] Test 3: Database verified ✅
* [ ] Test 4: Error alert with probable cause ✅
* [ ] Test 5: Debounce working ✅
* [ ] Test 6: Circuit breaker opens at 5 ✅
* [ ] Test 7: Self-loop detected ✅
* [ ] Test 8: Retention completed ✅

***

## Quick Reference Card

```
┌─────────────────────────────────────────────────┐
│   SUPERVISOR ERROR HANDLING — QUICK REF         │
├─────────────────────────────────────────────────┤
│                                                 │
│  Workflows:    3                                │
│  Nodes:        48 executable + 3 sticky = 51    │
│  DB Tables:    3                                │
│  DB Indexes:   7                                │
│  AI Cost:      $0/month                         │
│  Audit Rounds: 22 (136 DO NOT REPEAT items)     │
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
│  Storm:        >=3 distinct fps in 5 min        │
│                                                 │
│  Reset Circuit:                                 │
│    UPDATE circuit_state                         │
│    SET status='closed', error_count=0,          │
│        updated_at=NOW()                         │
│    WHERE circuit_key='supervisor';              │
│                                                 │
└─────────────────────────────────────────────────┘
```

***

## End of Deployment Guide

Last updated: 2026-05-26
Supervisor Error Handling Workflow — 3 workflows, 48 nodes, $0/month
22 review cycles, 136 DO NOT REPEAT items, 2 independent AI auditors
