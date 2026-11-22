# Concepts

## Glossary

| Concept | Meaning | Example |
|---|---|---|
| **Metric** | a number measured over time, collected every minute | number of path transitions, Portal response time |
| **Counter** | a metric that only increases (since the process start); charts show its increase | `webcon_elements_management_path_transitions_all_total` |
| **… /s, … /min** | rate – how many events per second / minute, averaged over a window of several minutes | 12 transitions /min |
| **Increase in the range** | how many events occurred in the entire selected time range (“dashboard time range” tiles) | 3 Service queue errors in the last 6 h |
| **Histogram** | distribution of durations: how many operations took 0–100 ms, 100–250 ms, … – percentiles are calculated from it | path transition time |
| **p50 (median)** | half of the operations were faster than this value – the “typical” time | p50 = 0.3 s |
| **p95** | 95% of operations were faster, 5% slower – the time experienced by one user in twenty. **The primary performance measure** in these dashboards | p95 = 2 s → 1 in 20 opens takes more than 2 s |
| **p99** | the slowest 1% of operations – individual extreme cases | |
| **Trace** | a record of the course of a single operation (a Portal request, a path transition, a Service task) with the duration of each step | opening the form of instance 1234 |
| **Span** | one step in a trace: name, duration, attributes, status; spans are nested | `webcon.rule.execute` (rule 18) in `element.model.load` |
| **Attribute** | additional information in a span | `webcon.path.id = 11`, `db.query.text = SELECT …` |
| **Exemplar** | a point on a metric chart linked to a specific trace – a bridge from the chart to the details | a diamond on the response time chart |
| **Spanmetrics** | metrics (count, duration) calculated automatically from spans – this is why there are charts for rules, actions, and form stages even though WEBCON does not send such metrics | `traces_spanmetrics_latency_bucket{span_name="webcon.action.execute"}` |
| **TraceQL metrics** | statistics calculated directly from traces in Tempo (“Where the time goes” tables) – they work for a range of up to 7 days, p95 is approximate | path ranking |
| **Log** | a message written by WEBCON (Serilog), with a level and often with a `trace_id` | `Error getting data for DataSource …` |
| **Log level** | `Information`, `Warning`, `Error`, `Fatal` | |
| **Service** (`job`, `service`) | telemetry source: `Portal` (web application under IIS) or `WebCon.WorkFlow` (WEBCON WorkFlow Service) | |
| **SQL filter threshold** | SQL query spans shorter than the threshold (1 s by default) are dropped so as not to flood the storage – traces show only **slow** queries | |
| **Retention** | how long data is kept: metrics 15 days, traces 8 days, logs 7 days (default) | |

## How WEBCON maps to telemetry

| What you do / what happens in WEBCON | Metric (chart) | Span (trace) | Attributes / identifiers |
|---|---|---|---|
| a user opens a Portal page | `http_server_request_duration_seconds` (HTTP request duration) | `server` span with `http.route` | `http.route`, `http.response.status_code`, `webcon.user.login` |
| opening an instance form | `webcon_…_element_open_total` | `webcon.elements_management.element.model.load` | `webcon.process.id`, `webcon.step.id` |
| path transition (button on the form, Service) | `webcon_elements_management_path_transitions_*` (count, successful, duration) | `webcon.elements_management.path.transitions` | `webcon.path.id` = path ID (WFP_ID) |
| business rule / form rule | – (spanmetrics) | `webcon.rule.execute` | `webcon.rule.id` (name empty in 2026.2.5) |
| data source (SQL, REST, SOAP, …) | – (spanmetrics) | `webcon.data_source.data.load` + HTTP / SQL span underneath | `webcon.data_source.id`, `webcon.data_source.type.name` |
| action (REST, “Start workflow”, …) | – (spanmetrics) | `webcon.action.execute` | `webcon.action.id`, `webcon.action.name` |
| external API call (REST action / data source) | `http_client_request_duration_seconds` | HTTP `client` span | `server.address`, `error.type` |
| WEBCON SQL query (longer than the threshold) | – | SqlClient span, e.g. `SELECT [WFElements]` | `db.namespace`, `db.query.text` |
| Service work (queues, timers, Solr) | `webcon_service_queue_*`, `webcon_timers_*`, `webcon_solr_queue_*` | `webcon.service.activity`, `webcon.service.heartbeat` | `webcon.service.role.name` |
| error in WEBCON | – | span with error status (not always) | `Error` log with `trace_id` |

> **Important:** data source and action spans **do not have an error status**, even when the call failed – the error is visible in the HTTP span underneath (`error.type`) and in the logs. This is why data source errors are shown from logs, and action errors from HTTP calls.

The identifiers (`path.id`, `rule.id`, `data_source.id`, `action.id`, `process.id`, `step.id`) are the same IDs that you see in **WEBCON Designer Studio** (e.g. in the object properties). The “WEBCON – Operations” dashboard retrieves path and process names from the content database.

## Where data delay comes from

- WEBCON sends metrics **every 60 s**, and charts average over several minutes – a change in load becomes visible after 2–5 minutes.
- Traces and logs are available after a few seconds.
- The Portal under IIS is shut down by IIS after a period of inactivity – it then sends no metrics (gaps in the charts are not a failure).

## Limitations worth knowing

- **p95 is approximate** – calculated from a histogram (duration buckets). For tables based on traces (TraceQL metrics), the buckets are powers of 2, so p95 = 1.07 s or 2.15 s, not 1.52 s. It is enough for comparing what is slower; for exact measurements – see min / max and individual traces.
- **Little traffic = unreliable percentiles.** p95 of 10 operations is practically the slowest of them. Always look at the “Calls” column.
- **Nested spans are counted multiple times** in the “Total time” tables – a rule executed during form loading increases the total time of both the rule and the loading.
- **Tables based on traces cover up to 7 days** (Tempo query limit and trace retention); a longer range = an error or truncated results. Over long ranges they are calculated more slowly.
