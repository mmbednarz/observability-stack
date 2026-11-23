# “WEBCON – Availability and backlog” dashboard

Folder `webcon`, dashboard **WEBCON – Availability and backlog** (the *Portal available* and *Database backlog* tiles on the **Start** screen). It answers two questions:

1. **Is the Portal responding?** – an HTTP probe every 30 s.
2. **Is a backlog building up in the database** that the Service is not picking up? – a read from the content database every 60 s.

WEBCON telemetry (the *WEBCON – Performance* dashboard) shows what the Portal and the Service **execute**. This dashboard shows what is **waiting** – e.g. overdue timeouts when the Service has stalled.

## Availability

| Panel | How to read it |
|---|---|
| **Status** | *Available* / *Unavailable* for each checked address (the *Address* variable at the top) |
| **Certificate – days to expiry** | red < 14 days (alert B2), orange < 30 days |
| **HTTP code** | 200 = OK; 0 = no response (DNS, connection, certificate); 302 = redirect (e.g. to sign-in); 401 = WEBCON does not respond anonymously; 5xx = application error |
| **Response time**, **HTTP request phases** | probe time and its components: `resolve` (DNS), `connect`, `tls`, `processing` (application time), `transfer` |
| **Availability over time** | availability interruptions on the timeline |

What is checked:

- **WEBCON Portal** – the main Portal address (given during installation or taken from an IIS binding with a host name), path `/health`; shown in the panels as that address. The *Available* result requires a 200 response and the `Healthy` status – in doing so, WEBCON checks, among other things, access to the configuration database. The probe runs on the Portal server: it connects locally (port from the Portal address), verifies the certificate for the host name from the Portal address, and sends the `Host: localhost` header, because WEBCON 2026.2 responds anonymously on `/health` only locally. The probe does not check the path through DNS, a load balancer or a firewall – use additional addresses for that.
- **Additional addresses** (installer parameter `-ProbeUrl`) – e.g. the production Portal, a load balancer; a 2xx code is required.

## Database backlog

| Panel | How to read it |
|---|---|
| **Overdue timeouts** | timeouts of instances past their due time that the Service has not picked up yet. Briefly > 0 – normal (the Service picks them up periodically); **persists for 30 min** – alert D1 |
| **Cyclical actions with errors** | active cyclical actions whose last execution ended with an error (alert D3) |
| **New failed emails (30 min)** | how many emails with at least 3 failed attempts appeared in the last 30 min – > 0 = a sending problem, e.g. SMTP (alert D2) |
| **Emails by attempt count** | the email queue by number of sending attempts. Emails that have exhausted their attempts (usually 5) **stay in the queue** – a large constant number at 5 attempts means old, permanently failed emails, not a current problem |
| **Queued emails** | all emails waiting to be sent or retried |
| **Queue tables** | row counts of WEBCON queue tables (name contains `QUEUE`; excluding additional `ZWEBCON_*` tables outside the WEBCON schema) – a rising trend without drops = the queue is not being processed |

## Database

| Panel | How to read it |
|---|---|
| **Instances – daily change** | growth in the number of instances (`WFElements` rows) during the day – net, i.e. created minus deleted |
| **Instances – total** | number of instances in the content database |
| **Log tables** | the largest log tables (name contains `LOGS`, excluding the `DicLogSources` dictionary; the administrative logs `AdminWFEventLogs` and `AdminServiceLogs` are in the configuration database, which the stack does not monitor) – candidates for archiving or cleanup |

Table row counts come from SQL Server metadata (without scanning the tables), so they may differ slightly from `COUNT(*)`.

## When panels are empty

- **Availability** – the Portal was not detected in IIS (the site is stopped, or the stack runs on a separate machine without an agent on the WEBCON host), or the site bindings have no host name and the installer did not get the Portal address (`-PortalUrl`). Smoke test: section “WEBCON and host data (informational)”, row *Availability probes*.
- **Backlog / Database** – database metrics are not enabled (`-WebconDbMetrics $true`) or the exporter login lacks permissions (`sql\grant-webcon-db-metrics.sql`). Smoke test: row *WEBCON database metrics*. Details: [Requirements – database metrics](../installation/02-requirements-and-preparation.md#3-metrics-from-the-content-database-optional).
