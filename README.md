***

# 🛡️ Supervisor Error Handling Workflow

**Automated error monitoring for n8n workflows — circuit breaker, auto-retry, Telegram alerts, zero AI cost.**

`3 workflows` · `48 nodes` · `3 tables` · `7 indexes` · `$0/month` · `Built with n8n + Postgres + Telegram`

***

## What This Is

A self-hosted error monitoring system for <https://n8n.io> workflow automation. When any monitored workflow fails, the Supervisor catches the error, classifies its severity and category, sends you a formatted Telegram alert with probable cause and recommended action, and optionally auto-retries transient failures — all without any AI or recurring costs.

It runs entirely on your own infrastructure: self-hosted n8n, PostgreSQL (Neon free tier works), a Telegram bot, and Healthchecks.io as a dead man's switch.

***

## Why This Exists

Most n8n error handling setups are "Error Trigger → Slack/Telegram message." That covers maybe 20% of what can go wrong.

This project asks: what happens when Telegram is down? When Postgres is unreachable? When the monitoring workflow itself fails? When 5 different workflows fail simultaneously? When a transient timeout deserves a retry but a credential error doesn't?

The Supervisor handles all of these with a 5-layer suppression cascade, a global circuit breaker, storm detection, delivery failure caching, and a dead man's switch — in 48 nodes across 3 workflows at $0/month.

***

## Architecture

### 3 Workflows, 48 Executable Nodes

```
Workflow 1 — Supervisor Core          18 nodes + 1 sticky = 19
Workflow 2 — Heartbeat Monitor        21 nodes + 1 sticky = 22
Workflow 3 — Data Retention            9 nodes + 1 sticky = 10
─────────────────────────────────────────────────────────────
Total                                 48 nodes + 3 sticky = 51
```

**Workflow 1 — Supervisor Core** is the error intake pipeline. It enriches and classifies errors into 7 categories, debounces duplicates with burst counting, manages the circuit breaker with 15-minute rolling decay, guards against self-loops, detects error storms across multiple workflows, sends severity-adapted Telegram alerts with probable cause advice and a Supervisor Action line, logs events independently of Telegram delivery, and auto-retries transient failures with exponential backoff.

**Workflow 2 — Heartbeat Monitor** runs every 5 minutes. It probes the circuit breaker for auto-recovery, queries system status with per-workflow error breakdown, pings Healthchecks.io with true start/completion lifecycle, detects orphan executions with tiered severity escalation, monitors critical workflow activation with state-change alerts, evaluates control-plane confidence, owns storm lifecycle (start/resolve), and sends HEALTHY/DEGRADED/CRITICAL verdicts with recovery duration and context.

**Workflow 3 — Data Retention** runs every 12 hours. It cleans up events older than 90 days, auto-resets stale circuits as a safety valve, repairs circuit state invariants, monitors table size and index bloat, verifies schema presence, runs ANALYZE, reports data span and oldest event age, and sends quiet-by-default reports with humanized reasons only when something meaningful happens.

***

## Features

### Error Monitoring

* **7-category classification** — `auth`, `rate_limit`, `timeout`, `connectivity`, `code_bug`, `resource`, `unknown`
* **Severity inference** — 🔴 critical, 🟡 warning, 🟠 error
* **Credential sanitization** — strips database URLs, JWT tokens, API keys, and passwords before logging or alerting
* **Normalized fingerprinting** — strips UUIDs, IPs, URLs, timestamps for stable dedup across dynamic error messages
* **JSON error body extraction** — handles nested API error responses with deduplication guard

### Circuit Breaker

* **Atomic Postgres CTE** with `FOR UPDATE` row locking — single query handles upsert, state transition, and transition logging
* **15-minute rolling decay** — sparse errors don't accumulate; only concentrated bursts trip the circuit
* **5-error threshold** with half-open test slot for controlled recovery
* **Transition reason tracking** — alerts show whether circuit opened from closed threshold or half-open reopen
* **Recovery probe estimate** — operator sees "\~5-10 min after errors stop"
* **Proactive `half_open_at` cleanup** — data invariant maintained in the hot path

### Storm Detection

* **Cross-fingerprint correlation** — 3+ distinct error patterns in 5 minutes = error storm
* **Self-loop quarantine** — monitoring workflow errors cannot trigger false storms
* **Source capsule** — storm alerts name the dominant workflow, category, and affected others
* **Dual authority** — Core detects active storms per-error; Heartbeat owns storm lifecycle (start/resolve)
* **Retry suppression** — auto-retry blocked during active storms to prevent amplification

### Auto-Retry

* **Transient failures only** — retries `connectivity`, `rate_limit`, and `timeout` categories
* **8-gate canonical retryGate** — DB unavailable → storm → circuit opened → retry execution → workflow denied → no execution ID → budget exhausted → eligible/not retryable
* **Exponential backoff** — 15s base, 2^n scaling, 120s cap, random jitter
* **Fingerprint-based budget** — max 2 retries per fingerprint per hour
* **Supervisor Action line** — every alert tells the operator what the system will do next

