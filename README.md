# Observability Stack (WEBCON)

An unofficial, self-hosted observability stack (metrics, traces, logs) for analyzing the performance of **WEBCON 2026.2+** installations on Windows Server – a demonstration of monitoring capabilities.

> **Disclaimer.** A private project shared as a demonstration of monitoring capabilities. It is not a WEBCON product and is not developed, supported, or endorsed by WEBCON. No support and no warranty – use at your own risk; test the solution before using it in a production environment. Details: MIT license ([LICENSE](LICENSE)). WEBCON, Grafana, and other names are trademarks of their respective owners.

| Signal | Source | Component |
|---|---|---|
| Metrics | WEBCON Portal/Service (OTLP), Windows/IIS host, SQL Server | **Prometheus** |
| Traces (OTLP) | WEBCON Portal/Service | **Grafana Tempo** |
| Logs | Portal and Service (OTLP; since 2026.2), optionally Serilog files | **Grafana Loki** |
| Collector | everything above | **Grafana Alloy** |
| Visualization | metrics ↔ traces ↔ logs correlation | **Grafana** |

```
WEBCON Portal ───OTLP/HTTP :4318──┐
WEBCON Service ──OTLP/HTTP :4318──┤
Serilog (Service files) ──────────┤                  ┌─> Prometheus :9090 (remote write + exemplars)
windows_exporter (built-in) ──────┼─> Grafana Alloy ─┼─> Tempo      :3200 (OTLP gRPC :14317)
SQL Server (dedicated login) ─────┘   :12345 (UI)    └─> Loki       :3100 (/otlp, push)
                                                               │
                                 Tempo metrics-generator ──────┘ (span metrics, service graph -> Prometheus)
                                                     Grafana :3000 (data sources with correlation)
```

All components run as **Windows services** (WinSW, prefix `obs-`) and listen on `127.0.0.1` only (Grafana optionally on all interfaces).

## Documentation

