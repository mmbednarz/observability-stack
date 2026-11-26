# Installer parameters (`Install-ObservabilityStack.ps1`)

The parameters are also described in the script header (`.PARAMETER`); syntax list: `Get-Help .\Install-ObservabilityStack.ps1`.

The **Kept** column – whether the installer uses the previous value when run again without the parameter ([Upgrade](05-upgrade.md#which-settings-are-kept)). “No” = the default value is restored. A kept switch is disabled with `-Name:$false` (e.g. `-GrafanaListenAll:$false`).

## Basic

| Parameter | Default | Kept | Description |
|---|---|---|---|
| `-Root` | `C:\Observability` | – | installation directory (always specify the same one) |
| `-EnvironmentName` | computer name | yes | environment label in telemetry |
| `-NonInteractive` | – | – | no prompts – missing values = error (automated scripts) |
| `-ConfigureWebcon` | – | – | after installation, runs `scripts\Set-WebconTelemetry.ps1` (OpenTelemetry configuration in WEBCON appsettings) |
| `-AllowDowngrade` | – | – | allows installing a version older than the installed one (without this switch, a downgrade stops the installation) |
| `-ForceDownload` | – | – | downloads the components again (instead of using `C:\Observability\downloads`) |
| `-SkipCommunityDashboards` | – | yes | no ASP.NET Core dashboards from grafana.com |

## SQL Server – metrics

| Parameter | Default | Kept | Description |
|---|---|---|---|
| `-SqlServer` | prompt | yes | SQL Server instance to monitor, recommended in the `host,port` format (e.g. `localhost,1433`); a server name or `server\instance` also works if the instance is reachable over TCP (named instance: SQL Browser running); `''` = no SQL Server metrics |
| `-SqlLogin` | prompt | yes | dedicated SQL login for the exporter ([permissions](02-requirements-and-preparation.md#1-metrics-exporter-login--svc_obs_mssql_exporter)) |
| `-SqlPassword` | prompt | yes (secret) | `SecureString`, e.g. `(Read-Host -AsSecureString)` |
| `-SqlEncrypt` / `-SqlTrustServerCertificate` | `$true` / `$true` | no | connection encryption / accepting the certificate without validation |

## SQL Server – “WEBCON SQL” data source (content database)

| Parameter | Default | Kept | Description |
|---|---|---|---|
| `-WebconSqlReaderLogin` | – | yes | read-only SQL login ([permissions](02-requirements-and-preparation.md#2-grafana-login-to-the-content-database--svc_obs_grafana_reader)); `''` = no data source |
| `-WebconSqlReaderPassword` | prompt | yes (secret) | `SecureString` |
| `-WebconSqlServer` | `-SqlServer` | yes | SQL Server instance hosting the content database |
| `-WebconContentDatabase` | `WEBCON_Content` | yes | content database name |

## Availability and WEBCON database metrics

| Parameter | Default | Kept | Description |
|---|---|---|---|
| `-PortalProbe` | `$true` | yes | Portal `/health` availability probe (in remote mode: the agent on the WEBCON host) |
| `-PortalUrl` | prompt | yes | main Portal address, the one users open, e.g. `https://bps.example.com`. The probe connects locally on the Portal server and verifies the certificate for the host name from this address. The installer asks, suggesting the address from an IIS binding with a host name; with `-NonInteractive` it uses that address, and when the bindings have no host name (`*`) it skips the probe with a warning. `'` = detection from IIS |
| `-ProbeUrl` | – | yes | additional HTTP(S) addresses to check (2xx code), e.g. the production Portal; `''` = no additional addresses |
| `-WebconDbMetrics` | `$false` | yes | metrics from the content database (`-WebconContentDatabase`): overdue timeouts, cyclical actions, emails, queue and log tables; permissions: `sql\grant-webcon-db-metrics.sql` |

## Telemetry and retention

| Parameter | Default | Kept | Description |
|---|---|---|---|
| `-SqlSpanThresholdSeconds` | `1` | yes | SQL query spans shorter than the threshold are dropped; `0` = keep all (high volume) |
| `-RetentionMetricsDays` | `15` | yes | how many days to keep metrics |
| `-RetentionTracesDays` | `8` | yes | traces (the “WEBCON – Operations” dashboard shows 7 days) |
| `-RetentionLogsDays` | `7` | yes | logs |
| `-AlloyMemoryLimit` | `1GiB` | yes | Alloy memory limit |
| `-WebconPortalServiceName` / `-WebconServiceServiceName` | – | yes | **fallback** service name mapping: the name (`ServiceName` from WEBCON appsettings) under which the Portal / Service sends telemetry without the `webcon.component` marker; Alloy replaces it with `Portal` / `WebCon.WorkFlow`. Not needed after `Set-WebconTelemetry.ps1`; the values must differ; `''` = no mapping |
| `-ServiceLogPath` | – | yes | glob pattern of the Service log files (e.g. `D:\WEBCON\Service\Logs\*.log`) – only for a Service without OTLP log export (WEBCON 2026.2 exports logs, do not use) |

## Network

| Parameter | Default | Kept | Description |
|---|---|---|---|
| `-GrafanaListenAll` | – | yes | Grafana on all interfaces + firewall rule `Observability - Grafana` (TCP 3000, Domain/Private profiles); `-GrafanaListenAll:$false` = localhost only, the rule is removed |
| `-OtlpListenAll` | – | yes | OTLP reception from the network (WEBCON on another machine **without** an agent) + rule `Observability - OTLP`; `-OtlpListenAll:$false` = disable, the rule is removed |

## Remote mode

Description: [Remote mode](04-remote-mode.md).

| Parameter | Default | Kept | Description |
|---|---|---|---|
| `-WebconHost` / `-SqlHost` | – | yes | agent hosts; `''` for both = return to local mode |
| `-SqlInstanceName` | `MSSQLSERVER` | yes | instance name on `-SqlHost` |
| `-SqlPort` | `1433` | yes | TCP port of the instance |
| `-CentralAddress` | stack VM FQDN | yes | stack address written to the agent configuration |
| `-AgentAddress` | host IP addresses from DNS | yes | IP addresses of the agent hosts allowed in the firewall |

## Examples

```powershell
# minimal installation without SQL
.\Install-ObservabilityStack.ps1 -SqlServer '' -NonInteractive

# full all-in-one installation (prompts for passwords)
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter `
    -WebconSqlReaderLogin svc_obs_grafana_reader -GrafanaListenAll -ConfigureWebcon

# no prompts (passwords from variables)
$exp = Read-Host 'Exporter password' -AsSecureString
$rdr = Read-Host 'Reader password' -AsSecureString
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter -SqlPassword $exp `
    -WebconSqlReaderLogin svc_obs_grafana_reader -WebconSqlReaderPassword $rdr -NonInteractive
```
