# Troubleshooting

Always start with the smoke test (PowerShell as administrator, repository directory):

```powershell
.\Test-ObservabilityStack.ps1
```

## Smoke test results

| Section / message | What it means | What to do |
|---|---|---|
| **Services**: `obs-… - status Stopped` | the service is not running | `Start-Service obs-…`; when it does not start – the service log (below) |
| **Readiness**: component not responding | the service is running, but the component is not ready | wait 1–2 min after startup; then the service log |
| `Loki: pattern ingester not ready yet` (WARN) | an internal Loki module takes up to ~2 h to start | nothing – logs are accepted |
| **End-to-end OTLP flow**: test trace / log / metric not found | Alloy does not pass data to the storage | Alloy UI <http://localhost:12345> (components in red), Application event log, source `Alloy` |
| `Tempo: TraceQL metrics` error `parquet` | corrupted Tempo block index | procedure below |
| **WEBCON and host data**: no `OTLP source: Portal` | the Portal has not sent anything yet | open the Portal in a browser, wait 2 min |
| no `OTLP source: WebCon.WorkFlow` / `webcon_* metrics` | WEBCON does not send telemetry | [Set-WebconTelemetry.ps1](03-webcon-configuration.md); after a WEBCON upgrade, run it again |
| `WEBCON service with a non-standard name …` / `… telemetry without the webcon.component marker` (WARN) | WEBCON sends telemetry without the component marker – the service name comes from `ServiceName` in appsettings | `Set-WebconTelemetry.ps1` ([marker](03-webcon-configuration.md#what-the-script-changes)); as a fallback, the installer's `-WebconPortalServiceName` / `-WebconServiceServiceName` |
| `Availability (portal): … unavailable (HTTP 401)` | WEBCON stopped responding anonymously to `/health` for the `Host: localhost` header (behavior observed on 2026.2.5) | check from the Portal server: `Invoke-WebRequest https://<host>/health -Headers @{Host='localhost'}`; report it – the probe needs to be changed |
| `Availability (portal): … (HTTP 0)` | no connection: IIS stopped, no binding on the port from the Portal address, certificate not matching the host name from `-PortalUrl` or expired | *HTTP request phases* panel; probe log: Alloy UI → `prometheus.exporter.blackbox.webcon`; correct `-PortalUrl` (the address users open the Portal with) |
| `Availability (custom): … (HTTP 0)` | no connection to the `-ProbeUrl` address: DNS, firewall, certificate | *HTTP request phases* panel |
| no Portal probe, installer: `The IIS bindings of the Portal site have no host name` (WARN) | the Portal site has `*` bindings – Portal address unknown | stack installer with `-PortalUrl https://<Portal address>` (in remote mode, then the WEBCON host script again with `-SkipWebconConfig`) |
| `Availability … (HTTP 302)` | redirect, e.g. to the sign-in page – the address does not point to the Portal `/health` | `-ProbeUrl` with the correct address |
| `WEBCON database metrics: 0 of 4 metrics` (WARN) | the exporter login has no access to the content database / columns | DBA: `sql\grant-webcon-db-metrics.sql`; query errors: Application event log, source `Alloy`, `component_id=prometheus.exporter.mssql.webcon_data` |
| `mssql exporter: down` | no connection to SQL | `.\scripts\Test-SqlExporterLogin.ps1`; is TCP enabled? ([SQL Express](02-requirements-and-preparation.md#sql-server-express--enabling-tcp)) |
| `Grafana: data source 'WEBCON SQL'` error | the Grafana login has no permissions / wrong password | DBA: `sql\grant-webcon-reader-permissions.sql` (especially after a WEBCON upgrade) |
| **Alerts**: rule evaluation error | the rule query does not work | Grafana log; report it (the rules are in the repository) |
| `Alerts: N rules with an error from before the Grafana restart` (information) | after a restart, Grafana restores the last state of the rules, including an error from the time when the data source was unavailable (e.g. a manual Prometheus restart) | nothing – repeat the test in 1 min; the error disappears after the next evaluation |
| **Alerts**: `Alert firing: …` (WARN) | the rule detected a problem | [Alerts](../user-guide/07-alerts.md) – what a given alert means |
| `Alerts not checked - no access to the Grafana admin password` | the test was run without administrator rights | run PowerShell as administrator |

## Installation problems

| Symptom | Solution |
|---|---|
| `Ports in use: …` | the installer shows the process using the port – stop it (e.g. a local Jaeger, Seq, another OTLP collector) |
| the script does not run / “is not digitally signed” | `Unblock-File` on the downloaded ZIP before extracting; `Set-ExecutionPolicy -Scope Process Bypass -Force` |
| garbled special characters in messages | the script file was changed with an editor that does not keep the BOM – download the files again |
| download error / SHA256 mismatch | no internet access or a proxy; retry with `-ForceDownload` |
| `SQL login verification failed` | the installer lists the missing permissions – pass them on to the DBA |
| Grafana does not start after an upgrade | `C:\Observability\logs\grafana\grafana.log` – `Failed to provision alerting` = an error in the alert rules from the repository |

## WEBCON problems

| Symptom | Solution |
|---|---|
| WEBCON does not start after `Set-WebconTelemetry.ps1` | restore the `*.bak-*` backup copies ([reverting](03-webcon-configuration.md#reverting-the-changes)); you can see the error by running `WebCon.WorkFlow.Bootstrapper.exe` from a console in the Service directory |
| Portal panels are empty, and Service panels show Portal routes | service names from appsettings instead of the fixed `Portal` / `WebCon.WorkFlow` – run `Set-WebconTelemetry.ps1` (`webcon.component` marker); `No appsettings files with an OpenTelemetry section found` = WEBCON outside `Program Files[ (x86)]\WEBCON` → `-SearchRoot` |
| WEBCON dashboards are empty after a WEBCON upgrade | the upgrade overwrote appsettings – run `Set-WebconTelemetry.ps1` again |
| no slow SQL queries in traces | SQL spans shorter than the threshold (default: 1 s) are dropped – this is intended; the installer's `-SqlSpanThresholdSeconds` |

## Where the logs are

| Component | Log |
|---|---|
| Grafana, Prometheus, Loki, Tempo | `C:\Observability\logs\<component>\` (`*.out.log`, `*.err.log`; Grafana: `grafana.log`) |
| Alloy | **Event Viewer** → Application, source `Alloy` (not files), and the UI at <http://localhost:12345> |
| WinSW services | `C:\Observability\logs\<component>\*.wrapper.log` |
| installation configuration | `C:\Observability\config\install-settings.json` |

## Corrupted Tempo index

Symptom: the “Where the time goes” panels and other TraceQL-based panels show `reading parquet file metadata: missing required field`; smoke test: `Tempo: TraceQL metrics` error.

```powershell
Stop-Service obs-tempo -Force          # also stops obs-alloy (dependency)
Remove-Item C:\Observability\data\tempo\blocks\single-tenant\index.json.gz, `
            C:\Observability\data\tempo\blocks\single-tenant\index.pb.zst -ErrorAction SilentlyContinue
Start-Service obs-tempo, obs-alloy
```

Tempo rebuilds the index from the blocks; no data is lost. In versions up to 0.10.0 (Tempo 2.10) the index was corrupted repeatedly on Windows (a Tempo 2.x bug) – the upgrade to 0.11.0 (Tempo 3) removes the cause; the procedure remains for any other index error.

## Components directly (diagnostics)

| Address | What it shows |
|---|---|
| <http://localhost:12345> | Alloy – processing graph, component status |
| <http://localhost:9090/query?g0.expr=up> | Prometheus – `up` = 1 for each metrics source scraped by Alloy (windows, mssql, stack components) |
| <http://localhost:3200/ready>, <http://localhost:3100/ready> | Tempo, Loki readiness |