### Heartbeat Monitor

* **5-minute schedule** with MD5 hash dedup — identical state = suppressed
* **HEALTHY / DEGRADED / CRITICAL verdict** with recovery banner showing duration and resolved reasons
* **Control Plane confidence** — `full / reduced / impaired` separates "system unhealthy" from "supervisor visibility impaired"
* **Top error sources** — per-workflow error breakdown rendered in the dashboard
* **DB-backed storm lifecycle** — start/resolve detected from `supervisor_events`, not dependent on new errors arriving
* **Orphan detection** with tiered escalation (🔴 6h+, 🟠 2h+, ⚠️ new) and re-alert markers
* **Activation monitoring** with state-change alerts, 6-hour reminders, and clickable workflow editor links
* **Classifier drift warning** — surfaces unknown-category error accumulation
* **Circuit flapping visibility** — warns when circuit transitions ≥4 times in 2 hours

### Dead Man's Switch

* **Healthchecks.io** with true start/completion lifecycle
* **Health-aware signaling** — sends `/fail` on CRITICAL, success otherwise
* **DMS Start + Complete evaluation** — both ping results checked, not just the final one

### Data Retention

* **90-day bounded deletion** (LIMIT 1000 per cycle)
* **Stale circuit safety valve** — resets open AND half-open circuits after 1 hour
* **`half_open_at` invariant repair** — cleans ghost timestamps on non-half-open circuits
* **Data span reporting** — oldest event age and retention window health at a glance
* **Humanized notify reasons** — "Dead tuple threshold exceeded" not "dead\_tuple\_warning"
* **Delivery/audit-aware weekly timer** — advances only after confirmed Telegram delivery AND successful DB log

### Resilience

* **Every Postgres/Telegram node**: `onError: continueErrorOutput` — failures never crash the workflow
* **DB-first logging** — alert events written before Telegram delivery via v1 execution order
* **Delivery failure cache** — Core and Heartbeat cache failed deliveries with source attribution; surfaces in next alert as grouped banner
* **Count-guarded deferred clearing** — cache only clears after confirmed successful delivery
* **Self-loop DB-quiet quarantine** — throttled self-loop errors produce zero DB writes
* **Single-JSON-parameter INSERT pattern** — immune to n8n's `queryReplacement` comma-split bug
* **Pre-built log payloads** — heartbeat and retention log payloads constructed in Code nodes, not sprawling expressions

***

## How It Works

```
Any n8n workflow fails
│
▼
Error Trigger (Supervisor Core)
│
▼
Enrich & Classify
(sanitize, categorize, fingerprint, self-loop detect, storm track)
│
├── Self-loop? → IF not throttled → Log + Telegram → stop
│
▼
Debounce Check (30s window)
├── Duplicate → Log & stop
└── New error ──▼
      Atomic Circuit Update (15-min rolling decay)
      │
      ├── Circuit suppressing → stop (empty return)
      └── Continue ──▼
            Format Alert Message
            (retryGate, supervisor action, storm context)
            │
      ┌─────┼──────┐
      ▼     ▼      ▼
     Log  Telegram  Auto-Retry?
    Event  Alert    (if eligible)
                      │
                      ▼
                    Wait (backoff)
                      │
                      ▼
                    HTTP Retry → Log Receipt
```

```
Every 5 minutes — Heartbeat Monitor
├── DMS Start (/start ping)
├── Circuit recovery probe (auto-heal)
├── System status + error trends + top sources
├── Orphan execution scan (with tiered escalation)
├── Activation monitoring (state-change + 6h reminder)
├── Evaluate health → verdict + control plane + storm lifecycle
├── Send update (only if state changed, recovered, storm event, or hourly pulse)
├── Log heartbeat event (pre-built payload)
├── Clear local cache
└── DMS Complete (health-aware /fail on CRITICAL)
```

```
Every 12 hours — Data Retention
├── Delete events > 90 days (LIMIT 1000)
├── Reset stale open circuits (safety valve)
├── Reset stale half_open circuits
├── Repair half_open_at invariants
├── Check table size + index bloat + dead tuples + autovacuum
├── Verify schema presence
├── ANALYZE tables
├── Report with data span (only if meaningful)
└── Log retention_completed (always, on all paths)
```

***

## Database

3 tables on PostgreSQL:

| Table               | Rows                       | Purpose                                                            |
| ------------------- | -------------------------- | ------------------------------------------------------------------ |
| `circuit_state`     | 1 (always)                 | Circuit breaker state — closed/open/half\_open with rolling decay  |
| `supervisor_events` | Growing (90-day retention) | Audit trail + trend detection + retry receipts + forensics         |
| `schema_versions`   | 1                          | Schema version tracking (checked by retention for drift detection) |

7 indexes including a partial unique index for orphan dedup and a composite partial index for fingerprint context performance. 3 CHECK constraints enforce valid states, severities, and event types.

***

## Quick Start

### 1. Create the database

