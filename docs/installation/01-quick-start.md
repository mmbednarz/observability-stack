# Quick start – installation on a single machine (all-in-one)

This guide takes you from zero to working dashboards in Grafana when **WEBCON, SQL Server, and the observability stack run on the same machine** (a typical dev / test environment). It takes about 30 minutes, of which about 10 minutes are spent downloading and installing the components.

Stack on a separate machine (WEBCON and SQL on other hosts): [Remote mode](04-remote-mode.md).

> **What you do not need to know:** Prometheus, Grafana, Tempo, or OpenTelemetry. The installer configures everything on its own, and this guide tells you what you should see after each step.

## What gets installed

Five Windows services (names start with `obs-`) in the `C:\Observability` folder:

| Service | Purpose |
|---|---|
| `obs-alloy` | receives telemetry from WEBCON, collects Windows and SQL Server metrics |
| `obs-prometheus` | stores metrics (counters, durations, load) |
| `obs-tempo` | stores traces – the detailed course of individual WEBCON operations |
| `obs-loki` | stores WEBCON logs |
| `obs-grafana` | website with dashboards and alerts – <http://localhost:3000> |

All services listen on `127.0.0.1` only – they are not visible from other computers (to change this: [parameters](08-installer-parameters.md), `-GrafanaListenAll`).

## Step 0. Check the requirements

- Windows Server 2019+ or Windows 10/11, an account with **administrator privileges**.
- **WEBCON 2026.2 or later** (2026.1 is not supported).
- Internet access from the server (GitHub, dl.grafana.com, grafana.com) – the installer downloads the components.
- ~10 GB of free space on drive `C:`.
- Free ports: 3000, 3100, 3200, 4317, 4318, 7947, 9090, 9096, 9097, 12345, 14317 (the installer checks them and reports any conflict).

Details and SQL Server preparation: [Requirements and preparation](02-requirements-and-preparation.md).

## Step 1. Download the installation files

