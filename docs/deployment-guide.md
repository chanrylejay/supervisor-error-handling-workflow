# Supervisor V1 Lean — Deployment Guide

**Project:** Supervisor V1 Lean
**Author:** Chan (Chanryle Jay Cagara)
**Last Updated:** 2026-05-24
**n8n Version:** 2.12.3 (self-hosted, Windows/PowerShell)

---

## Overview

This guide covers everything needed to deploy Supervisor V1 Lean from scratch. It incorporates all 10 deployment lessons learned from the V23 deployment so you don't repeat them.

**Estimated time:** 30–45 minutes for first deployment.

---

## 1. Prerequisites

Before starting, ensure you have:

- [ ] **n8n** self-hosted and running on `http://localhost:5678`
- [ ] **Neon PostgreSQL** account — [neon.tech](https://neon.tech) (free tier)
  - Region: Singapore (aws-ap-southeast-1) recommended for Philippines
  - Use the **pooled** endpoint (not direct)
- [ ] **Telegram Bot** — created via [@BotFather](https://t.me/BotFather)
  - Bot token saved
  - Your chat ID known (use [@userinfobot](https://t.me/userinfobot) to get it)
- [ ] **Healthchecks.io** account — [healthchecks.io](https://healthchecks.io) (free tier)
  - Create a check with **Period: 5 minutes** and **Grace: 30 minutes**
  - Copy the ping URL

---

## 2. Database Setup

### Option A: Fresh Install

If this is a new database (no V23 tables), simply run the schema file:

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

If you're deploying on the same Neon database that has V23 tables, **just run the schema.sql as-is**. All `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS` statements are idempotent.

The V23 tables (`error_logs`, `alert_log`, `pending_approvals`, `dead_letter_queue`) will remain but are never touched by V1 Lean. They're harmless.

**Optional cleanup** (only after V1 Lean is confirmed stable):
```sql
-- Remove V23-only tables
DROP TABLE IF EXISTS error_logs CASCADE;
DROP TABLE IF EXISTS alert_log CASCADE;
DROP TABLE IF EXISTS pending_approvals CASCADE;
DROP TABLE IF EXISTS dead_letter_queue CASCADE;
```

### Verification

After running the schema, verify:

```sql
-- Should return 1 row: status='closed', error_count=0
SELECT * FROM circuit_state;

-- Should return 1 row: version='v1_lean'
SELECT * FROM schema_versions;

-- Should return 0
SELECT COUNT(*) FROM supervisor_events;

-- Should return 6 indexes
SELECT indexname FROM pg_indexes
WHERE tablename = 'supervisor_events'
ORDER BY indexname;
```

---

## 3. Environment Variables

### Why These Matter

n8n 2.12.3 blocks `crypto` module and `$env` access by default. Without these variables, the Heartbeat's MD5 hash and the Self-Loop Check's `$env` lookups will fail silently.

### Variable Reference

| Variable | Required | Purpose |
|---|---|---|
| `NODE_FUNCTION_ALLOW_BUILTIN` | Yes | Enables `require('crypto')` in Code nodes |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | Yes | Enables `$env.VARIABLE` in Code nodes |
| `HEALTHCHECKS_PING_URL` | Yes | Dead Man's Switch ping URL |
| `SUPERVISOR_WORKFLOW_ID` | Yes | Self-loop guard + orphan exclusion |
| `HEARTBEAT_WORKFLOW_ID` | Yes | Self-loop guard + orphan exclusion |
| `RETENTION_WORKFLOW_ID` | Yes | Self-loop guard + orphan exclusion |
| `N8N_CONCURRENCY_PRODUCTION_LIMIT` | Optional | Limits concurrent workflow executions (default: 3) |

### Setting Variables (Interactive Session)

```powershell
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
$env:HEALTHCHECKS_PING_URL = "https://hc-ping.com/your-uuid-here"
$env:SUPERVISOR_WORKFLOW_ID = "FILL_AFTER_IMPORT"
$env:HEARTBEAT_WORKFLOW_ID = "FILL_AFTER_IMPORT"
$env:RETENTION_WORKFLOW_ID = "FILL_AFTER_IMPORT"
$env:N8N_CONCURRENCY_PRODUCTION_LIMIT = "3"
npx n8n
```

> **IMPORTANT:** Use PowerShell `$env:VAR = "value"` syntax. NOT Bash `export VAR=value`. This project runs on Windows.

> **NOTE:** Workflow IDs are only known after importing. See Section 5 for when to fill them in.

### PowerShell Execution Policy

If your startup script won't run, set the execution policy:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass
```

---

## 4. n8n Credential Setup

Set up these credentials in n8n before importing workflows.

### Postgres Credential

| Setting | Value |
|---|---|
| Host | Your Neon pooled endpoint (e.g. `ep-xxx.ap-southeast-1.aws.neon.tech`) |
| Port | `5432` |
| Database | Your database name |
| User | Your Neon username |
| Password | Your Neon password |
| SSL | `Allow` |
| Max Connections | `5` |

> **Neon gotcha:** Neon serverless Postgres can take 1–3 seconds to wake from idle. If you see connection timeouts on the first query after idle, add `connectionTimeout: 10` to the Postgres credential's "Connection Options" field.

### Telegram Bot Credential

| Setting | Value |
|---|---|
| Access Token | Your bot token from BotFather |

> **Tip:** Use the same Telegram bot you use for Shiny Gmail. One bot can serve multiple workflows.

### HTTP Header Auth Credential

This is used by the Heartbeat Monitor's orphan detection to query the n8n REST API.

| Setting | Value |
|---|---|
| Name | `X-N8N-API-KEY` |
| Value | Your n8n API key |

To create an n8n API key:
1. Go to `http://localhost:5678/settings/api`
2. Click **Create API Key**
3. Copy the key

---

## 5. Workflow Import

### Import Order

Import in this exact order:

```
1. workflows/workflow_1_supervisor_core.json
2. workflows/workflow_2_heartbeat_monitor.json
3. workflows/workflow_3_data_retention.json
```

### After Import: Note Workflow IDs

After importing each workflow, note its ID from the URL bar:

```
http://localhost:5678/workflow/AbCdE123  ← "AbCdE123" is the workflow ID
```

Record all three:

```
Supervisor Core:    _______________
Heartbeat Monitor:  _______________
Data Retention:     _______________
```

### Update Startup Script

Go back and fill in the workflow IDs in your startup script or environment variables:

```powershell
$env:SUPERVISOR_WORKFLOW_ID = "AbCdE123"   # ← your actual ID
$env:HEARTBEAT_WORKFLOW_ID = "FgHiJ456"    # ← your actual ID
$env:RETENTION_WORKFLOW_ID = "KlMnO789"    # ← your actual ID
```

> **IMPORTANT:** If n8n is already running, you must restart it for new `$env` values to take effect.

### Replace Telegram Chat IDs

Search for `REPLACE_WITH_TELEGRAM_CHAT_ID` in all workflows and replace with your actual Telegram chat ID.

| Workflow | Telegram Nodes to Update | Count |
|---|---|---|
| Supervisor Core | Telegram (Circuit Breaker), Telegram (Self-Loop Alert), Telegram (Send Alert) | 3 |
| Heartbeat Monitor | Telegram (DMS Failure), Telegram (Heartbeat), Telegram (API Error), Telegram (Orphan Alert) | 4 |
| Data Retention | Telegram (Retention Report) | 1 |
| **Total** | | **8 nodes** |

### Assign Credentials

After import, open each workflow and assign the correct credentials to:
- All **Postgres** nodes → your Neon credential
- All **Telegram** nodes → your Telegram Bot credential
- **HTTP (Running Executions)** in Heartbeat → your HTTP Header Auth credential

### ⚠️ CRITICAL: Import Corruption Warning

n8n can corrupt IF and Switch node output mappings during JSON import. Wires may look correct visually but route data to wrong outputs during execution.

**Symptoms:**
- IF node always takes the wrong branch
- Errors don't reach the Telegram alert despite wiring looking correct
- "All paths working except one specific branch"

**Fix:** Delete the corrupted node entirely, add a new one, and recreate the conditions and connections from scratch.

**Which nodes to watch:**
- `Is Debounced?` (Workflow 1)
- `Is Circuit Open?` (Workflow 1)
- `Is Self Loop?` (Workflow 1)
- `Has DMS Failed?` (Workflow 2)
- `Should Send?` (Workflow 2)
- `Has API Error?` (Workflow 2)
- `Has Orphans?` (Workflow 2)

> **Tip from V23 deployment:** 6 out of 8 branching nodes were corrupted during V23's import. Test each branch explicitly during smoke testing.

---

## 6. Workflow Activation

### Activation Order

Activate in this order:

```
1. Data Retention V1 Lean        (background cleanup - safe to start first)
2. Heartbeat Monitor V1 Lean     (start health monitoring)
3. Supervisor Core V1 Lean       (start catching errors)
```

**Why this order:** Retention and Heartbeat should be running before Supervisor starts catching errors. This ensures the circuit reset probe and health monitoring are active from the moment the first error is caught.

### After Activating Heartbeat

Within 5 minutes of activating the Heartbeat Monitor, you should receive your first Telegram heartbeat message:

```
💓 HEARTBEAT — Supervisor V1 Lean

Circuit: 🟢 closed (0 errors)
Errors (1h): 0
Errors (24h): 0
Trend: 🟢 stable

Timestamp: 2026-05-24T06:00:00Z
```

If you don't receive it within 5 minutes, check:
1. Telegram bot token and chat ID are correct
2. The workflow is activated (green toggle ON)
3. Postgres credential is connected

---

## 7. Setting Error Workflows

For every workflow you want Supervisor to monitor, configure it as the error handler:

1. Open the monitored workflow
2. Go to **Settings** (gear icon, top right)
3. Set **Error Workflow** → **Supervisor Core V1 Lean**
4. Save

### Shiny Gmail Workflows

If you're running Shiny Gmail Automation, set Supervisor as the error workflow for:

- [ ] Shiny Gmail Daily Orchestrator V2.7 Lean
- [ ] Shiny Gmail Single Email Processor Child V2.7 Lean
- [ ] Shiny Gmail Lightweight Telegram Rules Manager V2.7 Lean

### Important: Production Runs Only

> **Error Trigger only fires on PRODUCTION (published/active) runs, NOT manual test executions.**
>
> If you click "Execute Workflow" to test, errors will NOT reach Supervisor. The monitored workflow must be **activated** and triggered by its schedule/trigger to generate real Error Trigger events.

---

## 8. Smoke Tests

Run these tests in order. Each builds on the previous.

### Test 1: Heartbeat ✅

**What:** Verify Heartbeat Monitor is running and sending status.

**Steps:**
1. Activate Heartbeat Monitor
2. Wait up to 5 minutes
3. Check Telegram for heartbeat message

**Expected:** Heartbeat message with circuit status, error counts, and trend.

### Test 2: Dead Man's Switch ✅

**What:** Verify Healthchecks.io is receiving pings.

**Steps:**
1. Go to your Healthchecks.io dashboard
2. Check that the Supervisor check shows **UP**
3. Last ping should be within the last 5 minutes

**Expected:** Green status, recent ping timestamp.

### Test 3: Database Verification ✅

**What:** Confirm schema deployed correctly.

**Steps:**
```sql
SELECT * FROM circuit_state;
-- Expected: 1 row, status='closed', error_count=0

SELECT * FROM schema_versions;
-- Expected: version='v1_lean'

SELECT COUNT(*) FROM supervisor_events;
-- Expected: 0 or small number (heartbeat events may have started)
```

### Test 4: Error Alert ✅

**What:** Trigger a real error and verify Supervisor sends an alert.

**Steps:**
1. Create a new workflow called "Test Error Generator"
2. Add a **Schedule Trigger** (set to every 1 minute for testing)
3. Add a **Code** node with:
   ```javascript
   throw new Error('Supervisor V1 Lean smoke test — this is a test error');
   ```
4. Go to **Settings → Error Workflow → Supervisor Core V1 Lean**
5. **Activate** the Test Error Generator workflow
6. Wait for the schedule to fire (up to 1 minute)
7. Check Telegram for the alert

**Expected:**
```
🟠 ERROR — WORKFLOW ERROR

Workflow: Test Error Generator
Failed Node: Code
Error: Supervisor V1 Lean smoke test — this is a test error
Execution: http://localhost:5678/executions/xxxxx
Retryable: yes
Circuit: Error 1 of 5

Trace: err-xxxxx-xxxxxxxxx
Timestamp: 2026-05-24Txx:xx:xxZ
```

**After test:** Deactivate the Test Error Generator workflow.

### Test 5: Debounce ✅

**What:** Verify duplicate errors within 30 seconds are suppressed.

**Steps:**
1. Reactivate Test Error Generator
2. Set schedule to every 5 seconds (or trigger manually twice rapidly)
3. Wait for 2 triggers within 30 seconds
4. Check Telegram

**Expected:** Only ONE alert received, not two. Second error is debounced.

**Verify in database:**
```sql
SELECT event_type, COUNT(*)
FROM supervisor_events
WHERE created_at > NOW() - INTERVAL '5 minutes'
GROUP BY event_type;
-- Should show: error_alert (1), error_debounced (1+)
```

**After test:** Deactivate the Test Error Generator.

### Test 6: Circuit Breaker ✅

**What:** Verify circuit opens after 5 errors.

**Steps:**
1. Set Test Error Generator schedule to every 1 minute
2. Activate and let it fire 5+ times (spaced >30s apart to avoid debounce)
3. Watch Telegram

**Expected:**
- Alerts for errors 1–4 with escalating "Error X of 5"
- At error 5: Circuit Breaker Open alert
- Error 6+: No alerts (circuit is open, errors suppressed)

**After test:**
1. Deactivate Test Error Generator
2. Reset the circuit:
```sql
UPDATE circuit_state
SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';
```

### Test 7: Self-Loop Detection ✅

**What:** Verify Supervisor detects errors from its own workflows.

**Steps:**
1. Temporarily set Supervisor Core's own Error Workflow to itself
2. Add a Code node to Supervisor Core that throws an error (or wait for a natural error)
3. Check Telegram

**Expected:** Self-loop detection alert instead of a normal error alert.

**After test:** Remove the self-referencing Error Workflow setting. Supervisor should NOT monitor itself in production (the self-loop guard is a safety net, not the primary design).

### Test 8: Data Retention ✅

**What:** Verify retention runs and reports.

**Steps:**
- Either wait 12 hours for the scheduled run, OR
- Manually execute the Data Retention workflow (click "Execute Workflow")

**Expected:**
```
🧹 DATA RETENTION REPORT — V1 Lean

Deleted Events (90d): 0

✅ ANALYZE completed successfully.

Timestamp: 2026-05-24Txx:xx:xxZ
```

### Post-Testing Cleanup

After all tests pass:

```sql
-- Reset circuit breaker if needed
UPDATE circuit_state
SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';

-- Optional: clear test events
DELETE FROM supervisor_events
WHERE workflow_name = 'Test Error Generator';
```

Deactivate or delete the Test Error Generator workflow.

---

## 9. Troubleshooting

### "No Telegram alert received"

| Check | How |
|---|---|
| Bot token correct? | Send a test message via BotFather |
| Chat ID correct? | Use [@userinfobot](https://t.me/userinfobot) to verify |
| Workflow active? | Green toggle must be ON |
| Error Workflow set? | Monitored workflow → Settings → Error Workflow |
| Production run? | Error Trigger only fires on active/published runs, NOT manual executions |
| Credentials assigned? | Open workflow, check each Telegram node has a credential |

### "Heartbeat not sending"

The heartbeat uses MD5 dedup — **identical state = message suppressed**. This is by design ("no news = good news").

A heartbeat will send when:
- System state **changes** (circuit status, error counts, cache contents)
- Database is **unreachable** (always sends on DB error)
- First message of the **hour** (healthy heartbeat sent when minutes < 5)

If you need to force a heartbeat, change the circuit state temporarily:
```sql
UPDATE circuit_state SET error_count = 1 WHERE circuit_key = 'supervisor';
-- Wait for next heartbeat cycle (up to 5 min)
-- Then reset:
UPDATE circuit_state SET error_count = 0 WHERE circuit_key = 'supervisor';
```

### "Circuit stuck open"

Manual reset:
```sql
UPDATE circuit_state
SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';
```

Note: The Heartbeat Monitor automatically recovers open circuits after 5 minutes, and Data Retention resets stale circuits after 1 hour. If the circuit stays open, check that both workflows are active.

### "Orphan detection not working"

- Check the **HTTP Header Auth** credential is assigned to the `HTTP (Running Executions)` node
- Verify your n8n API key works: open `http://localhost:5678/api/v1/workflows` in your browser with the API key header
- The API must be accessible from localhost

### "$env not accessible" or "crypto is not defined"

These mean the environment variables are not set:

```powershell
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
```

You must restart n8n after setting these. They cannot be added while n8n is running.

### "Postgres connection timeout"

Neon serverless Postgres can take 1–3 seconds to wake from idle. Solutions:
1. Add `connectionTimeout: 10` in the Postgres credential's Connection Options
2. The `alwaysOutputData: true` setting on critical Postgres nodes prevents execution chain breaks on empty/error results

### "IF node routes everything to wrong branch"

This is a confirmed n8n import corruption bug. The fix:
1. Delete the corrupted IF node
2. Add a new IF node
3. Recreate the condition and rewire both outputs

Do NOT try to fix the existing node — the internal output mapping is corrupted and can only be fixed by recreation.

---

## 10. Useful SQL Commands

### View Circuit State
```sql
SELECT * FROM circuit_state WHERE circuit_key = 'supervisor';
```

### Reset Circuit Breaker
```sql
UPDATE circuit_state
SET status = 'closed', error_count = 0, updated_at = NOW()
WHERE circuit_key = 'supervisor';
```

### Recent Events (Last 1 Hour)
```sql
SELECT event_type, workflow_name, execution_id, severity, created_at
FROM supervisor_events
WHERE created_at > NOW() - INTERVAL '1 hour'
ORDER BY created_at DESC;
```

### Error Trends
```sql
SELECT
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 hour') AS errors_last_hour,
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '24 hours') AS errors_last_24h,
  COUNT(*) AS errors_total
FROM supervisor_events
WHERE event_type = 'error_alert';
```

### Event Type Distribution
```sql
SELECT event_type, COUNT(*), MAX(created_at) AS last_seen
FROM supervisor_events
GROUP BY event_type
ORDER BY COUNT(*) DESC;
```

### Clear All Events (Testing Only)
```sql
-- ⚠️ Only use during testing — this deletes all audit history
DELETE FROM supervisor_events;
```

### Remove V23 Tables (Optional)
```sql
-- Only run after confirming V1 Lean is stable in production
DROP TABLE IF EXISTS error_logs CASCADE;
DROP TABLE IF EXISTS alert_log CASCADE;
DROP TABLE IF EXISTS pending_approvals CASCADE;
DROP TABLE IF EXISTS dead_letter_queue CASCADE;
-- Optional: remove extension if no longer needed
-- DROP EXTENSION IF EXISTS pg_trgm;
```

---

## 11. Startup Script

Save this as `start-n8n.ps1` in your n8n directory:

```powershell
# ═══════════════════════════════════════════════════════════
# Supervisor V1 Lean + Shiny Gmail — n8n Startup Script
# ═══════════════════════════════════════════════════════════

# n8n runtime requirements
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
$env:N8N_CONCURRENCY_PRODUCTION_LIMIT = "3"

# Healthchecks.io Dead Man's Switch
$env:HEALTHCHECKS_PING_URL = "https://hc-ping.com/YOUR-UUID-HERE"

# Supervisor V1 Lean — workflow IDs
$env:SUPERVISOR_WORKFLOW_ID = "YOUR-SUPERVISOR-ID"
$env:HEARTBEAT_WORKFLOW_ID = "YOUR-HEARTBEAT-ID"
$env:RETENTION_WORKFLOW_ID = "YOUR-RETENTION-ID"

# Shiny Gmail — environment variables (if using)
$env:GMAIL_ACCOUNT = "primary"
$env:GEMINI_API_KEY = "YOUR-GEMINI-API-KEY"
$env:GEMINI_MODEL = "gemini-3.1-flash-lite"
$env:TELEGRAM_CHAT_ID = "YOUR-TELEGRAM-CHAT-ID"
$env:TELEGRAM_ALLOW_GROUP_RULES = "false"
$env:WEBHOOK_URL = "https://plywood-visor-plutonium.ngrok-free.dev"

# Start ngrok (for Shiny Gmail Telegram webhook — minimize window)
Start-Process -FilePath "ngrok" -ArgumentList "http", "5678", "--domain", "plywood-visor-plutonium.ngrok-free.dev" -WindowStyle Minimized
Start-Sleep -Seconds 3

# Start n8n
npx n8n
```

> **Remember:** Replace all `YOUR-*-HERE` placeholders with actual values.

### First-Time PowerShell Setup

If the script won't run:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass
```

---

## 12. Production Checklist

Run through this checklist before considering the system "live":

### Database
- [ ] Schema deployed (3 tables created)
- [ ] circuit_state initialized (status='closed', error_count=0)
- [ ] schema_versions shows 'v1_lean'

### Environment
- [ ] NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
- [ ] N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
- [ ] HEALTHCHECKS_PING_URL set and valid
- [ ] SUPERVISOR_WORKFLOW_ID set (actual ID, not placeholder)
- [ ] HEARTBEAT_WORKFLOW_ID set (actual ID, not placeholder)
- [ ] RETENTION_WORKFLOW_ID set (actual ID, not placeholder)

### Credentials
- [ ] Postgres credential assigned to all Postgres nodes
- [ ] Telegram Bot credential assigned to all Telegram nodes
- [ ] HTTP Header Auth credential assigned to HTTP (Running Executions)

### Configuration
- [ ] All 8 Telegram nodes have actual chat ID (not REPLACE_WITH_TELEGRAM_CHAT_ID)
- [ ] All 3 workflows activated
- [ ] All monitored workflows have Error Workflow set to Supervisor Core

### Smoke Tests
- [ ] Test 1: Heartbeat received ✅
- [ ] Test 2: Healthchecks.io shows UP ✅
- [ ] Test 3: Database tables verified ✅
- [ ] Test 4: Error alert received ✅
- [ ] Test 5: Debounce working ✅
- [ ] Test 6: Circuit breaker opens at 5 ✅
- [ ] Test 7: Self-loop detected ✅
- [ ] Test 8: Retention report received ✅

### Post-Test Cleanup
- [ ] Test Error Generator deactivated/deleted
- [ ] Circuit breaker reset to closed
- [ ] Test events cleaned up (optional)

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────┐
│         SUPERVISOR V1 LEAN — QUICK REF          │
├─────────────────────────────────────────────────┤
│                                                 │
│  Workflows:    3                                │
│  Nodes:        46 executable + 3 sticky = 49    │
│  DB Tables:    3                                │
│  AI Cost:      $0                               │
│                                                 │
│  Schedules:                                     │
│    Heartbeat:  every 5 minutes                  │
│    Retention:  every 12 hours                   │
│    Supervisor: on-demand (Error Trigger)        │
│                                                 │
│  Circuit Breaker:                               │
│    Opens at:   5 errors                         │
│    Recovery:   5 min → half_open                │
│                10 min → closed                  │
│    Safety:     1 hour → auto-reset (retention)  │
│                                                 │
│  Debounce:     30 seconds                       │
│  Retention:    90 days                          │
│  DMS Grace:    30 minutes                       │
│  Orphan:       >30 min running                  │
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

**End of Deployment Guide**

*Last updated: 2026-05-24*
*Supervisor V1 Lean — 3 workflows, 46 nodes, $0/month*