**[Documentation site](https://mmbednarz.github.io/observability-stack/)** (one copy per release; the same pages are in `docs/` of the package for offline reading). Key pages:

- [Quick start (all-in-one)](https://mmbednarz.github.io/observability-stack/latest/installation/01-quick-start/) · [Requirements and SQL Server](https://mmbednarz.github.io/observability-stack/latest/installation/02-requirements-and-preparation/) · [WEBCON configuration](https://mmbednarz.github.io/observability-stack/latest/installation/03-webcon-configuration/)
- [Remote mode (stack on a separate VM)](https://mmbednarz.github.io/observability-stack/latest/installation/04-remote-mode/) · [Upgrade](https://mmbednarz.github.io/observability-stack/latest/installation/05-upgrade/) · [Uninstall](https://mmbednarz.github.io/observability-stack/latest/installation/06-uninstall/)
- [Troubleshooting](https://mmbednarz.github.io/observability-stack/latest/installation/07-troubleshooting/) · [Installer parameters](https://mmbednarz.github.io/observability-stack/latest/installation/08-installer-parameters/)

## Quick start (summary)

Requirements: Windows Server 2019+ / Windows 10+, administrator, internet access, WEBCON 2026.2+ on the same machine.

1. Download `observability-stack-<version>.zip` from [Releases](https://github.com/mmbednarz/observability-stack/releases), unblock it (`Unblock-File`), and extract it, e.g., to `C:\Install`.
2. In PowerShell as administrator, in the extracted package folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter   # or -SqlServer '' (without SQL)
C:\Observability\app\scripts\Set-WebconTelemetry.ps1    # enables WEBCON telemetry (restarts WEBCON)
C:\Observability\app\Test-ObservabilityStack.ps1        # smoke test
```

The installer copies the scripts to `C:\Observability\app` – the package can be deleted afterward.

Grafana: <http://localhost:3000> – user `admin`, password in `C:\Observability\secrets\grafana-admin.txt`. Step by step (SQL logins, SQL Express, verification): [Quick start](https://mmbednarz.github.io/observability-stack/latest/installation/01-quick-start/).

## Dashboards

| Folder / dashboard | Contents |
|---|---|
| `webcon` / WEBCON – Performance | status, Portal, forms and path transitions, “where the time goes” (paths, business rules, data sources, actions – TraceQL metrics), SQL from the WEBCON perspective, Service (queues, timers, Solr, cache), .NET runtime, logs. |
| `webcon` / WEBCON – Operations | weekly overview (7 days): host, Portal visits, top 10 actions and paths (average, median, p95, min, max; path names from the database), active tasks by user (current state from the database), external APIs called by WEBCON (calls, p95, errors), data source and action errors. Panels based on the database require `-WebconSqlReaderLogin`. |
| `webcon` / WEBCON – Availability and backlog | Portal `/health` probe (the `-PortalUrl` address or from IIS bindings; HTTP code, time, certificate), backlog in the content database (overdue timeouts, cyclical actions with errors, email queue, queue and log tables). Database metrics require `-WebconDbMetrics $true`. |
| `host` / Windows – Host load | CPU, memory, disks, network, processes (WEBCON, IIS, SQL), IIS |
| `sql` / SQL Server – WEBCON | load, waits by category, locks, I/O and database size, memory, slow SQL queries from Tempo |
| `dotnet` | ASP.NET Core (grafana.com 19924, 19925) |

SQL Server metrics are defined in `config-templates/alloy/mssql-queries.yaml` (default exporter metrics + extensions), WEBCON content database metrics in `config-templates/alloy/webcon-db-queries.yaml`.

The dashboard folder on the server is managed by the installer: `.json` files that are not in the repository and not in `CommunityDashboards` are removed during installation. Save your own dashboards in Grafana (database) or add them to `dashboards/`.

## Alerts

30 Grafana Alerting rules provisioned from `config-templates/grafana/provisioning/alerting/` (description: [Alerts](https://mmbednarz.github.io/observability-stack/latest/user-guide/07-alerts/)):

| Folder | Rules |
|---|---|
| WEBCON – alerts | W1–W10: p95 of path transitions (> 5 s) and of the Portal (> 3 s), Portal 5xx (> 5 %), missing Service heartbeat / heartbeat errors, Service queue errors, growing Solr backlog, data source errors (Loki), external API call errors, spike in log errors; B1–B2: Portal unavailable, certificate expiring soon; D1–D3: overdue timeouts, emails not being sent, cyclical actions with errors; S1–S3: deadlocks, blocking, Page Life Expectancy; H1–H4: CPU, memory, disk (per host) |
| Observability stack – alerts | O1–O7: stack component not responding, host stopped sending metrics (including remote agents), no telemetry from the Service, Tempo query errors, spanmetrics series limit, telemetry dropped in Alloy, stack data disk |

- Notifications: **Grafana UI only** (Alerting → Alert rules / Active notifications) – no contact points. Silencing: Alerting → Silences.
- No data does not trigger alerts (a machine without WEBCON / SQL stays silent); a stopped Service or agent is detected by rules of the form “data present within the last 24 h, missing for 10–15 min” (W4, O2, O3).
- A Prometheus / Loki failure = `Error` state (`DatasourceError`) for the rules that use that data source.
- The rules are read-only in the UI – to change them, edit the YAML in the repository and reinstall. An error in a rule file prevents Grafana from starting (log: `Failed to provision alerting`).
- `Test-ObservabilityStack.ps1` (“Alerts” section) counts the rules, reports evaluation errors, and lists firing alerts.

## Telemetry data security

Alloy removes the `webcon.db.cs` attribute (database connection details) from spans before they are stored (`otelcol.processor.attributes "webcon_secrets"`), and `Test-ObservabilityStack.ps1` checks this.

## SQL tracing modes

| Mode | WEBCON `SqlTracing` | Alloy | Use case |
|---|---|---|---|
| Threshold (default) | enabled | drops SQL spans < `-SqlSpanThresholdSeconds` | analysis of slow queries at a reasonable volume |
| All | enabled | `-SqlSpanThresholdSeconds 0` | full picture, high volume |
| Disabled | `Set-WebconTelemetry.ps1 -SqlTracing Off` | – | minimum volume |

The filter covers the WEBCON `SqlQuery` span and SqlClient spans (`db.system` / `db.system.name`).

## Versions

Releases: [Releases](https://github.com/mmbednarz/observability-stack/releases), changes and manual upgrade steps: [CHANGELOG.md](CHANGELOG.md). The installed version is shown by the smoke test (`C:\Observability\config\install-settings.json`, field `StackVersion`). Upgrade guide: [Upgrade](https://mmbednarz.github.io/observability-stack/latest/installation/05-upgrade/).

## Package structure

```
Install-ObservabilityStack.ps1     stack installation / upgrade
Uninstall-ObservabilityStack.ps1   removal of services (-RemoveFiles: data as well)
Test-ObservabilityStack.ps1        end-to-end smoke test
Install-ObservabilityAgent.ps1     agent on a WEBCON / SQL host (remote mode, run from the agent-bundle package)
Uninstall-ObservabilityAgent.ps1   agent removal
versions.psd1                      pinned versions + URLs + community dashboards
scripts/
  Set-WebconTelemetry.ps1          OpenTelemetry configuration in WEBCON appsettings
  Test-SqlExporterLogin.ps1        standalone verification of the SQL login
  modules/ObservabilityStack.psm1  shared functions
config-templates/                  configuration templates ({{VARIABLES}}, @@BEGIN/@@END blocks)
dashboards/                        dashboards provisioned to Grafana (subfolder = folder)
config-templates/grafana/provisioning/alerting/   Grafana alert rules
sql/                               T-SQL for the DBA
webcon/                            sample WEBCON OpenTelemetry section
docs/                              documentation (installation/, user-guide/)
VERSION, CHANGELOG.md, LICENSE     version, changelog, MIT license
```

## Layout on the server

```
C:\Observability\
  bin\<component>\        binaries (.version file = installed version)
  config\                 generated configurations + install-settings.json
  data\                   TSDB, Tempo blocks, Loki chunks, Grafana database
  logs\<component>\       service logs (WinSW, rotation 10 MB x 8)
  services\obs-*\         WinSW wrappers (exe + xml)
  secrets\                Grafana password, SQL connection string, password of the Grafana database login (ACL: SYSTEM + Administrators)
  downloads\              cache of downloaded archives
  app\                    copy of the installed version's scripts (smoke test, uninstall, parameter changes)
```

## Diagnostics

Table of problems and solutions, component logs, Tempo index repair: [Troubleshooting](https://mmbednarz.github.io/observability-stack/latest/installation/07-troubleshooting/).

## Security (dev)

- Services on localhost only, no authentication between components.
- `ShowDbStatements = true` – SQL query text is included in traces (assumption: administrative/DBA access).
- Secrets in files with an ACL restricted to SYSTEM and Administrators; never in the repository.
