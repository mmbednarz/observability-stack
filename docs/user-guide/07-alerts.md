# Alerts

Grafana checks 30 rules every minute and marks a problem as an **alert**. Alerts are visible **only in Grafana** – they do not send emails or Teams messages (this can be added later).

## Where to see them

| Location | What is there |
|---|---|
| Menu → **Alerting → Alert rules** | all rules in two folders: *WEBCON – alerts* and *Observability stack – alerts*; the state of each rule |
| Menu → **Alerting → Active notifications** | currently firing alerts |
| Menu → **Alerting → Silences** | silences (e.g. for the duration of planned maintenance) |

## Rule states

| State | Meaning |
|---|---|
| **Normal** | condition not met – everything is fine |
| **Normal (NoData)** | no data – e.g. a machine without SQL Server; this is **not** a problem (the rules intentionally do not alert when there is no data) |
| **Pending** | condition met, but not for long enough yet (e.g. the rule requires 10 min) |
| **Firing** (Alerting) | firing alert |
| **Error** | the rule could not be evaluated – usually Prometheus or Loki is not running (`DatasourceError`); affects many rules at once |

Click a rule to see its description, current value, state history, and the **View panel** link to the dashboard panel it refers to.

Severity (the `severity` label): **critical** – respond immediately; **warning** – check within the day.

## WEBCON rules