Run `schema.sql` against your Postgres instance. See the DEPLOYMENT\_GUIDE.md for detailed instructions.

> **Note:** Index 7 uses `CREATE INDEX CONCURRENTLY` and must be run outside a transaction block. Run it separately if your SQL client auto-wraps in `BEGIN/COMMIT`.

### 2. Import workflows

Import in this order in n8n:

1. `workflow_1_supervisor_core.json`
2. `workflow_2_heartbeat_monitor.json`
3. `workflow_3_data_retention.json`

### 3. Set environment variables

| Variable                       | Required | Purpose                        |
| ------------------------------ | -------- | ------------------------------ |
| `NODE_FUNCTION_ALLOW_BUILTIN`  | Yes      | Set to `crypto`                |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | Yes      | Set to `false`                 |
| `N8N_BASE_URL`                 | Yes      | Your n8n base URL              |
| `HEALTHCHECKS_PING_URL`        | Yes      | Healthchecks.io ping URL       |
| `SUPERVISOR_WORKFLOW_ID`       | Yes      | Fill after import              |
| `HEARTBEAT_WORKFLOW_ID`        | Yes      | Fill after import              |
| `RETENTION_WORKFLOW_ID`        | Yes      | Fill after import              |
| `TELEGRAM_CHAT_ID`             | Yes      | Your Telegram chat ID          |
| `CRITICAL_WORKFLOW_IDS`        | Yes      | Comma-separated IDs to monitor |
| `LONG_RUNNING_WORKFLOW_IDS`    | Optional | Exclude from orphan detection  |
| `NEVER_RETRY_WORKFLOW_IDS`     | Optional | Never auto-retry these         |

### 4. Assign credentials and activate

* Assign **Postgres**, **Telegram Bot**, and **HTTP Header Auth** credentials to all relevant nodes
* Activate workflows in order: **Retention → Heartbeat → Core**
* Set Supervisor Core as the **Error Workflow** on all monitored workflows

### 5. Verify

You should receive a Telegram heartbeat within 5 minutes. See the DEPLOYMENT\_GUIDE.md for the complete 8-test smoke test suite.

***

## n8n Deployment Gotchas

* **n8n blocks `crypto` and `$env` by default** — set env vars before starting
* **Error Trigger only fires on production runs** — not manual test executions
* **Postgres nodes with 0 results stop execution chains** — use "Always Output Data"
* **Telegram/HTTP nodes replace `$json`** — downstream nodes receive API response, not original data. Use cross-node references (`$('NodeName').first().json`)
* **n8n import can corrupt IF/Switch output mappings** — delete and recreate if routing is wrong
* **Neon serverless Postgres can take 1-3s to wake** — use `connectionTimeout: 10`
* **`queryReplacement` splits on commas inside values** — use single-JSON-parameter pattern

***

## Quick Reference

```
┌─────────────────────────────────────────────────┐
│   SUPERVISOR ERROR HANDLING — QUICK REF         │
├─────────────────────────────────────────────────┤
│                                                 │
│  Workflows:    3                                │
│  Nodes:        48 executable + 3 sticky = 51    │
│  DB Tables:    3 (7 indexes)                    │
│  AI Cost:      $0/month                         │
│  Audit Rounds: 22                               │
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
│                                                 │
│  Debounce:     30 seconds                       │
│  Retention:    90 days                          │
│  DMS Grace:    30 minutes                       │
│  Orphan:       >30 min running                  │
│  Auto-Retry:   max 2/fingerprint/hour           │
│  Backoff:      15s base, 2^n, 120s cap          │
│  Storm:        ≥3 distinct fingerprints in 5m   │
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

## Audit History

This system was hardened across **22 review cycles** by 2 independent AI agents (Claude and GPT).

| Metric               | Count           |
| -------------------- | --------------- |
| Audit rounds         | 22              |
| DO NOT REPEAT items  | 136             |
| Bugs found and fixed | 30+             |
| AI agents involved   | 2 (Claude, GPT) |

### Key Discoveries

* **n8n's `queryReplacement` comma-split bug** on JSON payloads (silent data loss)
* **`$json` replacement by Telegram/HTTP nodes** (silent NULL metadata in downstream logs)
* **v1 execution order uses canvas Y-position**, not JSON array order for branch fan-out
* **`staticData` is workflow-local**, not cross-workflow
* **n8n API `status=running` filter may be unreliable** — defensive `stoppedAt`/`waitTill` guards needed
* **Circuit counter must be a burst detector with decay**, not an eternal accumulator

***

## Repository Structure

```
supervisor-error-handling/
├── README.md
├── DEPLOYMENT_GUIDE.md
├── LICENSE
├── schema.sql
├── workflow_1_supervisor_core.json
├── workflow_2_heartbeat_monitor.json
└── workflow_3_data_retention.json
```

***

## License

MIT — See LICENSE file.

***

## Author

**Chan (Chanryle Jay Cagara)**

Non-technical builder creating production automation systems with n8n.

* **GitHub:** <https://github.com/chanrylejay>
