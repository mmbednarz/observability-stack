# Upgrade

The installer is **idempotent**: running it again on an installed stack upgrades the binaries, configuration, dashboards and alert rules, and **keeps the data** (metrics, traces, logs, Grafana users) and secrets.

## Upgrading to a new version

1. Download the new package from [Releases](https://github.com/mmbednarz/observability-stack/releases), unblock it and extract it **to a new directory** (e.g. `C:\Install\observability-stack-0.12.0`) – as in [Quick start, step 1](01-quick-start.md#step-1-download-the-installation-files).
2. Read the section of the new version in `CHANGELOG.md` (in the package) – **Requires action** lists the manual steps (e.g. new SQL permissions, running `Set-WebconTelemetry.ps1` again).
3. PowerShell as administrator, in the new package directory:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\Install-ObservabilityStack.ps1 -NonInteractive
   C:\Observability\app\Test-ObservabilityStack.ps1
   ```

The installer shows the version change (`Upgrading 0.11.0 -> 0.12.0`), keeps the settings and data, and replaces `C:\Observability\app` with the scripts of the new version. You can delete the old and the new package afterwards. The installed version is shown by the smoke test (the “Version” section).

**A version older** than the installed one – the installer stops (the configuration and alert rules of the newer version may not match the older one). Deliberate return to an older version: `-AllowDowngrade`.

**Tempo 3 (version 0.11.0 and later) – no way back below 0.11.0.** The upgrade from 0.10.x replaces Tempo 2.10 with Tempo 3.1.1 automatically (traces from before the upgrade remain available). Tempo 2.10 cannot read the blocks written by Tempo 3, so installing a version older than 0.11.0 on 0.11.0+ requires deleting the trace data (`C:\Observability\data\tempo`, with the services stopped) – all traces are lost. If you may need to go back, copy `data\tempo` before the upgrade.
**Downtime:** the installer stops the `obs-*` services for the duration of the upgrade (usually 1–3 minutes, longer when it downloads new component versions). WEBCON works normally – telemetry from this period is lost, WEBCON is not affected.

### Which settings are kept

All settings of the stack are kept (saved in `C:\Observability\config\install-settings.json`). Rule: **a parameter specified explicitly > the value from the previous installation > the default value**. An upgrade with `-NonInteractive` alone keeps the whole configuration:

- SQL exporter instance and login (`-SqlServer`, `-SqlLogin`) + password; login, instance and database of the “WEBCON SQL” data source + password,
- network access (`-GrafanaListenAll`, `-OtlpListenAll`) and the firewall rules,
- retention (`-RetentionMetricsDays`, `-RetentionTracesDays`, `-RetentionLogsDays`), `-SqlSpanThresholdSeconds`, `-AlloyMemoryLimit`, `-EnvironmentName`, `-ServiceLogPath`, service name mapping, `-SkipCommunityDashboards`,
- Portal probe (`-PortalProbe`, `-PortalUrl`, `-ProbeUrl`), database metrics (`-WebconDbMetrics`),
- remote mode: hosts, instance, port, addresses, login passwords; the Grafana administrator password.

The installer lists the values different from the defaults that it took over, e.g. `Kept from the previous installation: -GrafanaListenAll, -RetentionMetricsDays 90`. The full list with the **Kept** column: [Installer parameters](08-installer-parameters.md).

Not kept (actions for a single run): `-NonInteractive`, `-ForceDownload`, `-AllowDowngrade`, `-ConfigureWebcon`. Always specify the same `-Root` (the settings file is in it).

Upgrade from 0.11.0 or older: the values that these versions did not save (network access, metrics and logs retention, Alloy memory limit) are read from the current configuration of the stack.

### What an upgrade overwrites

- **Dashboards** from the package (`dashboards\`) – changes made in Grafana to these dashboards will be lost. Save your own dashboards as **new** ones (*Save as*) – they are stored in the Grafana database and an upgrade does not touch them.
- **Alert rules** – they are read-only in Grafana; a change = editing the YAML in `config-templates\` (overwritten by the next release).
- `.json` files in `C:\Observability\config\grafana\dashboards` that are not part of the package are deleted.
- Component configuration in `C:\Observability\config` – regenerated from the templates.

## Changing parameters

Run the installer again with new parameters – without the package, from the copy in `C:\Observability\app` (the same version), e.g.:

```powershell
cd C:\Observability\app
.\Install-ObservabilityStack.ps1 -GrafanaListenAll
```

Examples:

| Goal | Command |
|---|---|
| add SQL metrics after an installation without SQL | `.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter` |
| add the “WEBCON SQL” data source | `.\Install-ObservabilityStack.ps1 -WebconSqlReaderLogin svc_obs_grafana_reader` |
| change the SQL exporter login password | `.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter` (prompts for the password) |
| disable SQL metrics | `.\Install-ObservabilityStack.ps1 -SqlServer ''` |
| disable the “WEBCON SQL” data source | `.\Install-ObservabilityStack.ps1 -WebconSqlReaderLogin ''` |
| Grafana accessible from the network | `.\Install-ObservabilityStack.ps1 -GrafanaListenAll` (adds a firewall rule for port 3000) |
| Grafana accessible only locally again | `.\Install-ObservabilityStack.ps1 -GrafanaListenAll:$false` (removes the firewall rule) |
| longer trace retention | `.\Install-ObservabilityStack.ps1 -RetentionTracesDays 14` |

The other settings stay unchanged – specify only the parameter you change.

Full list: [Installer parameters](08-installer-parameters.md).

## After a WEBCON upgrade

A WEBCON upgrade can overwrite `appsettings` and `web.config` and recreate content database tables:

1. `C:\Observability\app\scripts\Set-WebconTelemetry.ps1` – enables telemetry export again (WEBCON restart).
2. DBA: `C:\Observability\app\sql\grant-webcon-reader-permissions.sql` – grants the permissions to the Grafana login again.
3. `C:\Observability\app\Test-ObservabilityStack.ps1` – verification.

Symptom of skipping these steps: empty WEBCON dashboards (step 1 missing) or errors in panels with path names and tasks (step 2 missing).

## Changing a component version (advanced)

The versions of Grafana, Prometheus, Tempo, Loki and Alloy are pinned in `versions.psd1` (URL + SHA256 checksum) and change with stack releases. Do not change them on the server – the configuration may require changes (e.g. Tempo 3.x removes the `ingester` / `compactor` sections).

## Grafana administrator password

The `C:\Observability\secrets\grafana-admin.txt` file is used **only on the first start** of Grafana (database creation). A password changed later in Grafana (*Profile → Change password*) is not saved in the file – the file will be out of date, and the smoke test will not check alerts. Recommendation: do not change the `admin` password; create separate accounts for people.

Resetting a forgotten password (PowerShell as administrator):

```powershell
& C:\Observability\bin\Grafana\bin\grafana.exe cli --homepath C:\Observability\bin\Grafana `
    --config C:\Observability\config\grafana\grafana.ini admin reset-admin-password (Get-Content C:\Observability\secrets\grafana-admin.txt)
```
