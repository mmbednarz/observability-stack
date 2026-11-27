# “WEBCON – Performance” dashboard

**Folder:** `webcon` · **Default range:** last 6 h · **Refresh:** every 1 min

**Purpose:** current diagnostics – is WEBCON running fast, and if not, **where** is it losing time: Portal, form, rule, data source, action, SQL, or Service.

**Filters:** *Service* (`Portal`, `WebCon.WorkFlow` = Service), *Database (DB ID)* (content database). **Links** (top right corner): *Windows – Host load*, *SQL Server*, *Traces (Explore)*, *Documentation*.

**Annotations** (toggles next to the filters) – vertical lines on all charts:

| Toggle | Color | Meaning |
|---|---|---|
| *WEBCON process start* (enabled by default) | orange | start of a Portal / Service process (restart, IIS pool recycling, start after inactivity). Response time spikes right after the line are a “cold start” – cache loading |
| *Cache marked for refresh* | purple | WEBCON marked the configuration cache for refresh (e.g. application publishing in Designer Studio) – subsequent requests reload the configuration |

Rows from general to detailed:

| Row | Question |
|---|---|
| [Status](#status) | Is there a problem? (at a glance) |
| [Portal – user experience](#portal--user-experience) | How fast does the Portal respond, and which pages are slow? |
| [Forms and path transitions](#forms-and-path-transitions) | How many transitions, how long do they take, which form stage is slow? |
| [Where the time goes](#where-the-time-goes-paths-rules-data-sources) | Which specific path / rule / data source / action? |
| [SQL from the WEBCON perspective](#sql-from-the-webcon-perspective) | Which SQL queries are slow? |
| [WEBCON WorkFlow Service](#webcon-workflow-service) | Is the Service keeping up with queues, timers, indexing? |
| [.NET runtime](#net-runtime) | Are WEBCON processes short on CPU / memory / threads? |
| [Logs](#logs) | What errors and warnings does WEBCON write? |

---

## Status

Tiles – the status at a glance. Start with the colors.

| Tile | What it shows | Thresholds | What to do when it is not green |
|---|---|---|---|
| **Portal requests /s** | how many HTTP requests the Portal handles (excluding health check) | – (informational) | a reference point: a slow Portal under heavy traffic ≠ a slow Portal without traffic |
| **Portal HTTP p95** | 95% of Portal requests are faster than this value | 🟢 < 1 s · 🟡 1–3 s · 🔴 > 3 s | *Portal* row → *Routes by total time* table |
| **5xx errors** | % of responses with a server error (selected services) | 🟢 < 1% · 🟡 1–5% · 🔴 > 5% | *HTTP errors by route*, *Logs* row |
| **Path transitions /min** | all path transitions (Portal + Service), including failed ones | – | |
| **Successful transitions** | successful / all transitions in the range | 🔴 < 95% · 🟡 95–99% · 🟢 ≥ 99% | a failed transition = a validation, rule, or action error; *Logs* row, transition traces |
| **Path transition p95** | 95% of transitions are faster than this value | 🟢 < 2 s · 🟡 2–5 s · 🔴 > 5 s | *Paths – longest transitions* table |
| **Users (since start)** | unique Portal users since the last start of the Portal process | – | with nightly IIS application pool recycling = users of the current day; a Portal restart (recycling, WEBCON upgrade) resets the counter |
| **Service queue /min** | items taken from Service queues | – | |
| **Service queue errors** | queue items whose processing failed (range) | 🟢 0 · 🔴 ≥ 1 | *WEBCON WorkFlow Service* row, *Logs* (service `WebCon.WorkFlow`) |
| **Solr – backlog growth** | added to indexing minus processed (range) | 🟢 ≤ 0 · 🟡 1–99 · 🔴 ≥ 100 | > 0 = indexing is falling behind; *Solr – indexing queues* |
| **Service alive** | whether the Service sent a “heartbeat” in the last 5 min | 🟢 YES · 🔴 NO | the Service is stopped or hung – check the `WebCon WorkFlow Service` service |
| **Process starts** | how many times WEBCON processes started in the range | 🟡 ≥ 1 | restart = cache loss, slower first requests; unplanned restarts – logs, event log |

---

## Portal – user experience

| Panel | What it shows | How to read it |
|---|---|---|
| **Requests /s by route group** | Portal traffic in groups: home page / navigation, form, reports / dashboards, tasks, other API | which part of the Portal is used most often; a spike in one group = e.g. a report opened en masse |
| **Portal response time (p50 / p95 / p99)** | typical (p50), slow (p95), and extreme (p99) response time | p50 rises = everything is slow (server, SQL); only p95/p99 rise = selected pages are slow. **Points = exemplars** – click a point high on the chart to open the trace of a slow request |
| **Portal response time distribution** | heatmap: how many requests took how long at a given moment | bright cells high up = many slow requests; a single “streak” at the top = a recurring slow operation |
| **HTTP errors by route** | number of 4xx and 5xx responses per route | **5xx** = WEBCON error; **401** after a session expires is normal; **404** = missing resource / wrong link |
| **Routes by total time (dashboard time range)** | table of routes: count, p95, total time (count × average time), % of 5xx errors | **total time** shows what loads the Portal the most – a route called 10,000 times at 0.2 s weighs more than one called 10 times at 5 s. Clicking a route opens the *ASP.NET Core Endpoint* dashboard |
| **Active requests and connection queue** | requests being handled and connections waiting in the server queue | a growing queue = the Portal is not keeping up (not enough threads / CPU) – see *.NET runtime* |
| **Portal and form opens** | home page and instance form opens /s | |
| **Portal users** | unique users since the last start of the Portal process | the counter drops to zero at a Portal restart; with nightly IIS application pool recycling the peak before the drop = users of that day |

**Routes (`http.route`)** are Portal address templates with parameters in curly braces (e.g. `{controller=Home}/{action=Index}/{id?}`), not specific addresses – all form opens of different instances go to one route. The specific instance ID and user are in the request trace.

---

## Forms and path transitions

| Panel | What it shows | How to read it |
|---|---|---|
| **Path transitions** | all, successful, and failed transitions /min | failed > 0 – check the logs and the traces of failed transitions |
| **Successful transitions by kind** | breakdown: new instance (`element_new`), save only (`only_save`), call source (Portal, Service, API) | whether the load comes from creating new instances, saves, or transitions from the Service (e.g. timers, “Start workflow”) |
| **Path transition time (p50 / p95 / p99)** | transition time (WEBCON histogram) | points = exemplars – the trace of a specific transition |
| **Path transition time distribution** | heatmap of transition times | |
| **Transitions in progress, history, model cache** | transitions in progress at a given moment, history writes /s, instance models in cache | a growing number of transitions in progress = transitions are blocking (e.g. SQL locks) |
| **Form handling stages – p95** | p95 of successive stages: model retrieval / loading, rules and default values, JS model build, save, transition, actions, data sources | which form **stage** is slow |
| **Form handling stages (dashboard time range)** | table of stages: count, p95, total time | the stage with the largest total time is the best candidate for optimization. Nested stages are counted multiple times (a rule in model loading increases both) |

---

## Where the time goes (paths, rules, data sources)

The most important row for application optimization. The tables are calculated from **traces** (TraceQL metrics) or spanmetrics, for the entire dashboard time range (up to 7 days). Columns: **Calls**, **Total time** and the duration – in tables calculated from traces **Average** (Total time / Calls) and **Max**, both exact; in spanmetrics tables **p95** (approximate). Clicking an ID in a table calculated from traces opens the spans of this object in Explore: **Show spans slower than average** or **Show all spans** (the list is not sorted by duration – click the *Duration* column header).

| Panel | What it shows | Identifier | Drill-down |
|---|---|---|---|
| **WEBCON spans by total time** | all WEBCON operations (`webcon.*`) sorted by total time | span name | the overall picture – what WEBCON spends the most time on in total |
| **Portal MVC pipeline (filters)** | authorization and Portal request filters | span name | long `on_authorization` = permission / application checks |
| **Paths – longest transitions** | transitions by path ID | `webcon.path.id` (path ID in Designer Studio) | click the ID → spans of this path's transitions → trace → what takes time (actions, rules, SQL) |
| **Business rules** | rule executions by ID | `webcon.rule.id` | click the ID → spans; the rule name is not sent in WEBCON 2026.2.5 – find the ID in Designer Studio |
| **Data sources** | data loads from data sources by ID and type (SQL, REST, …) | `webcon.data_source.id`, type | a slow REST data source = a slow external API; a slow SQL data source = a query to optimize |
| **Actions** | action executions by ID and name | `webcon.action.id`, name | |
| **Form loading by process and step** | form open time per process and step | `webcon.process.id`, `webcon.step.id` | which form (step) opens slowly |
| **Form JS model build – steps** | stages of the server-side form model build | step name | details for advanced users |
| **Slowest requests (traces > 2 s)** | recent Portal / Service requests longer than 2 s: route, status, user login | Trace ID | click the Trace ID → the whole trace |

**How to read the rankings:**

- **High average, low count** – a rare but slow operation (e.g. a monthly report). Affects few users.
- **Medium average, huge count** – “death by a thousand cuts”: the most total time, the biggest gain from optimization.
- **Max much higher than average** – single slow executions (e.g. a lock, a slow external system at one moment), not a constantly slow object. Open the spans slower than average.
- **Total time** = count × average time – the best column for setting priorities.
- Tables calculated from traces show no p95: Tempo calculates percentiles from buckets that are powers of 2 (… 2.1 s, 4.3 s, 8.6 s), so p95 could be almost twice the real value (e.g. 8.59 s when the slowest execution took 6.3 s).

**Example:** the *Data sources* table shows data source ID 66 (REST type), average = 21 s, count 40. Clicking the ID → span → trace → under the `webcon.data_source.data.load` span there is an HTTP span to `10.255.255.1` lasting 21 s with the error status `connection_error` – the target server does not respond, and WEBCON waits until the connection timeout. Solution on the application side: a correct address / timeout in the data source configuration.

---

## SQL from the WEBCON perspective

SQL queries executed by WEBCON – from its point of view (how long it waited for the database).

| Panel | What it shows | How to read it |
|---|---|---|
| **Slow SQL queries (above the Alloy filter threshold)** | recent SQL queries longer than the threshold (1 s by default): table, database, **full query text** | click the Trace ID → in which WEBCON operation (form, report, data source) the query was run |
| **Slow queries by operation** | slow queries grouped by name, e.g. `SELECT [WFElements]` | which table / operation is most often slow |
| **SQL Server – load** | queries (batch requests), transactions, compilations /s | details: [SQL Server](05-sql-server.md) |
| **SQL Server – waits (top 5 categories)** | what SQL Server waits for the longest | |
| **SQL Server – locks and memory** | blocked sessions, longest lock wait, deadlocks, Page Life Expectancy | locks during slow transitions = transitions are waiting for each other |

Queries shorter than the threshold **are not recorded** – no slow queries in the table is good news, not an error.

---

## WEBCON WorkFlow Service

| Panel | What it shows | How to read it |
|---|---|---|
| **Service queues – dequeued items by role** | items processed by Service roles (e.g. `SolrElementQueue`, `UserSynchronization`) /s | which role is working; unknown roles = “role <id>” |
| **Service queues – errors by role** | failed processing of queue items | any value > 0 requires checking the Service logs |
| **Service work time by role – p95** | how long a unit of work of a role takes | rising time = the role is not keeping up |
| **Timers and cyclical actions** | timers and cyclical actions in progress, and executions /min | a large number of executions = a looping timer or a bulk operation |
| **Solr – indexing queues** | added (solid line) vs processed (dashed) elements, attachments, activities /min | solid line permanently above the dashed one = the backlog is growing |
| **Solr – durations (p95)** | Solr queries, indexing, text extraction from attachments | slow extraction = large / unusual attachments |
| **Database cache – refreshes** | configuration cache refreshes | a spike after application publishing is normal; frequent refreshes = response time spikes |
| **Database cache – duration (p95)** | cache refresh duration | |
| **Heartbeat and health check** | Portal / Service heartbeat and health check duration; errors on the right axis | heartbeat errors = a problem with the database or with Portal ↔ Service communication |

---

## .NET runtime

The state of WEBCON processes (Portal, Service) from the .NET side. Useful when everything is slow at once.

| Panel | What it shows | When to react |
|---|---|---|
| **WEBCON process CPU** | CPU usage in cores (1 = one full core) | close to the number of server cores = not enough CPU |
| **Memory: working set and GC heap** | process memory and .NET object memory | steady growth without drops = possible leak / growing cache |
| **GC pauses** | % of time the application was paused by garbage collection | > 5% = memory pressure |
| **GC collections by generation** | garbage collection frequency | frequent gen2 = many long-lived objects (cache, large models) |
| **Thread pool** | threads and work items waiting in the pool queue | a growing queue with a constant thread count = thread pool starvation (everything slows down) |
| **Exceptions and lock contention** | .NET exceptions /s and lock contentions /s | a spike in exceptions = check the logs |

---

## Logs

| Panel | What it shows | How to read it |
|---|---|---|
| **Logs by level** | number of log records by service and level | an `error` spike = an event to investigate |
| **Errors and warnings** | Warning / Error / Fatal records | expand a record – fields `exception_message`, `RequestPath`, `AuthenticatedUserLogin`; the **Open trace** button next to `trace_id` |

Searching the logs: panel menu **⋮ → Explore** and add a filter, e.g. `|= "DataSource"` (contains text).