1. Download the latest `observability-stack-<version>.zip` package and the `.sha256` file from the [Releases](https://github.com/mmbednarz/observability-stack/releases) page.
2. Verify the checksum, unblock the archive (otherwise Windows blocks scripts downloaded from the internet), and extract it, e.g., to `C:\Install`:

   ```powershell
   (Get-FileHash .\observability-stack-0.12.1.zip -Algorithm SHA256).Hash   # compare with the .sha256 file
   Unblock-File .\observability-stack-0.12.1.zip
   Expand-Archive .\observability-stack-0.12.1.zip -DestinationPath C:\Install
   ```

Do not extract the package into the `C:\Observability` installation directory – the installer refuses (uninstalling with `-RemoveFiles` would delete it together with the data).

After installation, the package is no longer needed: the installer copies the scripts to `C:\Observability\app` (smoke test, uninstall, parameter changes, `Set-WebconTelemetry.ps1`, SQL scripts).

## Step 2. Prepare the SQL logins (recommended)

Without this step the stack works, but **without** the SQL Server dashboard and without some panels of the “WEBCON – Operations” dashboard. You can skip it and come back to it later (running the installer again adds SQL).

Two SQL logins are needed – details and scripts for the DBA: [Requirements and preparation → SQL Server](02-requirements-and-preparation.md#sql-server).

| Login | Purpose | Script for the DBA |
|---|---|---|
| `svc_obs_mssql_exporter` | SQL Server metrics (load, locks, waits) | `sql\grant-sql-exporter-permissions.sql` |
| `svc_obs_grafana_reader` | reading path names and active tasks from the WEBCON content database | `sql\grant-webcon-reader-permissions.sql` |

> **SQL Server Express:** TCP is disabled by default, and the installer connects to SQL over TCP only. Enable TCP with a static port 1433 – instructions: [Requirements → SQL Server Express](02-requirements-and-preparation.md#sql-server-express--enabling-tcp).

## Step 3. Run the installer

Open **PowerShell as administrator** (right-click → *Run as administrator*) and go to the folder with the files:

```powershell
cd C:\Install\observability-stack-0.12.1
Set-ExecutionPolicy -Scope Process Bypass -Force
```

Choose one option:

```powershell
# a) without SQL Server (simplest)
.\Install-ObservabilityStack.ps1 -SqlServer ''

# b) with SQL Server metrics – the installer asks for the login and password
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter

# c) like b) + data from the WEBCON content database for the "WEBCON – Operations" dashboard (recommended)
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter `
    -WebconSqlReaderLogin svc_obs_grafana_reader -WebconContentDatabase WEBCON_Content
```

`localhost,1433` is the address of the SQL instance in `host,port` format. A named instance on a dynamic port (e.g., `localhost\SQLEXPRESS`) does not work – see the SQL Express note above.

**What you will see:** successive `==> …` sections with `[OK]` lines. The installer:

1. checks free ports and the permissions of the SQL logins (if permissions are missing, it prints commands for the DBA and stops),
2. downloads the components and verifies their checksums,
3. generates the configuration and the Grafana administrator password,
4. registers and starts the `obs-*` services.

At the end, it prints a summary with addresses and – **only on the first installation** – the Grafana administrator password:

```
Summary
    Grafana     http://localhost:3000  (admin / password: C:\Observability\secrets\grafana-admin.txt)
                New admin password: ************************
```

Save the password in a password manager. `Ingester not ready` messages while Loki / Tempo start are normal – the installer waits until the components are ready.

## Step 4. Point WEBCON telemetry to the stack

By default, WEBCON does not send metrics, traces, or logs. The `Set-WebconTelemetry.ps1` script enables this in the `appsettings` files of the Portal and the Service. Preview first:

```powershell
.\scripts\Set-WebconTelemetry.ps1 -WhatIf
```

The script finds the files in `C:\Program Files\WEBCON` and `C:\Program Files (x86)\WEBCON` and lists what it will change. Then make the actual change:

```powershell
.\scripts\Set-WebconTelemetry.ps1
```

After you confirm (`Y`), the script backs up the files (`*.bak-<timestamp>`), changes the configuration, and **restarts the WEBCON WorkFlow Service and the Portal application** – schedule this outside users' working hours. Details and rolling back the changes: [WEBCON configuration](03-webcon-configuration.md).

## Step 5. Check that everything works

```powershell
.\Test-ObservabilityStack.ps1
```

The smoke test sends a test trace, log, and metric and checks that they reached the data stores. Expected result (excerpt):

```
==> End-to-end OTLP flow
    [OK]   Tempo: test trace found
    [OK]   Loki: test log found
    [OK]   Prometheus: test metric found
==> WEBCON and host data (informational)
    [OK]   OTLP source: WebCon.WorkFlow
    [OK]   OTLP source: Portal
    [OK]   webcon_* metrics present
    [OK]   mssql exporter: up
==> Alerts
    [OK]   Alert rules loaded: 30
Result: OK
```

- `OTLP source: Portal` appears only after the first visit to the Portal after the restart (IIS starts the application on the first request). Open the Portal in a browser and repeat the test after 2 minutes – WEBCON sends metrics every 60 s.
- A `[WARN]` about the Loki “pattern ingester” is only a warning – it can last up to 2 h after startup.
- Other problems: [Troubleshooting](07-troubleshooting.md).

## Step 6. Sign in to Grafana

1. Open <http://localhost:3000>.
2. User `admin`, password from step 3. If you do not have it, read it in PowerShell as administrator:

   ```powershell
   Get-Content C:\Observability\secrets\grafana-admin.txt
   ```

3. You will see the **Start** home screen – WEBCON status at a glance, links, and firing alerts. All dashboards: menu (☰) → **Dashboards**, in folders:

   | Folder | Dashboard | Where to start |
   |---|---|---|
   | `webcon` | **WEBCON – Performance** | current performance: Portal, forms, paths, business rules, SQL, Service |
   | `webcon` | **WEBCON – Operations** | weekly overview: most frequent actions and paths, tasks, external APIs |
   | `webcon` | **WEBCON – Availability and backlog** | Portal availability (`/health` probe) and backlog in the content database |
   | `sql` | **SQL Server – WEBCON** | database load and problems |
   | `host` | **Windows – Host load** | CPU, memory, disks, processes |

The first meaningful charts appear after users have worked in WEBCON for a dozen or so minutes. How to read the dashboards: [Grafana in 10 minutes](../user-guide/01-grafana-in-10-minutes.md).

## Next steps

- Other Grafana users: menu → **Administration → Users and access → Users → New user** (the *Viewer* role is enough for viewing).
- Access to Grafana from other computers: reinstall with `-GrafanaListenAll` ([Upgrade](05-upgrade.md#changing-parameters)).
- After a WEBCON upgrade: run `C:\Observability\app\scripts\Set-WebconTelemetry.ps1` again ([Upgrade](05-upgrade.md#after-a-webcon-upgrade)).
- New stack version: [Upgrade](05-upgrade.md).
