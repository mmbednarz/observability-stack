# “WEBCON – Operations” dashboard

**Folder:** `webcon` · **Default time range:** last 7 days · **Refresh:** every 5 min

**Purpose:** a weekly overview for the person who maintains applications – how heavily the server is loaded, how many people use Portal, which **actions** and **paths** are the slowest (with **names** from the database), who has the most tasks, and whether **external systems** (APIs called by data sources and actions) are working.

Unlike “Performance” (current, technical diagnostics), this dashboard answers questions from a weekly review or a meeting with the process owner.

**Filters:**

| Variable | Meaning |
|---|---|
| *Service* | `Portal`, `WebCon.WorkFlow` (Service) |
| *Exclude ports* | ports excluded from the external API panels (default `4317|4318` – WEBCON's own telemetry) |
| *Exclude hosts* | excluded hosts (default `localhost` – Solr, Service modules) |
| *WEBCON hosts* | names of WEBCON servers – Portal → Service calls are not “external” |

Panels based on the content database (path names, tasks) require the **WEBCON SQL** data source – without it they show an error or only IDs ([installation](../installation/01-quick-start.md#step-3-run-the-installer), option c).

---

## Host

| Panel | What it shows | Thresholds |
|---|---|---|
| **CPU – average** / **CPU – maximum** | average and highest 5-minute CPU utilization during the week | 🟢 < 70 % · 🟡 70–90 % · 🔴 > 90 % |
| **Memory – maximum** | highest physical memory usage | 🟢 < 70 % · 🟡 70–90 % · 🔴 > 90 % |
| **Fullest disk** / **Free space (min)** | usage of the fullest volume (now) | 🟢 < 80 % · 🟡 80–90 % · 🔴 > 90 % |
| **Disk latency – max** | worst average I/O latency during the week | 🟢 < 20 ms · 🟡 20–50 ms · 🔴 > 50 ms – the disk slows down SQL and WEBCON |
| **CPU and memory** | trend during the week | peaks at fixed times = cyclical jobs, reports, backup |

**Maximum in red, average in green** = short peaks; check when they occurred (chart) and compare with *Top 10 actions – average time per day*.

Host details: [Windows – Host load](06-windows-host.md).

---

## Portal – visits

| Panel | What it shows | Notes |
|---|---|---|
| **Home page opens – today** | Portal home page opens since midnight | |
| **Sign-ins – today** | sign-ins since midnight | sign-in ≠ visit: a user with a remembered session does not sign in again |
| **Unique users (7 days)** | unique users over 7 days, but not earlier than since Portal start | a Portal restart (e.g. IIS application pool recycling, upgrade) resets the counter. WEBCON does not expose a daily unique user count |
| **Unique since Portal start** | since the last process start | |
| **Opens and sign-ins per day** | bars per day (UTC days) | usage trend – working days vs weekend, rollout of a new application |

---

## Actions – top 10

| Panel | What it shows |
|---|---|
| **Actions – top 10 by average time** | 10 actions (ID and name from Designer Studio) with the highest average time: **count, average, median, p95, min, max** |
| **Top 10 actions – average time per day** | average time of these actions on consecutive days |

**How to read the table:**

- **Min / max** are exact (from traces), **median and p95** are approximate (histogram) – they can fall outside the min–max range; this is not an error.
- **Average ≫ median** = most executions are fast, but very long ones occur (e.g. an external API timeout).
- **Min ≈ max, high** = the action is always slow – a candidate for optimization (e.g. the action's SQL query, the API call).
- Click the **action ID** → traces of executions – the trace shows what the action did (HTTP, SQL, subworkflow start).

**Daily chart:** an increase in the average time of a single action starting on a specific day = a change in the application (publishing) or in the external system.

---

## Paths – top 10

| Panel | What it shows |
|---|---|
| **Paths – top 10 by average transition time** | 10 paths with the highest average transition time, with the **path, step, workflow and process name** (from the content database) |
| **Top 10 paths – average transition time per day** | trend on consecutive days (path ID – names in the table) |

Transition time covers everything that happens after the path button is clicked: validation, rules, actions on the path and on entering the next step, saving to the database. You break down a slow path in the trace (click the ID) – usually a single action or a single query is to blame.

---

## Tasks – current status

Data straight from the content database – the **current status**, independent of the selected time range.

| Panel | What it shows |
|---|---|
| **Active tasks** | number of active tasks and overdue tasks |
| **Users with the most active tasks** | top 10 users: tasks, overdue, group (assigned to a group – the login is then the group login) |

Use cases: bottlenecks in processes (one person with hundreds of tasks), substitutions, cleanup after an employee leaves.

---

## External APIs called by WEBCON

Outgoing HTTP calls from Portal and Service: REST / SOAP data sources and actions, authentication, licenses. Internal calls (Solr, Service modules, Portal → Service) are excluded by filters.

| Panel | What it shows | How to read it |
|---|---|---|
| **Target servers – top 10 by call count** | server, number of calls, p95, % errors, from how many services | which external system is called most often and how fast it responds |
| **Errors by server and type** | number of errors by type | error types – see below |
| **Calls per hour by server (top 10)** | traffic over time | |
| **Errors per hour by server and type** | errors over time | since when the external system has been returning errors |
| **p95 response time by server (top 10)** | response time in hourly windows | slowdown on the API provider's side |
| **Data sources by total time** | data sources (ID, type): p95, count, total time | click the ID → trace with the HTTP call and the target server |
| **Data sources with errors** | errors fetching data from a data source (from logs): data source ID and name, service, count | a data source to fix in Designer Studio or an unavailable external system. **Show logs** button – the error message |
| **Actions with HTTP call errors** | actions in which an HTTP call returned an error | WEBCON can complete an action “successfully” despite an HTTP error – this is where you see it. Approximate count. **Show traces** button |

**Error types (`error.type`):**

| Value | Meaning | Typical cause |
|---|---|---|
| `400`–`499` | the external system rejected the request | wrong address / parameters (404), missing permissions (401, 403) – data source / action configuration |
| `500`–`599` | error on the external system's side | API provider outage / overload |
| `connection_error` | the connection could not be established | server down, firewall, wrong port; **duration ~21 s** = connection timeout (the server does not respond), short = connection refused |
| `name_resolution_error` | host name not found in DNS | typo in the address, missing DNS record |

Note: a data source that receives a 404 response does not always write an error to the log (WEBCON returns an empty result) – it will not appear in *Data sources with errors*, but the error is visible in the HTTP panels above.

**Example:** server `httpbin.org:443` – 120 calls during the week, 40 % errors of type `500`. *Actions with HTTP call errors* points to action ID 6. This is a test action calling an address that always returns 500 – in a real application: report it to the API owner or fix the address in the action.
