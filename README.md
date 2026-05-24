# 🛡️ Supervisor V1 Lean

**Automated error monitoring for n8n workflows — circuit breaker, Telegram alerts, zero AI cost.**

`3 workflows` · `46 nodes` · `3 tables` · `$0/month` · `Built with n8n + Postgres + Telegram`

---

## What This Is

Supervisor V1 Lean is a self-hosted error monitoring system for [n8n](https://n8n.io) workflow automation. When any monitored workflow fails, Supervisor catches the error, classifies its severity, and sends you a Telegram alert — complete with execution link, retry guidance, and circuit breaker status.

It runs entirely on your own infrastructure: n8n on localhost, Neon PostgreSQL free tier, a Telegram bot, and Healthchecks.io as a dead man's switch. No external AI APIs. No recurring costs.

---

## The Story

This project started as **Supervisor V23** — a 139-node, 8-workflow AI-powered monitoring system that used DeepSeek to triage errors, search historical fixes, run diagnostics, and suggest repairs.

It was genuinely impressive engineering. It also cost **~500,000 tokens per error** just to send a Telegram message that said "this workflow failed on this node with this error." The same information was available in the Error Trigger payload before any AI processing.

The numbers told the story:

| | V23 | V1 Lean |
|---|---|---|
| Workflows | 8 | **3** |
| Nodes | 139 | **46** |
| DB tables | 7 | **3** |
| Indexes | 17 | **6** |
| AI tokens per error | ~500,000 | **0** |
| Monthly cost | $0.70–$1.40 | **$0** |
| Known bugs | 1 | **0** |
| Deferred items | 9 | **0** |

V23's long-term vision was a self-improving knowledge base: errors would auto-resolve from historical fixes. In practice, the error log was small, the search tool almost always returned "no match found," the repair tool generated generic advice, and the approval buttons were silently dropped by n8n due to a platform limitation.

So I rebuilt it with the same philosophy I applied to [Shiny Gmail Automation](https://github.com/chanrylejay/shiny-gmail-automation):

> **V23:** "What if every dependency fails in every possible way? Let AI handle it."
>
> **V1 Lean:** "Catch the error. Tell Chan. If Telegram fails, cache it. If everything fails, Healthchecks.io catches the silence."

Three safety layers, zero AI cost.

---

## Architecture

### 3 Workflows, 46 Executable Nodes

```
Workflow 1 — Supervisor Core          18 nodes + 1 sticky = 19
Workflow 2 — Heartbeat Monitor        21 nodes + 1 sticky = 22
Workflow 3 — Data Retention            7 nodes + 1 sticky =  8
─────────────────────────────────────────────────────────────
Total                                 46 nodes + 3 sticky = 49
```

**Workflow 1 — Supervisor Core** is the error intake pipeline. It receives errors from any monitored workflow, normalizes the payload with severity inference and credential sanitization, debounces duplicates, manages the circuit breaker, guards against self-loops, and sends a formatted Telegram alert.

**Workflow 2 — Heartbeat Monitor** runs every 5 minutes. It probes the circuit breaker for auto-recovery, queries system status with error rate trends, pings Healthchecks.io, detects orphan executions via the n8n API, and sends status updates only when something changes.

**Workflow 3 — Data Retention** runs every 12 hours. It cleans up events older than 90 days, auto-resets stale circuits as a safety valve, runs ANALYZE for query planner freshness, and sends a cleanup report.

---

## Features

### Error Monitoring
- **Error Trigger** intake from any n8n workflow set to use Supervisor as its error workflow
- **Payload normalization** — extracts execution ID, workflow name, failed node, error message, execution URL from n8n's error object
- **Severity inference** — pattern-matches error messages to classify as 🔴 critical (auth/credentials), 🟡 warning (timeout/rate limit), or 🟠 error (general)
- **Credential sanitization** — strips Postgres URLs, JWT tokens, API keys, and passwords before they reach Telegram or the database

### Circuit Breaker
- **Atomic Postgres CTE** with `FOR UPDATE` — single query handles upsert, count increment, and state transition
- **5-error threshold** — circuit opens after 5 errors, suppressing all further alerts until recovery
- **Auto-recovery** via heartbeat: open → half_open (5 min), half_open → closed (10 min without errors)
- **Safety valve** via data retention: stale open circuits auto-reset after 1 hour
- **Escalation awareness** — every alert shows "Error X of 5" so you know how close the circuit is to opening

### Debounce
- **30-second window** via `staticData` — identical errors within 30 seconds are suppressed
- **Fingerprint generation** — `workflowName::failedNode::errorMessage(100chars)` normalized to lowercase
- **Auto-cleanup** — stale debounce keys older than 5 minutes are garbage collected

### Self-Loop Guard
- **ID-based detection** — checks all 3 monitoring workflow IDs via `$env` variables
- **Name-based fallback** — substring match against monitoring workflow names as defense-in-depth
- **Suppression with alert** — self-loop errors send a dedicated Telegram alert and stop (no infinite recursion)

### Telegram Alerts
- **Severity icons** — 🔴 critical, 🟡 warning, 🟠 error — instant triage from the notification
- **Circuit escalation** — "Error 3 of 5" tells you the urgency
- **Execution URL** — direct link to the failed execution in n8n
- **Retryable indicator** — whether the error is likely transient or permanent

### Heartbeat Monitor
- **5-minute schedule** with MD5 hash dedup — "no news = good news"
- **Error rate trends** — `errors_last_hour` and `errors_last_24h` with trend indicator (🟢 stable / 🟡 elevated / 🔴 spike)
- **Emergency cache pickup** — reads `staticData` failures from all workflows and reports them
- **Cache cleared only after successful Telegram send** — no silent data loss

### Dead Man's Switch
- **Healthchecks.io** integration — external monitoring pings every 5 minutes
- **30-minute grace period** — laptop can sleep briefly without false alerts
- **DMS failure alert** — dedicated Telegram message if the ping fails

### Orphan Execution Detection
- **n8n REST API** query for running executions
- **30-minute threshold** — flags any non-monitoring execution running longer than 30 minutes
- **Monitoring exclusion** — all 3 Supervisor workflow IDs excluded from orphan detection
- **Uncertainty tracking** — if API returns 0 executions during active system state, flags it rather than assuming clean

### Data Retention
- **90-day retention** on supervisor_events with bounded deletes (LIMIT 1000)
- **ANALYZE pass** after cleanup for query planner freshness
- **Stale circuit safety valve** — resets circuits open >1 hour with no new errors
- **Limit-hit warning** — alerts when deletion cap is reached

### Resilience Pattern
- **Every Postgres node**: `onError: continueErrorOutput` — failures never crash the workflow
- **Every Telegram node**: `onError: continueErrorOutput` — delivery failures are caught
- **Cache Event Failure** — universal catch-all caches failures to `staticData` (bounded to 50 entries)
- **Heartbeat pickup** — cached failures are reported in the next heartbeat cycle

---

## How It Works

```
Any n8n workflow fails
        │
        ▼
   Error Trigger (Supervisor Core)
        │
        ▼
   Normalize + Severity Inference + Sanitize
        │
        ▼
   Debounce Check (30s window)
   ├── Duplicate → Log & stop
   └── New error ──▼
                Circuit Breaker Update
                    │
                    ├── Circuit OPEN → Alert & stop
                    └── Circuit OK ──▼
                                 Self-Loop Check
                                     │
                                     ├── Self-loop → Alert & stop
                                     └── Normal ──▼
                                              Format Alert
                                              (severity, "Error X of 5", URL)
                                                  │
                                                  ▼
                                              Telegram → Log event
```

Meanwhile, every 5 minutes:

```
Heartbeat Monitor
    ├── Circuit recovery probe (auto-heal)
    ├── System status + error trends
    ├── Dead Man's Switch ping
    ├── Orphan execution scan
    └── Send update (only if state changed)
```

And every 12 hours:

```
Data Retention
    ├── Delete events > 90 days
    ├── Reset stale circuits (safety valve)
    ├── ANALYZE tables
    └── Send report
```

---

## Database

3 tables on Neon PostgreSQL free tier (Singapore region, Postgres 17):

| Table | Rows | Purpose |
|---|---|---|
| `circuit_state` | 1 (always) | Circuit breaker state — closed/open/half_open |
| `supervisor_events` | Growing (90-day retention) | Audit trail + trend detection source |
| `schema_versions` | 1 | Migration tracking |

6 indexes including a partial unique index for orphan event dedup. 3 CHECK constraints enforce valid states, severities, and event types.

---

## Sample Telegram Messages

### Error Alert (with severity)
```
🟠 ERROR — WORKFLOW ERROR

Workflow: Shiny Gmail Daily Orchestrator
Failed Node: Postgres (Mark Run Started)
Error: connection timeout after 10000ms
Execution: http://localhost:5678/executions/12345
Retryable: yes
Circuit: Error 2 of 5

Trace: err-12345-1716537411000
Timestamp: 2026-05-24T06:00:01Z
```

### Critical Alert
```
🔴 CRITICAL — WORKFLOW ERROR

Workflow: Shiny Gmail Single Email Processor
Failed Node: Gmail (Apply Category Label)
Error: Request had insufficient authentication scopes
Execution: http://localhost:5678/executions/12346
Retryable: no
Circuit: Error 4 of 5

Trace: err-12346-1716537412000
Timestamp: 2026-05-24T06:00:02Z
```

### Heartbeat (with trends)
```
💓 HEARTBEAT — Supervisor V1 Lean

Circuit: 🟢 closed (0 errors)
Errors (1h): 0
Errors (24h): 3
Trend: 🟢 stable

Timestamp: 2026-05-24T06:00:00Z
```

### Heartbeat (degraded)
```
💓 HEARTBEAT — Supervisor V1 Lean

Circuit: 🟡 half_open (3 errors)
Errors (1h): 3
Errors (24h): 8
Trend: 🔴 spike

🚨 Emergency Cache: 2 failed event(s)

Timestamp: 2026-05-24T06:05:00Z
```

### Circuit Breaker
```
🔴 CIRCUIT BREAKER OPEN

Error count: 5
Last error: Shiny Gmail Daily Orchestrator → Gemini Classify Email
Error: 429 Too Many Requests
Trace: err-12350-1716537500000

⚠️ All new errors will be suppressed until circuit resets.
```

### Self-Loop Detection
```
🔁 SELF-LOOP DETECTED

The Supervisor caught an error from its own monitoring workflows.

Workflow: Heartbeat Monitor V1 Lean
Failed Node: System Status Query
Error: connection refused
Trace: err-hb-123-1716537600000

⚠️ Suppressed to prevent infinite error loops.
```

---

## Prerequisites

- **n8n** self-hosted (tested on 2.12.3, Windows/PowerShell)
- **Neon PostgreSQL** free tier (or any Postgres 14+)
- **Telegram Bot** — create via [@BotFather](https://t.me/BotFather)
- **Healthchecks.io** account — free tier, create a check with 5-minute period and 30-minute grace

---

## Quick Start

### 1. Create the database

Run `database/schema.sql` against your Postgres instance:

```powershell
# Using psql (adjust connection string)
psql "postgresql://user:pass@host/db?sslmode=require" -f database/schema.sql
```

Or paste the SQL into Neon's SQL Editor.

### 2. Import workflows

Import in this order in n8n:

1. `workflows/workflow_1_supervisor_core.json`
2. `workflows/workflow_2_heartbeat_monitor.json`
3. `workflows/workflow_3_data_retention.json`

### 3. Configure

In each workflow, replace `REPLACE_WITH_TELEGRAM_CHAT_ID` with your Telegram chat ID.

Set up n8n credentials:
- **Postgres** — your Neon connection string (pooled endpoint, SSL: Allow)
- **Telegram Bot** — bot token from BotFather
- **Header Auth** — for n8n API access (orphan detection)
- **Healthchecks.io** — ping URL as environment variable

### 4. Note workflow IDs

After import, note each workflow's ID from the URL bar. You'll need them for the environment variables.

### 5. Set environment variables

```powershell
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"
$env:HEALTHCHECKS_PING_URL = "https://hc-ping.com/your-uuid"
$env:SUPERVISOR_WORKFLOW_ID = "your-supervisor-workflow-id"
$env:HEARTBEAT_WORKFLOW_ID = "your-heartbeat-workflow-id"
$env:RETENTION_WORKFLOW_ID = "your-retention-workflow-id"
```

### 6. Activate workflows

Activate all 3 workflows in n8n.

### 7. Set as Error Workflow

For every workflow you want monitored, go to:
**Settings → Error Workflow → Supervisor Core V1 Lean**

### 8. Smoke test

Create a test workflow with a Code node that throws an error:

```javascript
throw new Error('Supervisor smoke test');
```

Set its Error Workflow to Supervisor Core, activate it, and trigger it. You should receive a Telegram alert within seconds.

---

## Environment Variables

```powershell
# Required — n8n runtime
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"

# Required — Healthchecks.io
$env:HEALTHCHECKS_PING_URL = "https://hc-ping.com/your-uuid"

# Required — Workflow IDs (for self-loop guard + orphan exclusion)
$env:SUPERVISOR_WORKFLOW_ID = "your-supervisor-workflow-id"
$env:HEARTBEAT_WORKFLOW_ID = "your-heartbeat-workflow-id"
$env:RETENTION_WORKFLOW_ID = "your-retention-workflow-id"

# Optional — n8n concurrency
$env:N8N_CONCURRENCY_PRODUCTION_LIMIT = "3"
```

> **Note:** Use PowerShell `$env:` syntax, not Bash `export`. This project runs on Windows.

---

## Repository Structure

```
supervisor-v1-lean/
├── README.md
├── LICENSE
├── workflows/
│   ├── workflow_1_supervisor_core.json
│   ├── workflow_2_heartbeat_monitor.json
│   └── workflow_3_data_retention.json
├── database/
│   └── schema.sql
└── docs/
    └── deployment-guide.md
```

---

## n8n Deployment Gotchas

Lessons learned from deploying V23 and V1 Lean:

1. **n8n blocks `crypto` and `$env` by default** — you must set `NODE_FUNCTION_ALLOW_BUILTIN=crypto` and `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`
2. **Error Trigger only fires on production runs** — not manual test executions. You must activate the monitored workflow to test.
3. **Postgres nodes with 0 results stop execution chains** — enable "Always Output Data" where empty results are expected
4. **n8n Telegram node silently drops inline keyboard buttons** when callback data uses expressions — confirmed platform limitation
5. **`$env` expressions show red errors in the UI** — this is normal. They resolve at runtime.
6. **Windows uses `$env:VAR = "value"`** — not Bash `export VAR=value`
7. **n8n import can corrupt IF/Switch node output mappings** — if wiring looks correct but routes wrong, delete and recreate the node from scratch
8. **Neon serverless Postgres can take 1-3s to wake from idle** — use `connectionTimeout: 10` in credentials if needed

---

## Related Projects

- **[Shiny Gmail Automation](https://github.com/chanrylejay/shiny-gmail-automation)** — Automated Gmail cleanup with AI classification, Telegram rules manager, and Postgres ledger. Same author, same lean philosophy.

Both projects share the same evolution story: overengineered God Mode → battle-tested Lean.

---

## License

[MIT](LICENSE)

---

## Author

**Chan (Chanryle Jay Cagara)**
Manila, Philippines

Non-technical builder creating production automation systems with n8n.

- GitHub: [@chanrylejay](https://github.com/chanrylejay)
- Telegram: [@pefectsea](https://t.me/pefectsea)
