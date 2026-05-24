
# 🛡️ Supervisor V1 Lean

**Automated error monitoring for n8n workflows — circuit breaker, auto-retry, Telegram alerts, zero AI cost.**

`3 workflows` · `50 nodes` · `3 tables` · `$0/month` · `Built with n8n + Postgres + Telegram`

---

## What This Is

Supervisor V1 Lean is a self-hosted error monitoring system for [n8n](https://n8n.io) workflow automation. When any monitored workflow fails, Supervisor catches the error, classifies its severity and category, sends you a formatted Telegram alert with probable cause and recommended action, and optionally auto-retries transient failures — all without any AI or recurring costs.

It runs entirely on your own infrastructure: n8n on localhost, Neon PostgreSQL free tier, a Telegram bot, and Healthchecks.io as a dead man's switch.

---

## The Story

This project started as **Supervisor V23** — a 139-node, 8-workflow AI-powered monitoring system that used DeepSeek to triage errors, search historical fixes, run diagnostics, and suggest repairs.

It was genuinely impressive engineering. It also cost **~500,000 tokens per error** just to send a Telegram message that said "this workflow failed on this node with this error." The same information was available in the Error Trigger payload before any AI processing.

The numbers told the story:

| | V23 | V1 Lean |
|---|---|---|
| Workflows | 8 | **3** |
| Nodes | 139 | **50** |
| DB tables | 7 | **3** |
| Indexes | 17 | **6** |
| AI tokens per error | ~500,000 | **0** |
| Monthly cost | $0.70–$1.40 | **$0** |
| Known bugs | 1 | **0** |
| Deferred items | 9 | **0** |
| Audit rounds | 4 | **10** |

V1 Lean was then hardened across **10 review cycles** (5 audit rounds + 5 rebuttals) by 2 independent AI agents (Claude and GPT), producing **114 approved changes** and rejecting 54 proposals that would have added unnecessary complexity.

The philosophy:

> **V23:** "What if every dependency fails in every possible way? Let AI handle it."
>
> **V1 Lean:** "Catch the error. Tell Chan. Retry if safe. If Telegram fails, log anyway. If everything fails, Healthchecks.io catches the silence."

Three safety layers, zero AI cost.

---

## Architecture

### 3 Workflows, 50 Executable Nodes
Workflow 1 — Supervisor Core          16 nodes + 1 sticky = 17
Workflow 2 — Heartbeat Monitor        25 nodes + 1 sticky = 26
Workflow 3 — Data Retention            9 nodes + 1 sticky = 10
─────────────────────────────────────────────────────────────
Total                                 50 nodes + 3 sticky = 53

**Workflow 1 — Supervisor Core** is the error intake pipeline. It enriches and classifies errors with 7 categories, debounces duplicates with burst counting, manages the circuit breaker with 15-minute rolling decay, guards against self-loops, sends severity-adapted Telegram alerts with probable cause advice, logs events independently of Telegram delivery, and auto-retries transient failures with exponential backoff.

**Workflow 2 — Heartbeat Monitor** runs every 5 minutes. It probes the circuit breaker for auto-recovery, queries system status with per-workflow error breakdown and retry counts, pings Healthchecks.io with true start/completion lifecycle, detects orphan executions with alert memory, monitors critical workflow activation with edge-triggered alerts, and sends HEALTHY/DEGRADED/CRITICAL verdicts with recovery context.

**Workflow 3 — Data Retention** runs every 12 hours. It cleans up events older than 90 days, auto-resets stale circuits as a safety valve, monitors table size and index bloat, verifies schema presence, runs ANALYZE, and sends quiet-by-default reports only when something meaningful happens.

---

## Features

### Error Monitoring
- **Error Trigger** intake from any n8n workflow set to use Supervisor as its error workflow
- **Trigger-node error fallback** — handles both standard execution errors and trigger-node failures (different n8n payload shapes)
- **7-category classification** — `auth`, `rate_limit`, `timeout`, `connectivity`, `code_bug`, `resource`, `unknown`
- **Severity inference** — 🔴 critical (auth/credentials), 🟡 warning (timeout/rate limit/connectivity), 🟠 error (general)
- **Credential sanitization** — strips Postgres URLs, JWT tokens, API keys, and passwords before Telegram or database writes
- **Normalized fingerprinting** — strips UUIDs, IPs, URLs, timestamps, and large numbers for stable dedup across dynamic error messages

### Circuit Breaker
- **Atomic Postgres CTE** with `FOR UPDATE` — single query handles upsert, count increment, state transition, and transition logging
- **15-minute rolling decay** — sparse errors across hours don't accumulate; only concentrated bursts within 15 minutes trip the circuit
- **5-error threshold** — circuit opens after 5 errors within the decay window
- **Unified alert path** — the circuit-tripping error gets the full rich alert (probable cause, retry eligibility) plus a circuit-open banner, not a stripped-down separate notification
- **Auto-recovery** via heartbeat: open → half_open (5 min), half_open → closed (10 min without errors)
- **Safety valve** via data retention: stale open circuits auto-reset after 1 hour
- **Suppression via empty return** — when circuit is open, Merge Circuit Result returns `[]` and n8n halts downstream naturally

### Debounce
- **30-second window** via `staticData` — identical errors within 30 seconds are suppressed
- **Normalized fingerprint** — `workflowName::failedNode::normalizedError` with UUIDs, IPs, timestamps stripped
- **Burst counting** — tracks suppressed duplicate count, included in next alert ("⚡ 5 duplicates suppressed since last alert")
- **Auto-cleanup** — stale debounce and burst keys older than 5 minutes are garbage collected

### Self-Loop Guard
- **ID-based detection** — checks all 3 monitoring workflow IDs via `$env` variables
- **Name-based fallback** — substring match against monitoring workflow names as defense-in-depth
- **Absorbed into enrichment** — self-loop detection runs inside Enrich & Classify, before debounce and circuit logic, preventing monitoring errors from poisoning the circuit counter
- **Parallel logging** — self-loop events are logged to the database independently of Telegram delivery

### Telegram Alerts
- **Severity-adapted formatting** — critical alerts show full detail; warning/error alerts show compact format
- **Taxonomy labels** — `NEW ERROR`, `BURST UPDATE`, `CIRCUIT OPEN`, `RETRY FAILED` in the first line for instant Telegram preview scanning
- **Probable cause + recommended action** — deterministic advice per error category ("Likely cause: credential expired. Action: check credential validity.")
- **Circuit-open banner** — prepended to the normal alert when the circuit trips, preserving all context in one message
- **Compact HTML links** — `...` instead of raw URLs
- **Silent non-critical alerts** — warning/error alerts use `disable_notification: true`; only critical alerts and circuit-open transitions buzz the phone
- **Entity-safe truncation** — raw text truncated before HTML escaping, never cutting mid-entity
- **Telegram length guard** — `clampTelegramHtml()` prevents messages exceeding Telegram's 4096-char limit
- **Web preview disabled** — `disable_web_page_preview: true` on all Telegram nodes

### Auto-Retry
- **Transient failures only** — retries `connectivity`, `rate_limit`, and `timeout` categories
- **retryOf guard** — if the execution is already a retry, skip auto-retry entirely (prevents infinite loops)
- **NEVER_RETRY denylist** — optional `$env.NEVER_RETRY_WORKFLOW_IDS` for workflows with non-idempotent side effects (payments, external messages)
- **Fingerprint-based cooldown** — max 2 retries per fingerprint per hour
- **Exponential backoff** — 15s base, 2^n scaling, 120s cap, random 0-5s jitter via Wait node
- **Retry receipt logging** — successful retry submissions logged to `supervisor_events` via cross-node reference (immune to `$json` replacement by HTTP node)
- **Parallel execution** — retry runs parallel to Telegram and DB logging, not downstream

### Heartbeat Monitor
- **5-minute schedule** with MD5 hash dedup — "no news = good news"
- **True DMS lifecycle** — `/start` ping at beginning of heartbeat, success ping after all checks complete
- **HEALTHY / DEGRADED / CRITICAL verdict** — instant top-line status
- **Recovery banner with context** — "✅ RECOVERED — System returned to HEALTHY from DEGRADED (circuit closed, DMS restored)"
- **Per-workflow error breakdown** — top 5 error sources in last 24h with 1-hour counts
- **Auto-retry visibility** — retry counts in the dashboard ("🔄 Auto-Retries: 3 (1h) · 5 (24h)")
- **Trend direction arrows** — 📈 increasing, 📉 decreasing, ➡️ stable
- **Hash stability** — volatile counters bucketed before hashing to prevent phantom notifications from natural counter decay
- **Silent healthy heartbeats** — `disable_notification: true` when HEALTHY
- **Orphan confidence state** — `none` / `found` / `uncertain` / `api_error` as single source of truth
- **API error edge-triggering** — API unreachable alerts fire on first detection + hourly re-alert, not every 5 minutes
- **Heartbeat local cache** — honest per-workflow cache labeling (staticData is workflow-local, not cross-workflow)

### Dead Man's Switch
- **Healthchecks.io** integration with true start/completion lifecycle
- **`/start` signal** at beginning of heartbeat cycle
- **Success ping** after all checks, logging, and cache clearing complete
- **30-minute grace period** — laptop can sleep briefly without false alerts
- **Previous-cycle DMS state** — heartbeat dashboard shows DMS status from last cycle (5-minute lag, acceptable for a dead man's switch indicator)

### Orphan Execution Detection
- **n8n REST API** query for running executions
- **30-minute threshold** — flags any non-excluded execution running longer than 30 minutes
- **Monitoring exclusion** — all 3 Supervisor workflow IDs excluded
- **Long-runner exclusion** — optional `$env.LONG_RUNNING_WORKFLOW_IDS` for legitimate long-running workflows
- **Alert memory** — first detection + hourly re-alert only (not every 5 minutes)
- **Confidence state** — `none`, `found`, `uncertain`, `api_error` — reflected in heartbeat dashboard
- **Consolidated alert path** — API errors and orphan detections share a single IF gate and Telegram node

### Activation Monitoring
- **Critical workflow roster** — `$env.CRITICAL_WORKFLOW_IDS` checked against n8n active workflows API
- **Edge-triggered alerts** — SHA-1 state hash ensures dedicated alerts only fire on state changes, not every 5 minutes
- **Uncertainty handling** — API errors or malformed responses flagged as uncertain, not falsely declared inactive
- **Clickable workflow URLs** — inactive workflow IDs rendered as `<a>` links for one-tap investigation

### Data Retention
- **90-day retention** on supervisor_events with bounded deletes (LIMIT 1000)
- **Stale circuit safety valve** — resets circuits open >1 hour with no new errors
- **Table size monitoring** — warns at 50MB threshold
- **Index bloat detection** — `pg_indexes_size()` with 50MB threshold warning
- **Schema presence check** — verifies `v1_lean` version + 3/3 expected tables
- **ANALYZE pass** after cleanup for query planner freshness
- **Quiet by default** — only sends Telegram on DB error, schema drift, limit hit, stale circuit reset, size warnings, or weekly summary
- **Delivery-aware weekly timer** — weekly report timestamp only advances after confirmed Telegram delivery (checks `message_id`)
- **Retention logged on ALL paths** — `retention_completed` event written whether Telegram succeeds, fails, or is skipped

### Resilience Pattern
- **Every Postgres node**: `onError: continueErrorOutput` — failures never crash the workflow
- **Every Telegram node**: `onError: continueErrorOutput` — delivery failures are caught
- **DB logging independent of Telegram** — alert events written parallel to Telegram send, not downstream
- **Single-JSON-parameter INSERT pattern** — all Postgres INSERTs use `($1::jsonb)->>'field'` extraction, immune to n8n's `queryReplacement` comma-split bug
- **No write-only caches** — Supervisor Core and Data Retention have no dead-data cache nodes; error outputs are terminal

---

## How It Works


Any n8n workflow fails
│
▼
Error Trigger (Supervisor Core)
│
▼
Enrich & Classify
(sanitize, categorize, fingerprint, self-loop detect)
│
├── Self-loop → Telegram + Log (parallel) → stop
│
▼
Debounce Check (30s window)
├── Duplicate → Log & stop
└── New error ──▼
Circuit Breaker Update (15-min rolling decay)
│
├── Circuit suppressing → stop (empty return)
└── Continue ──▼
Format Alert Message
(circuit banner if newly open,
probable cause, compact links)
│
┌────────┼────────┐
▼        ▼        ▼
Telegram  Log Event  Auto-Retry?
(if eligible)
│
▼
Wait (backoff)
│
▼
HTTP Retry → Log Receipt

Meanwhile, every 5 minutes:


Heartbeat Monitor
├── DMS Start (/start ping)
├── Circuit recovery probe (auto-heal)
├── System status + error trends + retry counts
├── Orphan execution scan (with alert memory)
├── Activation monitoring (edge-triggered)
├── Evaluate health → HEALTHY/DEGRADED/CRITICAL
├── Send update (only if state changed or hourly pulse)
├── Log heartbeat event
├── Clear local cache
└── DMS Complete (success ping)

And every 12 hours:


Data Retention
├── Delete events > 90 days (LIMIT 1000)
├── Reset stale circuits (safety valve)
├── Check table size + index bloat
├── Verify schema presence
├── ANALYZE tables
├── Report (only if meaningful)
└── Log retention_completed (always)

---

## Database

3 tables on Neon PostgreSQL free tier (Singapore region, Postgres 17):

| Table | Rows | Purpose |
|---|---|---|
| `circuit_state` | 1 (always) | Circuit breaker state — closed/open/half_open with rolling decay |
| `supervisor_events` | Growing (90-day retention) | Audit trail + trend detection + retry receipts |
| `schema_versions` | 1 | Migration tracking (checked by retention for schema presence) |

6 indexes including a partial unique index for orphan event dedup with hourly time-bucketing. 3 CHECK constraints enforce valid states, severities, and event types.

All INSERT operations use the single-JSON-parameter pattern (`($1::jsonb)->>'field'`) to avoid n8n's documented `queryReplacement` comma-split bug.

---

## Sample Telegram Messages

### Error Alert (warning severity — silent notification)

🟡 NEW ERROR — timeout
Workflow: Shiny Gmail Daily Orchestrator → Postgres (Mark Run Started)
Error: connection timeout after 10000ms
Execution: Open execution
💡 Slow dependency or long-running operation.
🔧 Check external service latency and node timeout settings.
Retryable: yes — auto-retry eligible
Circuit: Error 2 of 5
Trace: err-12345-1716537411000
May 25, 2026, 06:00:01

### Critical Alert (audible notification)

🔴 CRITICAL — auth
Workflow: Shiny Gmail Single Email Processor
Failed Node: Gmail (Apply Category Label)
Category: auth
Error: Request had insufficient authentication scopes
Execution: Open execution
💡 Likely cause: Credential expired, revoked, or permission issue.
🔧 Action: Check credential validity and recent permission changes.
Retryable: no (auth)
Circuit: Error 4 of 5
Trace: err-12346-1716537412000
May 25, 2026, 06:00:02

### Circuit Breaker Open (merged into normal alert)

🔴 CIRCUIT BREAKER OPENED
Threshold: 5 of 5
Effect: New errors will be suppressed until recovery probe.
🔴 CIRCUIT OPEN — rate limit
Workflow: CRM Sync → HTTP Request
Error: 429 Too Many Requests
Execution: Open execution
💡 External API quota or burst threshold reached.
🔧 Confirm provider rate limits; reduce concurrency or increase backoff.
Retryable: yes — auto-retry eligible
Circuit: Error 5 of 5
Trace: err-12350-1716537500000
May 25, 2026, 06:05:00

### Heartbeat (HEALTHY — silent notification)

💓 SUPERVISOR — 🟢 HEALTHY
🟢 Circuit: closed (0/5)
🟢 DMS: ok
🟢 Workflows: 4/4 active
🟢 Orphans: none
📊 Trend: 🟢 stable ➡️
🔄 Auto-Retries: 0 (1h) · 0 (24h)
Errors: 0 (1h) · 0 (24h)
May 25, 2026, 07:00:01

### Heartbeat (DEGRADED — audible notification)

💓 SUPERVISOR — 🟡 DEGRADED
🟡 Circuit: half_open (3/5)
🟢 DMS: ok
🟢 Workflows: 4/4 active
🔴 Orphans: 2 detected
📊 Trend: 🔴 spike 📈
🔄 Auto-Retries: 3 (1h) · 5 (24h)
Errors: 5 (1h) · 12 (24h)
🏆 Top Sources (24h):

Invoice Sync — 8 errors (3 in 1h)
CRM Push — 3 errors (1 in 1h)

🚨 Heartbeat Local Cache: 1 failed event(s)
May 25, 2026, 07:05:01

### Recovery (audible notification)

✅ RECOVERED — System returned to HEALTHY from DEGRADED (circuit closed, orphans resolved)
💓 SUPERVISOR — 🟢 HEALTHY
🟢 Circuit: closed (0/5)
🟢 DMS: ok
🟢 Workflows: 4/4 active
🟢 Orphans: none
📊 Trend: 🟢 stable 📉
🔄 Auto-Retries: 0 (1h) · 3 (24h)
Errors: 0 (1h) · 8 (24h)
May 25, 2026, 08:00:01

### Retention Report (silent, only when meaningful)

🧹 DATA RETENTION REPORT — V1 Lean
Deleted Events (90d): 47
Remaining Events: 853
Events Table Size: 2.1 MB
Events Index Size: 1.3 MB
Schema: ✅ v1_lean present, 3/3 tables
✅ ANALYZE: completed successfully.
May 25, 2026, 12:00:01

---

## Prerequisites

- **n8n** self-hosted (tested on 2.12.3, Windows/PowerShell)
- **Neon PostgreSQL** free tier (or any Postgres 14+)
- **Telegram Bot** — create via https://t.me/BotFather
- **Healthchecks.io** account — free tier, create a check with 5-minute period and 30-minute grace

---

## Quick Start

### 1. Create the database

Run `database/schema.sql` against your Postgres instance:

```powershell
psql "postgresql://user:pass@host/db?sslmode=require" -f database/schema.sql
```

Or paste the SQL into Neon's SQL Editor.

### 2. Import workflows

Import in this order in n8n:

- `workflows/workflow_1_supervisor_core.json`
- `workflows/workflow_2_heartbeat_monitor.json`
- `workflows/workflow_3_data_retention.json`

### 3. Set environment variables

```powershell
# Required — n8n runtime
$env:NODE_FUNCTION_ALLOW_BUILTIN = "crypto"
$env:N8N_BLOCK_ENV_ACCESS_IN_NODE = "false"

# Required — Healthchecks.io
$env:HEALTHCHECKS_PING_URL = "https://hc-ping.com/your-uuid"

# Required — Workflow IDs (self-loop guard + orphan exclusion)
$env:SUPERVISOR_WORKFLOW_ID = "your-supervisor-workflow-id"
$env:HEARTBEAT_WORKFLOW_ID = "your-heartbeat-workflow-id"
$env:RETENTION_WORKFLOW_ID = "your-retention-workflow-id"

# Required — Telegram
$env:TELEGRAM_CHAT_ID = "your-telegram-chat-id"

# Required — Activation monitoring
$env:CRITICAL_WORKFLOW_IDS = "id1,id2,id3"

# Optional — Orphan detection exclusion
$env:LONG_RUNNING_WORKFLOW_IDS = "id4,id5"

# Optional — Auto-retry safety denylist
$env:NEVER_RETRY_WORKFLOW_IDS = "id6,id7"

# Optional — n8n concurrency
$env:N8N_CONCURRENCY_PRODUCTION_LIMIT = "3"
```

### 4. Assign credentials and activate

- Assign Postgres, Telegram Bot, and HTTP Header Auth credentials to all relevant nodes
- Activate all 3 workflows
- Set Supervisor Core as the Error Workflow on all monitored workflows

### 5. Smoke test

Create a test workflow with a Code node that throws `throw new Error('Supervisor smoke test')`, set its Error Workflow to Supervisor Core, activate, and trigger. You should receive a Telegram alert within seconds.

See `docs/deployment-guide.md` for the complete 8-test smoke test suite.

**Note:** Use PowerShell `$env:` syntax, not Bash `export`. This project runs on Windows.


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


## Audit History

This system survived 10 review cycles (5 audit rounds + 5 rebuttals) by 2 independent AI agents:

| Metric | Count |
|---|---|
| Total approved changes | 114 |
| Total rejected proposals | 54 |
| Critical bugs found and fixed | 11 |
| Review cycles | 10 |
| AI agents involved | 2 (Claude, GPT) |
























### Key Discoveries Across Audit Rounds

- **n8n's queryReplacement comma-split bug** on JSON payloads (silent data loss)
- **`$json` data replacement** by Telegram/HTTP nodes (silent NULL metadata in logs)
- **`disable_notification` expression** evaluating undefined as true (all alerts silent)
- **`staticData` being workflow-local**, not cross-workflow (false "emergency cache pickup" claim)
- **Circuit counter** being an eternal accumulator instead of a burst detector

---

## n8n Deployment Gotchas

- **n8n blocks crypto and `$env` by default** — set env vars before starting
- **Error Trigger only fires on production runs** — not manual test executions
- **Postgres nodes with 0 results** stop execution chains — use "Always Output Data"
- **n8n Telegram node silently drops inline keyboard buttons** — confirmed platform limitation
- **`$env` expressions show red errors in the UI** — normal, resolves at runtime
- **Telegram/HTTP nodes replace `$json`** — log nodes downstream of action nodes receive API response, not original data. Use cross-node references (`$('NodeName').first().json`)
- **n8n import can corrupt IF/Switch output mappings** — delete and recreate if routing is wrong
- **Neon serverless Postgres can take 1-3s to wake** — use `connectionTimeout: 10`
- **`queryReplacement` splits on commas inside values** — use single-JSON-parameter pattern (`$1::jsonb`) for any INSERT with JSON payloads

---

## Security Advisory
CVE-2026-44789, CVE-2026-44790, and CVE-2026-44791 affect n8n versions below 2.20.7. If running n8n 2.12.3, evaluate upgrading. The HTTP Request prototype pollution vulnerability affects 4 HTTP nodes in the supervisor workflows.

---

## Related Projects

- **[shiny-gmail-automation](https://github.com/chanrylejay/shiny-gmail-automation)** — Automated Gmail cleanup with AI classification, Telegram rules manager, and Postgres ledger. Same author, same lean philosophy.

Both projects share the same evolution story: overengineered God Mode → battle-tested Lean.

---

## License

See LICENSE file.

---

## Author

**Chan (Chanryle Jay Cagara)**  
Manila, Philippines

Non-technical builder creating production automation systems with n8n.

- **GitHub:** https://github.com/chanrylejay
- **Telegram:** https://t.me/pefectsea