| ID | Alert | When | Severity | What to do |
|---|---|---|---|---|
| W1 | Slow path transitions (p95) | transition p95 > 5 s for 10 min (min. 10 transitions) | warning | [Scenario: slow transition](08-scenarios.md#2-path-transition-takes-a-long-time) |
| W2 | Slow Portal (p95) | Portal p95 > 3 s for 10 min (min. 50 requests) | warning | [Scenario: slow form](08-scenarios.md#1-form-opens-slowly) |
| W3 | Portal 5xx errors | > 5 % of responses with a server error (min. 10 errors) for 5 min | **critical** | *Performance → HTTP errors by route*, *Logs* |
| W4 | No Service heartbeat | the Service was running within the last 24 h, but has shown no sign of life for 10 min | **critical** | the `WebCon WorkFlow Service` service – status, event log; [scenario](08-scenarios.md#4-service-is-not-processing). Service in the *Running* state while the alert persists (e.g. after a virtual machine was paused) = the Service work loop has stalled – restart the service |
| W5 | Heartbeat / health check errors | heartbeat or health check ended with an error | warning | Service and Portal logs; database connectivity |
| W6 | Service queue errors | a Service queue item was not processed | warning | *Performance → WEBCON WorkFlow Service*, `WebCon.WorkFlow` logs |
| W7 | Growing Solr indexing backlog | > 1000 backlog items within 30 min and growing | warning | *Solr – indexing queues*; the Solr service |
| W8 | Data source errors | ≥ 5 data retrieval errors from a single data source in 15 min | warning | *Operations → Data sources with errors*; [scenario](08-scenarios.md#3-data-source-or-rest-action-returns-errors) |
| W9 | External API call errors | ≥ 10 HTTP errors to a single server in 15 min (without the WEBCON host, Solr and OTLP) | warning | *Operations → External APIs called by WEBCON* |
| W10 | Spike in log errors | ≥ 50 errors in a service's logs in 10 min | warning | *Performance → Logs* |

## Availability and database backlog rules

Dashboard: [WEBCON – Availability and backlog](09-availability-and-backlog.md). Rules D1–D3 work when content database metrics are enabled (`-WebconDbMetrics`).

| ID | Alert | When | Severity | What to do |
|---|---|---|---|---|
| B1 | Portal unavailable | the Portal `/health` probe (or an additional address) without a 200 response / Healthy status for 3 min | **critical** | *HTTP code* panel: 0 = no connection (IIS, DNS, certificate), 5xx / `Unhealthy` = WEBCON (e.g. no access to the configuration database), 401 = see [Troubleshooting](../installation/07-troubleshooting.md) |
| B2 | Certificate expiring soon | the address certificate expires in less than 14 days | warning | renew the IIS binding certificate |
| D1 | Overdue timeouts | overdue timeouts have not dropped to zero for 30 min | warning | the Service is not picking them up – check alert W4 and the [scenario](08-scenarios.md#4-service-is-not-processing) |
| D2 | Failed emails increasing | in the last 30 min, new emails appeared with ≥ 3 failed attempts (emails that have exhausted their attempts stay in the queue, so the increase is what counts) | warning | SMTP configuration, Service logs |
| D3 | Cyclical actions with errors | cyclical actions whose last execution ended with an error for 30 min | warning | Designer Studio (cyclical actions), Service logs |

## SQL Server and host rules

| ID | Alert | When | Severity | What to do |
|---|---|---|---|---|
| S1 | SQL deadlocks | a deadlock occurred (15 min) | warning | [SQL Server → Locks](05-sql-server.md#locks) |
| S2 | Long SQL blocking | sessions blocked for 10 min | warning | as above; [scenario](08-scenarios.md#5-database-slows-down) |
| S3 | SQL memory pressure (Page Life Expectancy) | Page Life Expectancy < 300 s for 30 min | warning | [SQL Server → Memory](05-sql-server.md#memory) |
| H1 | High host CPU utilization | > 90 % for 15 min | warning | [Host → Processes](06-windows-host.md#processes-webcon-iis-sql-server-stack) – which process |
| H2 | Low host free memory | > 90 % for 15 min | warning | [Host → Memory](06-windows-host.md#memory) |
| H3 / H4 | Low disk space / Critically low disk space | < 10 % (H3, warning) / < 5 % (H4, critical) | warning / **critical** | free up space; logs, backups, temporary files |

## Observability stack rules

These concern the tool itself – whether data is being collected at all.

| ID | Alert | When | Severity | What to do |
|---|---|---|---|---|
| O1 | Stack component not responding | an `obs-*` service stopped responding | **critical** | [Troubleshooting](../installation/07-troubleshooting.md) |
| O2 | Host stopped sending metrics | host metrics were present within the last 24 h, but have been missing for 10 min | **critical** | Alloy / agent on the host; after a paused VM is resumed, the alert is expected and clears by itself |
| O3 | No telemetry from WEBCON WorkFlow Service | the Service was sending data (last 24 h), but has sent nothing for 15 min | **critical** | Service stopped? configuration overwritten by a WEBCON upgrade? (the Portal is not checked – under IIS without traffic it stops sending, which is normal) |
| O4 | Tempo - query errors | trace queries end with an error | warning | [corrupted Tempo index](../installation/07-troubleshooting.md#corrupted-tempo-index) |
| O5 / O5b | Tempo - spanmetrics near series limit / Tempo - spanmetrics dropping series | O5: > 80 % of the `max_active_series` limit for 15 min; O5b: series dropped because the limit was exceeded | O5 warning / O5b **critical** | a very large number of paths / actions – report to the stack administrator |
| O6 | Alloy - telemetry dropped or not sent | Alloy does not accept or write data for 5 min | warning | Alloy logs (event log), disk space |
| O7 | Low disk space for stack data | < 15 % on the `C:\Observability\data` volume | **critical** | shorten the retention or free up space |

## Silencing

For planned maintenance (WEBCON upgrade, server restart):

1. **Alerting → Silences → New silence**.
2. Duration (e.g. 2 h) and a matcher, e.g. `severity = critical` or `alertname = W4 No Service heartbeat`.
3. Comment (reason) → **Save silence**.

## Changing thresholds

The rules are in the repository (`config-templates/grafana/provisioning/alerting/`) and are read-only in Grafana. Changing a threshold = changing the file in the repository and reinstalling ([Upgrade](../installation/05-upgrade.md)).
