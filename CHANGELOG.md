# Changelog

Format: one section per version – **Changes** and **Requires action** (manual steps when upgrading from the previous version). Numbering follows [SemVer](https://semver.org/): major = a change that requires manual migration, minor = new features, patch = fixes.

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
