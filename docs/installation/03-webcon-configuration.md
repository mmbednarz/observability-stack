# WEBCON configuration (`Set-WebconTelemetry.ps1`)

WEBCON 2026.2+ has built-in OpenTelemetry support, but it does not send any data by default. The `scripts\Set-WebconTelemetry.ps1` script enables export to the local Alloy (`http://localhost:4318`).

## What the script changes

1. In `C:\Program Files\WEBCON` and `C:\Program Files (x86)\WEBCON`, it finds the `appsettings.json` / `appsettings.Production.json` files with an `OpenTelemetry` section (usually the Portal and the Service). When a directory contains `appsettings.Production.json`, only that file is changed.
2. In the `OpenTelemetry` section, it:
   - enables `Metrics`, `Tracing`, `Logs`,
   - sets the OTLP/HTTP exporter to `http://localhost:4318/v1/metrics|traces|logs`,
   - disables other exporters in these sections (unless `-KeepOtherExporters` is specified),
   - enables SQL query tracing (`SqlTracing`) – short queries are then dropped by Alloy (by default < 1 s).
3. It sets the `OTEL_*` environment variables (metric exemplars, span event limit) and the component marker `OTEL_RESOURCE_ATTRIBUTES=webcon.component=…` (other attributes in this variable are kept):
   - Service – in the Windows service registry key (`webcon.component=service`),
   - Portal (IIS) – in `web.config` (`<aspNetCore><environmentVariables>`, `webcon.component=portal`).

   Based on the marker, Alloy assigns the services the fixed names `Portal` and `WebCon.WorkFlow`, which are used by the dashboards and alerts – regardless of `ServiceName` in the WEBCON appsettings (it can differ between installations). The name from WEBCON is kept in the `webcon.service.name.original` attribute.
4. It restarts the WEBCON WorkFlow Service; saving `web.config` restarts the Portal application.

Before each change, it creates a backup copy of the file: `appsettings.Production.json.bak-20261106101500`, `web.config.bak-…`.

## Usage

```powershell
# preview – changes nothing
.\scripts\Set-WebconTelemetry.ps1 -WhatIf

# apply (asks for confirmation, restarts WEBCON)
.\scripts\Set-WebconTelemetry.ps1
```

| Parameter | When to use |
|---|---|
| `-SqlTracing Threshold` (default) / `All` / `Off` | SQL query tracing: slow (installer threshold), all, disabled. `All` also requires the installer with `-SqlSpanThresholdSeconds 0` |
| `-AppSettingsPath <file>` | change only selected files |
| `-SearchRoot <directory>` | WEBCON in a non-standard directory (default: `Program Files\WEBCON` and `Program Files (x86)\WEBCON`) |
| `-NoRestart` | change without a restart – takes effect after the next WEBCON restart |
| `-RestartIis` | full `iisreset` instead of restarting only the application |
| `-Force` | no confirmation prompt (automated scripts) |
| `-DisableLogs` | do not send logs |

The installer can run the script itself: `Install-ObservabilityStack.ps1 … -ConfigureWebcon`.

## Verification

- `.\Test-ObservabilityStack.ps1` → section “WEBCON and host data”: `OTLP source: WebCon.WorkFlow` (Service), `OTLP source: Portal` and `WEBCON service names normalized (webcon.component)`.
- `[WARN] WEBCON service with a non-standard name …` or `… telemetry without the webcon.component marker` – WEBCON sends telemetry without the marker (e.g. configured manually). Run the script again; when that is not possible, use the fallback name-based mapping: the installer with `-WebconPortalServiceName` / `-WebconServiceServiceName` ([parameters](08-installer-parameters.md)).
- The Portal appears only after the first request (open the Portal in a browser); WEBCON metrics arrive every 60 s.

## Reverting the changes

Restore the backup copies and restart WEBCON:

```powershell
$dir = 'C:\Program Files\WEBCON\WEBCON BPS WorkFlow Service'
Get-ChildItem $dir -Filter 'appsettings.Production.json.bak-*' | Sort-Object Name | Select-Object -Last 1 |
    Copy-Item -Destination (Join-Path $dir 'appsettings.Production.json') -Force
Restart-Service 'WebCon WorkFlow Service'
```

Do the same for the Portal directory (`WEBCON BPS Portal`: `appsettings.Production.json` and `web.config`). If the script was run several times, choose the backup copy from before the **first** run (the oldest one).

## Known issues in WEBCON 2026.2.5

| Symptom | Cause / workaround |
|---|---|
| WEBCON does not start after manually editing appsettings | `"Headers": ""` in an exporter breaks the startup (IndexOutOfRangeException) – the script never writes an empty `Headers`. |
| Every log entry appears twice | a second sink with the default configuration sends logs as `unknown_service:…` – Alloy drops them. |
| Database connection details in traces | Alloy removes the `webcon.db.cs` attribute (database connection details) from spans; the smoke test checks this. |
| The Service does not start within 30 s (event 7009) | the Service startup can be close to the SCM limit – this also happens without telemetry; start it again |
