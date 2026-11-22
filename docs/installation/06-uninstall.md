# Uninstall

## Order

1. **Disable telemetry in WEBCON** – otherwise WEBCON will keep trying to send data to `localhost:4318` (no impact on how WEBCON works, but with export errors in the logs).
2. **Remove the stack** (`Uninstall-ObservabilityStack.ps1`).
3. (optional) **Remove the SQL logins**.

## 1. WEBCON – restoring the configuration

Restore the backup copies of the files from before the first run of `Set-WebconTelemetry.ps1` (the oldest `*.bak-*`) – procedure: [WEBCON configuration → Reverting the changes](03-webcon-configuration.md#reverting-the-changes). Files:

| Directory (default: `C:\Program Files\WEBCON\…`) | Files |
|---|---|
| `WEBCON BPS Portal` | `appsettings.Production.json`, `web.config` |
| `WEBCON BPS WorkFlow Service` | `appsettings.Production.json` |

The `OTEL_*` variables of the Service are in the service registry key – remove them if you restore the configuration manually:

```powershell
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebCon WorkFlow Service'
(Get-ItemProperty $key).Environment      # preview
Remove-ItemProperty $key -Name Environment   # only when it contains just the OTEL_* variables added by the script
Restart-Service 'WebCon WorkFlow Service'
```

A simpler alternative without restoring files: in `appsettings.Production.json` of the Portal and the Service, set `OpenTelemetry › Metrics / Tracing / Logs › Enabled = false` and restart WEBCON.

## 2. Removing the stack

PowerShell as administrator, in the `C:\Observability\app` directory (copy of the scripts of the installed version) or in the package directory:

```powershell
# services and firewall rules; data, configuration and secrets REMAIN in C:\Observability
.\Uninstall-ObservabilityStack.ps1

# everything, including data and passwords (irreversible)
.\Uninstall-ObservabilityStack.ps1 -RemoveFiles
```

| Variant | When | What remains |
|---|---|---|
| without `-RemoveFiles` | temporary shutdown, relocation, reinstallation keeping the history | `C:\Observability` (data, secrets, `install-settings.json`). Running `Install-ObservabilityStack.ps1` again restores the previous configuration and data |
| with `-RemoveFiles` | permanent removal, clean reinstallation | nothing – a new installation requires the SQL logins and passwords again; Grafana gets a **new** `admin` password |

Preview without changes: `-WhatIf`.

**`-RemoveFiles` safeguards:**

- the installation directory contains a git repository (e.g. cloned into `C:\Observability\...`) – the script **refuses** to remove it; move the repository and run the script again,
- the installation directory contains files other than the stack (`bin`, `config`, `data`, `logs`, `services`, `secrets`, `downloads`, `app`, `agent-bundle`) – the script lists them and asks for confirmation; `-Force` skips the prompt.

**Clean reinstallation** (e.g. to test a new version): `Uninstall-ObservabilityStack.ps1 -RemoveFiles`, then [Quick start, step 3](01-quick-start.md#step-3-run-the-installer). The WEBCON configuration does not need to be changed – the `localhost:4318` address stays the same.

## 3. SQL logins (optional)

The scripts do not remove the logins. DBA:

```sql
DROP LOGIN [svc_obs_mssql_exporter];
-- in each WEBCON content database:
USE [WEBCON_Content]; DROP USER IF EXISTS [svc_obs_grafana_reader];
DROP LOGIN [svc_obs_grafana_reader];
```

## Remote mode – removing the agent

On each WEBCON / SQL host (PowerShell as administrator, in `C:\Observability\app` – copy of the agent scripts; the agent bundle is not needed):

```powershell
.\Uninstall-ObservabilityAgent.ps1               # obs-alloy service
.\Uninstall-ObservabilityAgent.ps1 -RemoveFiles  # also C:\Observability on the host
```

The script also removes the `Observability - SQL (Grafana)` firewall rule on the SQL host. It does not change the WEBCON configuration (step 1 – on the WEBCON host) or the SQL logins (it prints the `DROP LOGIN` commands).

On the stack VM: `Uninstall-ObservabilityStack.ps1` also removes the `Observability - Agenci` rule.
