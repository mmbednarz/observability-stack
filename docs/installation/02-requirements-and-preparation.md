# Requirements and preparation

## Server

| Requirement | Details |
|---|---|
| Operating system | Windows Server 2019+ (verified on 2025) or Windows 10/11 (verified on 11). `tar.exe` is required (included in the system since Windows 10 1803 / Server 2019) |
| PowerShell | Windows PowerShell 5.1 (built-in) or PowerShell 7+ |
| Permissions | local administrator – installing Windows services, writing to `C:\Observability`, reading secrets |
| Internet | `github.com`, `objects.githubusercontent.com`, `dl.grafana.com`, `grafana.com` (community dashboards). Proxy: configure it in the system before installation |
| Disk | ~1 GB of binaries + data: depends on traffic and retention, on dev usually < 10 GB |
| Memory | about 2–3 GB of RAM for all stack services (Alloy has a 1 GiB limit, parameter `-AlloyMemoryLimit`) |
| WEBCON | **2026.2+** (Portal and Service). 2026.1 is not supported – different span names, panels based on traces would be empty |

### Ports (`127.0.0.1` only)

| Port | Component | Port | Component |
|---|---|---|---|
| 3000 | Grafana | 9090 | Prometheus |
| 4317 / 4318 | Alloy – OTLP receiver (gRPC / HTTP) for WEBCON | 9096 | Loki gRPC |
| 12345 | Alloy – UI | 3100 | Loki HTTP |
| 3200 | Tempo HTTP | 9097 / 14317 / 7947 | Tempo gRPC / OTLP / memberlist |

The installer checks the ports before installation and prints the process that occupies a port (e.g., a local Jaeger, Seq, or another OTLP collector). In local mode, no firewall rules are needed.

## SQL Server

SQL Server metrics and panels based on the WEBCON database are optional. **Two separate SQL logins** are needed (SQL authentication, not Windows):

### 1. Metrics exporter login – `svc_obs_mssql_exporter`

Collects server metrics (load, waits, locks, I/O, memory). It needs only `VIEW SERVER STATE` and `VIEW ANY DEFINITION` – **without** access to WEBCON data and without `sysadmin`.

The DBA runs in SSMS:

```sql
CREATE LOGIN [svc_obs_mssql_exporter] WITH PASSWORD = N'<strong_password>', CHECK_POLICY = ON, DEFAULT_DATABASE = [master];
-- then the script from the repository:
-- sql\grant-sql-exporter-permissions.sql
```

Checking the login without installing: `.\scripts\Test-SqlExporterLogin.ps1`.

### 2. Grafana login to the content database – `svc_obs_grafana_reader`

The “WEBCON – Operations” dashboard shows the **names** of paths and processes (traces contain only IDs) and the current active tasks. The login gets `SELECT` on only 5 tables: `ActiveTasks`, `WFAvaiblePaths`, `WFSteps`, `WorkFlows`, `WFDefinitions` – without access to form data.

```sql
CREATE LOGIN [svc_obs_grafana_reader] WITH PASSWORD = N'<strong_password>', CHECK_POLICY = ON, DEFAULT_DATABASE = [master];
-- then the script from the repository (set the content database names in the header, default WEBCON_Content):
-- sql\grant-webcon-reader-permissions.sql
```

> A WEBCON upgrade can recreate the tables and remove the permissions – after a WEBCON upgrade, the DBA runs this script again.

Why two logins: any dashboard editor can write queries against the Grafana data source, and the exporter login can see the query text of other sessions (`VIEW SERVER STATE`). The Grafana login therefore has a minimal scope.

### 3. Metrics from the content database (optional)

Backlog that is not visible in WEBCON telemetry: overdue timeouts, cyclical actions with errors, the email queue, sizes of queue and log tables (the “WEBCON – Availability and backlog” dashboard, alerts D1–D3). Enabled with the installer parameter `-WebconDbMetrics $true`; requires SQL metrics (the exporter login).

The **exporter** login (`svc_obs_mssql_exporter`) gets a user in the content database and `SELECT` **only on the columns** used in the queries (IDs, statuses, counters, dates) – without email and form content. The DBA runs the script from the repository (set the login and the content database names in the header):

```sql
-- sql\grant-webcon-db-metrics.sql
DECLARE @login     sysname       = N'svc_obs_mssql_exporter';
DECLARE @databases nvarchar(max) = N'WEBCON_Content';
```

Missing permissions do not stop the installation – the installer prints a warning, and the metrics appear once the permissions are granted (without reinstalling). After a WEBCON upgrade, run the script again.

### SQL Server Express – enabling TCP

The exporter connects to SQL Server **over TCP only**. SQL Server Express has TCP and the SQL Browser service disabled by default, so the `localhost\SQLEXPRESS` address does not work. Enable TCP with a static port:

1. **SQL Server Configuration Manager** → *SQL Server Network Configuration* → *Protocols for SQLEXPRESS*.
2. **TCP/IP** → *Enabled* = **Yes**.
3. *TCP/IP* → *Properties* → **IP Addresses** tab → **IPAll** section: *TCP Dynamic Ports* = empty, *TCP Port* = **1433**.
4. Restart the **SQL Server (SQLEXPRESS)** service – this drops connections, including WEBCON's.
5. Check: `sqlcmd -S localhost,1433 -E -C -Q "SELECT @@VERSION"`.

Windows Firewall rules are not needed when SQL and the stack are on the same machine. In the installer, specify `-SqlServer 'localhost,1433'`.

## Before installation – checklist

- [ ] PowerShell running as administrator
- [ ] release package files extracted and unblocked (`Unblock-File` on the ZIP)
- [ ] (optional) SQL logins created, passwords at hand
- [ ] (SQL Express) TCP enabled on port 1433
- [ ] maintenance window for restarting WEBCON (the `Set-WebconTelemetry.ps1` step)

Next: [Quick start, step 3](01-quick-start.md#step-3-run-the-installer).
