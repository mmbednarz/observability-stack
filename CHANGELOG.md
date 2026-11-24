# Changelog

Format: one section per version – **Changes** and **Requires action** (manual steps when upgrading from the previous version). Numbering follows [SemVer](https://semver.org/): major = a change that requires manual migration, minor = new features, patch = fixes.

## [0.11.0] – 2026-11-24

### Changes

- **Tempo 3.1.1** (previously 2.10.7): the upgrade fixes the repeatedly corrupted Tempo block index on Windows (TraceQL panels: `reading parquet file metadata: missing required field`; a Tempo 2.x bug – grafana/tempo#5588) and the growing Tempo memory use. Traces and TraceQL metrics from before the upgrade remain available. The installer migrates automatically: it writes the last traces to storage, removes the Tempo 2.x working directories (`data\tempo\wal`, `data\tempo\generator\traces`) and starts Tempo 3 (live-store).
- Fix: “trace not found” after clicking an exemplar (e.g. *Portal response time*) or a trace link for a trace older than ~1 h – the Tempo data source no longer limits a trace-by-ID lookup to the Explore time range (`traceQuery.timeShiftEnabled: false`).
- Alert O4 (*Tempo – query errors*) counts only errors returned to Grafana (`api_*` routes) – internal sub-requests are retried by Tempo and the user gets a correct response.
- Smoke test: checks the running Tempo version and warns about Tempo working directories outside the data directory (`C:\var\tempo`).
- *WEBCON – Operations*, external API panels and alert W9: calls to Solr (port `8983`) and to the WEBCON host by IP address (resolved by the installer) are excluded as internal WEBCON communication – previously Solr called by IP (e.g. `10.0.0.5:8983`) appeared as an external API.
- Alert S3 (*SQL memory pressure*): `for` 15 → 30 min – short Page Life Expectancy drops during nightly SQL maintenance no longer raise the alert.

### Requires action

- None – the installer updates Tempo, the dashboard and the rules. Remote mode: the agents do not need to be updated.
- As with every upgrade, repeat the switches that are not saved (`-GrafanaListenAll`, `-OtlpListenAll`, retention, see *Upgrade*) – otherwise e.g. Grafana becomes available only locally.
- **No way back below 0.11.0** without deleting the trace data – Tempo 2.10 cannot read Tempo 3 blocks (see *Upgrade*). Copy `data\tempo` before the upgrade if you may need to return.

## [0.10.0] – 2026-11-23

### Changes

- Documentation published as a website: <https://mmbednarz.github.io/observability-stack/> – navigation, search, one copy per release (version selector; `latest` = newest release). The `.md` files stay in `docs/` of the package for offline reading.
- *Documentation* links in the dashboards and on the Start dashboard open the website pages of the installed version.

### Requires action

- None – the dashboard links are updated by the installer.

## [0.9.1] – 2026-11-22

### Changes

- User interface and documentation in English: script messages and help, comments, dashboards, alert rules, README, CHANGELOG, documentation. Documentation moved to `docs/installation/` and `docs/user-guide/` (English file names).
- Alert folders renamed to *Observability stack – alerts* and *WEBCON – alerts* (rule groups: *Stack*, *WEBCON*, *SQL Server and hosts*); the installer removes the old, empty folders. Rule UIDs and conditions are unchanged.
- SQL wait categories (`obs_wait_stats`) and labels in dashboard queries in English (e.g. `role`, `route_group`, `server`, `data_source`).
- `-RemoveFiles` confirmation: type `yes`.
- Fixed the color threshold of the *Deadlocks (range)* tile.
- Portal availability probe: new `-PortalUrl` parameter – the main Portal address (the installer asks, suggesting the address from an IIS binding with a host name). The probe connects locally on the Portal server, verifies the certificate for the host name from this address, and the Portal is shown under this address in panels and alerts. One probe instead of one per IIS binding.
- IIS bindings without a host name (`*`) are no longer replaced with the server name (this caused a false *Portal unavailable* alert when the certificate is issued for a different name) – without `-PortalUrl` the probe is skipped with a warning.
- Fix: with several IIS bindings of the Portal site (e.g. http + https) the probe got one concatenated address.

### Requires action

- Run the installer from the new package (`.\Install-ObservabilityStack.ps1 -NonInteractive`). Old empty alert folders are removed automatically; a folder that still contains alert rules is kept (the installer prints a warning) and is retried on the next run.
- SQL wait category series recorded before the upgrade keep the old (Polish) category names and are not merged with the new ones on the charts; they disappear with the retention period.
- Own scripts or bookmarks that rely on installer / smoke test output, alert folder names or documentation paths must be updated.
- Portal probe: the probe series are now labeled with the Portal address. Series under the previous addresses (from IIS bindings) stop updating; until they leave the dashboard time range, *WEBCON – Availability and backlog* still shows them, with their last state.
- Fixed: the *Errors and warnings* log panel failed with *Invalid regular expression* (the Loki `TraceId (body)` derived field used an inline `(?i)` flag that browsers do not support). Applied on upgrade.
- Servers where the Portal site has only bindings without a host name: run the installer with `-PortalUrl https://<Portal address>`; in remote mode, then run the WEBCON host script from the agent package again (`-SkipWebconConfig` – no WEBCON restart).

## [0.9.0] – 2026-11-19

First release.

### Changes

- Observability stack as Windows services: Grafana Alloy, Prometheus, Grafana Tempo, Grafana Loki, Grafana (versions in `versions.psd1`); idempotent installer, all services on `127.0.0.1` only.
- WEBCON 2026.2+ telemetry (OTLP): metrics, traces, and logs from the Portal and the Service; `scripts\Set-WebconTelemetry.ps1` configures WEBCON. Fixed service names `Portal` / `WebCon.WorkFlow` regardless of `ServiceName` in appsettings.
- Windows host and IIS metrics, SQL Server metrics (dedicated login), short SQL span filter, removal of the `webcon.db.cs` attribute (database connection details) from spans.
- Dashboards: Start, WEBCON – Performance, WEBCON – Operations, WEBCON – Availability and backlog, Windows – Host load, SQL Server – WEBCON.
- Portal availability probe (`/health`, addresses from IIS bindings) and metrics from the WEBCON content database (overdue timeouts, cyclical actions, email queue, sizes of queue and log tables).
- 30 Grafana alert rules (UI only).
- Remote mode: stack on a separate machine + agent bundle for WEBCON and SQL Server hosts (not verified on production hosts).
- Versioned releases: ZIP package, copy of the scripts in `C:\Observability\app` (smoke test, uninstall, parameter changes without the package), protection against downgrade (`-AllowDowngrade`) and against removing unrelated files with `-RemoveFiles`.

### Requires action

- Installations from before releases (repository clone): run the installer from the extracted package (`.\Install-ObservabilityStack.ps1 -NonInteractive`). If the repository is located in `C:\Observability`, the installer asks you to move it.
