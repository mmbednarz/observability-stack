# Remote mode – stack on a separate machine

You install the stack (Grafana, Prometheus, Tempo, Loki) on a **separate, empty VM**. The WEBCON and SQL Server hosts run only a lightweight **agent** (the `obs-alloy` service) that collects data and sends it to the stack.

```
WEBCON host                                    Stack VM
  Portal / Service ─OTLP─> agent obs-alloy ──TCP 4317 (traces, logs)──> Alloy ─> Tempo / Loki / Prometheus
  Windows / IIS metrics ─┘                 └─TCP 9999 (metrics)───────>          Grafana :3000
SQL host
  Windows + SQL metrics ─> agent obs-alloy ──TCP 9999──────────────>
  SQL Server <──────────────── TCP 1433 ── Grafana ("WEBCON SQL" data source)
```

When to choose it: a production-like environment, WEBCON and SQL on different servers, no approval for additional services on the WEBCON server other than the agent.

> **Status:** the mode has been verified on a single VM with a simulated agent. Agent installation on real WEBCON / SQL hosts has not been tested yet – please report problems.

## Requirements

- Stack VM: as in [Requirements](02-requirements-and-preparation.md#server); internet access is needed only on the stack VM (the agent bundle contains the binaries).
- Network connectivity:

  | From | To | Port | Purpose |
  |---|---|---|---|
  | WEBCON host, SQL host | stack VM | TCP 4317 | traces and logs (OTLP gRPC) |
  | WEBCON host, SQL host | stack VM | TCP 9999 | metrics |
  | stack VM | SQL host | TCP 1433 (`-SqlPort`) | “WEBCON SQL” data source in Grafana |
  | users' browsers | stack VM | TCP 3000 | Grafana (`-GrafanaListenAll`) |

- On the hosts: local administrator; on the SQL host, a Windows account with the `sysadmin` role (the script creates logins and grants permissions).
- Agent → stack connections use **no TLS and no authentication**; the stack VM firewall allows only the host addresses. Filters (including removal of the `webcon.db.cs` attribute from traces) already run in the agent.

## Step 1. Stack VM – install the stack and the agent bundle

```powershell
.\Install-ObservabilityStack.ps1 -WebconHost WEBCON01 -SqlHost SQL01 -SqlInstanceName SQLEXPRESS -PortalUrl https://bps.example.com -GrafanaListenAll
```

| Parameter | Meaning |
|---|---|
| `-WebconHost` | name of the WEBCON host (Portal + Service) |
| `-SqlHost` | name of the SQL Server host with the WEBCON databases |
| `-SqlInstanceName` | instance name (`MSSQLSERVER` = default instance) |
| `-SqlPort` | TCP port of the instance (default: 1433) |
| `-WebconContentDatabase` | content database (default: `WEBCON_Content`) |
| `-PortalUrl` | main Portal address for the availability probe (without the parameter the installer asks); the probe is run by the agent on the WEBCON host, connecting locally |
| `-CentralAddress` | stack VM address used by the agents (default: FQDN) |
| `-AgentAddress` | IP addresses allowed in the firewall (default: from DNS of the host names) |

The installer creates the `C:\Observability\agent-bundle` bundle and the `agent-bundle.zip` archive with:

- `README.txt` – the order of steps with the names of your hosts,
- `01-Sql-SQL01.ps1`, `02-Webcon-WEBCON01.ps1` – ready-to-run scripts for the hosts (WEBCON and SQL on one host: a single `01-WebconSql-<host>.ps1` script),
- Alloy and WinSW binaries, SQL scripts, `Set-WebconTelemetry.ps1`,
- **SQL login passwords** (`secrets\sql-logins.json`) – the bundle is confidential; delete it from the hosts after installation.

## Step 2. SQL host

Copy `agent-bundle.zip` to the SQL host, extract it, and run PowerShell as administrator in the bundle directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\01-Sql-SQL01.ps1
```

The script creates the `svc_obs_mssql_exporter` and `svc_obs_grafana_reader` logins, grants permissions, installs the agent (Windows + SQL Server metrics) and adds a firewall rule for Grafana.

When TCP is disabled for the instance (typical for SQL Express), the script stops with a message. In that case:

```powershell
.\01-Sql-SQL01.ps1 -EnableSqlTcp     # WARNING: restarts the SQL Server instance
```

## Step 3. WEBCON host

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\02-Webcon-WEBCON01.ps1
```

The script installs the agent (receives WEBCON telemetry on `127.0.0.1:4318`, Windows and IIS metrics, Portal `/health` probe) and runs `Set-WebconTelemetry.ps1` – it **restarts the WEBCON WorkFlow Service and the Portal application** (with confirmation; `-Force` without prompting, `-SkipWebconConfig` without changing WEBCON).

The order “SQL first, then WEBCON” lets you fit both outages (SQL restart, WEBCON restart) into a single maintenance window.

## Step 4. Stack VM – verification

```powershell
.\Test-ObservabilityStack.ps1
```

The “Remote agents” section checks host metrics, SQL metrics, WEBCON telemetry and a test log sent by the agent. Portal telemetry appears after the first visit to the Portal.

Finally, delete the bundle (`agent-bundle`, `agent-bundle.zip`) from the WEBCON and SQL hosts – the agent script copies everything needed later (uninstallation, `Set-WebconTelemetry.ps1`, SQL scripts) to `C:\Observability\app` on the host, without passwords. Do not extract the bundle to `C:\Observability` – the script will refuse to run.

## Upgrades and changes

- Running the stack installer again **without** `-WebconHost` / `-SqlHost` keeps the hosts and passwords (the bundle is regenerated with the same passwords).
- Agent upgrade: after the stack is upgraded to a new version, the installer generates a new agent bundle (with the same version) → run the host script again (the script is idempotent).
- Returning to local mode: `.\Install-ObservabilityStack.ps1 -WebconHost '' -SqlHost ''`.
- Removing the agent from a host: [Uninstall → agent](06-uninstall.md#remote-mode--removing-the-agent).
