# Scenarios – from symptom to cause

Step-by-step recipes for typical reported issues. Each one starts with a symptom (“users say that…”) and ends at a specific object in WEBCON Designer Studio (form, path, business rule, data source, action) or at a server resource.

Navigation basics (time range, exemplars, trace view): [Grafana in 10 minutes](01-grafana-in-10-minutes.md#drilling-down-from-chart-to-root-cause).

---

## 1. Form opens slowly

**Symptom:** “Opening a request takes several seconds”. Alert W2.

1. **WEBCON – Performance**, with a time range covering the reported moment (e.g. *Last 3 hours*; zoom in on the chart by selecting an area).
2. **Status** row: is *Portal HTTP p95* yellow / red? If so, the problem affects many users. If it is green, the problem is isolated (one form / user).
3. **Portal – user experience → Portal response time (p50 / p95 / p99)** row: is **p50** rising (everything is slow → step 7) or only **p95 / p99** (selected operations are slow → step 4)?
4. **Forms and path transitions → Form handling stages (dashboard time range)** row: which stage has the highest p95 – business rules and default values (`rules_and_defaults.apply`), JS model build, data sources?
5. **Where the time goes → Form loading by process and step** row: find the process and step with the highest p95 (process / step ID = Designer Studio). Click the ID → traces.
6. In the trace, look for the longest bar deepest in the tree:
   - `webcon.data_source.data.load` – data source (attribute `webcon.data_source.id`) → scenario 3 if there is a slow HTTP span underneath; slow SQL span → the data source query needs optimizing,
   - `webcon.rule.execute` – business rule (`webcon.rule.id`) – e.g. a rule executed for every row of an item list,
   - SQL span (`SELECT [...]`) – the `db.query.text` attribute shows the query.
7. Everything is slow: **.NET runtime** (CPU, thread pools, GC), dashboards **Windows – Host load** and **SQL Server** (links in the top right corner – the time range is kept).

**Example (illustrative):** the form of the “Verification” step opens in 4 s. Trace: `element.model.load` 3.9 s → `rules_and_defaults.apply` 3.6 s → 12 × `webcon.data_source.data.load` (`data_source.id = 58`, type `WebServiceREST`) at 0.3 s each. The REST data source is called separately for each of the 12 fields. Solution: a single data source call with cache, or fields filled in by a single business rule.

---

## 2. Path transition takes a long time

**Symptom:** “After clicking »Approve« it spins for a long time”. Alert W1.

1. **WEBCON – Performance → Status**: *Path transition p95*.
2. **Where the time goes → Paths – longest transitions**: the path ID with the highest p95 or total time. The name of the path, step, and process is shown on the **WEBCON – Operations → Paths – top 10** dashboard (from the database).
3. Click the path ID → transition traces → select the longest one.
4. In the trace: under `webcon.elements_management.path.transitions` there are actions (`webcon.action.execute`, attribute `webcon.action.name`), business rules, and saving (SQL). The longest item is the candidate:
   - REST / SOAP action – time spent in the external system (HTTP span under the action),
   - “Start workflow” action / subworkflows – transitions in subworkflows,
   - SQL – locks (scenario 5) or a heavy query.
5. **Operations → Top 10 paths – average transition time per day**: since when has it been slow? Compare with the application publication date.

**Tip:** an action that calls an external API during a transition extends the database transaction – other transitions wait for locks. Consider moving the call to an asynchronous action / the Service.

---

## 3. Data source or REST action returns errors

**Symptom:** “The choice list is empty”, “The action did not send data to system X”. Alerts W8, W9.

1. **WEBCON – Operations → External APIs called by WEBCON** (time range: day / week).
2. **Target servers – top 10 by call count**: which server has errors (error %) and how long it takes to respond (p95).
3. **Errors by server and type** – the kind of error:
   - `404` / `401` / `403` – configuration in WEBCON (address, authentication),
   - `500`–`599` – a problem on the external system side,
   - `connection_error` ~21 s – the server does not respond (firewall, wrong IP address),
   - `name_resolution_error` – wrong host name.
4. **Data sources with errors**: data source ID and name → Designer Studio. **Show logs** – the full error message.
5. **Actions with HTTP call errors**: action ID and name. **Show traces** – the trace contains the HTTP span with the address and response code.
6. **Errors per hour by server and type**: since when? A sudden start = a change on the external system side or an application publication.

**Example (dev test data):** data source 66 – p95 21 s, `connection_error` to `10.255.255.1` (an address that does not respond). Every opening of a form with this data source waits 21 s. Action 6 (`httpbin.org/status/500`) – 100 % `500` errors; WEBCON completes the transition despite the error, so the user does not see it.

---

## 4. Service is not processing

**Symptom:** “Timers are not executing”, “Search does not find new documents”, “User synchronization does not work”. Alerts W4, W6, W7, O3.

1. **WEBCON – Performance → Status**: *Service alive* (red = the Service is not sending a heartbeat), *Service queue errors*, *Solr – backlog growth*, *Process starts*.
2. *Service alive* is red: the `WebCon WorkFlow Service` service (services.msc) – stopped? Event log → Application / System. After the Service starts, the tile changes color within 5 min.
   - The service is running (*Running*), but the heartbeat does not come back: the Service work loop has stalled. Observed after a virtual machine was paused (clock jump in the System log, source Kernel-General, event 1): the Service still responded to `/health`, but stopped sending heartbeats and executing timers. Fix: restart the service.
3. **WEBCON WorkFlow Service** row:
   - *Service queues – errors by role* – which role (e.g. `SolrElementQueue`, `UserSynchronization`),
   - *Solr – indexing queues* – the “added” line permanently above “processed” = the backlog is growing,
   - *Timers and cyclical actions* – executions /min (a sharp increase = a looping timer),
   - *Heartbeat and health check* – errors = a problem with the database or communication.
4. **Logs**: variable *Service* = `WebCon.WorkFlow`, panel *Errors and warnings* – the error messages.

---

## 5. Database slows down

**Symptom:** everything is slow, especially saving and lists / reports. Alerts S1–S3.

1. **WEBCON – Performance → SQL from the WEBCON perspective**: *Slow SQL queries (above the Alloy filter threshold)* – which WEBCON queries exceed the threshold (1 s by default). Click the Trace ID → in which WEBCON operation (form, report, data source).
2. Dashboard **SQL Server – WEBCON** (link in the top right corner):
   - **Waits (what SQL Server is waiting for) → Wait time by category** – the dominant category:
     - `Locks` → the *Locks* row; the cause is usually long path transitions (scenario 2) or bulk operations,
     - `Data I/O` / `Log I/O` → the *Database I/O* row and disk latency in the host dashboard,
     - `CPU` → *CPU pressure (signal wait %)*, heavy reports / queries without indexes,
     - `Memory` → the *Memory* row, *Page life expectancy*.
3. **Batches and compilations /s**: compilations > 10 % = queries without parameters (e.g. SQL business rules that build the query text).
4. Pass the query from *Slow SQL queries* to the DBA together with the context (form / data source from the trace).

---

## 6. An alert fired – what now?

1. **Alerting → Alert rules** → click the firing rule: description, current value, **View panel** – the dashboard panel it refers to.
2. Determine the scope: since when (rule state history), whether it affects a single service / host (alert labels).
3. Go to the scenario for the rule – the “What to do” table in [Alerts](07-alerts.md).
4. Planned maintenance? Silence the alert (**Silences**) instead of ignoring it.
5. Many rules in the **Error** state at once = a problem with the stack itself (Prometheus / Loki) – [Troubleshooting](../installation/07-troubleshooting.md).

---

## 7. Weekly review (no reported issue)

Once a week, 15 minutes, dashboard **WEBCON – Operations** (7 days by default):

1. **Host**: CPU / memory / disk maximums – are we approaching the limits?
2. **Portal – visits**: usage trend (working days, new applications).
3. **Actions – top 10**, **Paths – top 10**: are there new items on the list? Is the average time of any object growing (daily chart)?
4. **Tasks – current status**: users with a large number of tasks / overdue tasks.
5. **External APIs called by WEBCON**: new errors, growing p95 of providers.
6. **Alerting → Alert rules**: alerts from the week (state history) – are the thresholds reasonable?
