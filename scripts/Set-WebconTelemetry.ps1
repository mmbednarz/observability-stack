#Requires -Version 5.1
<#
.SYNOPSIS
    Configures OpenTelemetry in WEBCON 2026.2+ (Portal, Service) - OTLP/HTTP export to the local Alloy.

.DESCRIPTION
    Modifies the "OpenTelemetry" section in the WEBCON appsettings(.Production).json files:
      - Metrics / Tracing / Logs: Enabled = true
      - Exporters.<name> -> http://localhost:4318/v1/{metrics|traces|logs}, Protocol = http
        (names as in the WEBCON 2026 examples: Metrics/Tracing -> "Otlp", Logs -> "Loki"; to change: -*ExporterName)
      - other exporters in these sections -> Enabled = false (unless -KeepOtherExporters)
      - SqlTracing according to -SqlTracing
    Sets the OTEL_SPAN_EVENT_COUNT_LIMIT, OTEL_METRICS_EXEMPLAR_FILTER and OTEL_RESOURCE_ATTRIBUTES variables
    (component marker webcon.component = service / portal; existing attributes are preserved):
      - WEBCON Windows services (Service) - service registry key; only services whose exe is in the folder of a modified appsettings file are detected
      - Portal under IIS - web.config (<aspNetCore><environmentVariables>); saving it restarts the application
    The marker lets Alloy assign fixed service names ("Portal", "WebCon.WorkFlow") regardless of ServiceName
    in appsettings - docs/projekt/projekt-nazwy-uslug-webcon.md.
    Before each change, creates a backup copy of the file (*.bak-<timestamp>). A WEBCON upgrade may overwrite the files -
    in that case run the script again.

    Logs are exported over OTLP by the Portal and (since 2026.2) the Service; older Service versions - Serilog files (installer -ServiceLogPath).

.PARAMETER AppSettingsPath
    Files to change. If omitted, files with an "OpenTelemetry" section are searched for in -SearchRoot.

.PARAMETER SearchRoot
    Folders searched when -AppSettingsPath is omitted. Default: <Program Files>\WEBCON and <Program Files (x86)>\WEBCON
    (those that exist).

.PARAMETER SqlTracing
    Threshold - SQL tracing enabled, Alloy drops short spans (threshold from the installation, default 1 s)
    All       - SQL tracing enabled, no filtering (installer threshold = 0)
    Off       - SQL tracing disabled in WEBCON

.EXAMPLE
    .\scripts\Set-WebconTelemetry.ps1 -WhatIf
.EXAMPLE
    .\scripts\Set-WebconTelemetry.ps1 -AppSettingsPath 'C:\Program Files\WEBCON\WEBCON BPS Portal\appsettings.Production.json' -SqlTracing Off
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$AppSettingsPath,
    [string[]]$SearchRoot,
    [string]$OtlpEndpoint = 'http://localhost:4318',
    [ValidateSet('Threshold', 'All', 'Off')][string]$SqlTracing = 'Threshold',
    [string]$MetricsExporterName = 'Otlp',
    [string]$TracingExporterName = 'Otlp',
    [string]$LogsExporterName = 'Loki',
    [switch]$KeepOtherExporters,
    [switch]$DisableLogs,
    [string[]]$WebconServiceName,
    [switch]$SkipServiceEnvironment,
    [switch]$NoRestart,
    [switch]$RestartIis,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'modules\ObservabilityStack.psm1') -Force -DisableNameChecking
Assert-Administrator

$OtlpEndpoint = $OtlpEndpoint.TrimEnd('/')

# ---------------------------------------------------------------------
function Set-JsonProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-OrCreateObject {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value -or $p.Value -isnot [System.Management.Automation.PSCustomObject]) {
        Set-JsonProperty -Object $Object -Name $Name -Value ([pscustomobject]@{})
    }
    return $Object.$Name
}

function Set-SignalExporter {
    param([Parameter(Mandatory)]$Signal, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExporterName)
    $exporters = Get-OrCreateObject -Object $Signal -Name 'Exporters'
    if (-not $KeepOtherExporters) {
        foreach ($p in @($exporters.PSObject.Properties)) {
            if ($p.Name -ne $ExporterName -and $p.Value -is [System.Management.Automation.PSCustomObject] -and $p.Value.PSObject.Properties['Enabled']) {
                if ($p.Value.Enabled) { Write-Info "  disabling exporter $($p.Name)" }
                $p.Value.Enabled = $false
            }
        }
    }
    $exporter = [ordered]@{
        Enabled  = $true
        Endpoint = "$OtlpEndpoint$Path"
        Protocol = 'http'
    }
    # No empty Headers: WEBCON 2026.2.5 fails to start with "Headers": "" (IndexOutOfRangeException while building the host)
    $old = $exporters.PSObject.Properties[$ExporterName]
    if ($old -and $old.Value -is [System.Management.Automation.PSCustomObject] -and $old.Value.PSObject.Properties['Headers'] -and $old.Value.Headers) {
        $exporter.Headers = $old.Value.Headers
    }
    Set-JsonProperty -Object $exporters -Name $ExporterName -Value ([pscustomobject]$exporter)
}

# OTEL_RESOURCE_ATTRIBUTES: comma-separated key=value list - sets webcon.component, keeps the rest
function Merge-ResourceAttribute {
    param([string]$Current, [Parameter(Mandatory)][string]$Component)
    $pairs = [ordered]@{}
    if ($Current) {
        foreach ($p in ($Current -split ',')) {
            if ($p.Trim() -match '^([^=]+)=(.*)$') { $pairs[$Matches[1].Trim()] = $Matches[2].Trim() }
        }
    }
    $pairs['webcon.component'] = $Component
    return (@($pairs.Keys | ForEach-Object { "$_=$($pairs[$_])" }) -join ',')
}

# ---------------------------------------------------------------------
Write-Step 'WEBCON configuration files'
if (-not $AppSettingsPath) {
    if (-not $SearchRoot) {
        # WEBCON is sometimes installed in Program Files (x86) (verified with 2026.2.5 on Windows Server 2019)
        $SearchRoot = @($env:ProgramFiles, ${env:ProgramFiles(x86)} | Where-Object { $_ } | Select-Object -Unique |
            ForEach-Object { Join-Path $_ 'WEBCON' })
    }
    $roots = @($SearchRoot | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $roots) { throw "Folder $($SearchRoot -join ', ') not found - specify -AppSettingsPath or -SearchRoot." }
    Write-Info "Searching: $($roots -join ', ')"
    # Name filter in Where-Object: PS 5.1 ignores -Include together with -LiteralPath (it would read all files, e.g. locked Solr indexes)
    $candidates = Get-ChildItem -LiteralPath $roots -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -eq 'appsettings.json' -or $_.Name -eq 'appsettings.Production.json') -and $_.FullName -notmatch '\\(bin|obj)\\' } |
        Where-Object { Select-String -LiteralPath $_.FullName -Pattern '"OpenTelemetry"' -SimpleMatch -Quiet -ErrorAction SilentlyContinue }
    # If the folder contains appsettings.Production.json with an OpenTelemetry section - change only that file (it overrides the base one)
    $byDir = $candidates | Group-Object DirectoryName
    $AppSettingsPath = foreach ($g in $byDir) {
        $prod = $g.Group | Where-Object Name -eq 'appsettings.Production.json'
        if ($prod) { $prod.FullName } else { $g.Group[0].FullName }
    }
    if (-not $AppSettingsPath) { throw "No appsettings files with an OpenTelemetry section found in $($roots -join ', ')." }
    Write-Info 'Files found:'
    $AppSettingsPath | ForEach-Object { Write-Info "  $_" }
    if (-not $Force -and -not $WhatIfPreference) {
        $answer = Read-Host 'Change the files listed above? (Y/N)'
        if ($answer -notmatch '^(t|y)') { Write-Warn 'Cancelled.'; return }
    }
}

$stamp = Get-Date -Format 'yyyyMMddHHmmss'
foreach ($file in $AppSettingsPath) {
    if (-not (Test-Path -LiteralPath $file)) { throw "File $file not found" }
    Write-Step $file
    $bytes = [IO.File]::ReadAllBytes($file)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        throw "Cannot parse $file (comments / trailing commas?). Fix the file or run in PowerShell 7. Error: $($_.Exception.Message)"
    }

    $otel = Get-OrCreateObject -Object $json -Name 'OpenTelemetry'

    $metrics = Get-OrCreateObject -Object $otel -Name 'Metrics'
    Set-JsonProperty $metrics 'Enabled' $true
    Set-SignalExporter -Signal $metrics -Path '/v1/metrics' -ExporterName $MetricsExporterName

    $tracing = Get-OrCreateObject -Object $otel -Name 'Tracing'
    Set-JsonProperty $tracing 'Enabled' $true
    Set-JsonProperty $tracing 'ShowExceptions' $true
    Set-JsonProperty $tracing 'HttpTracing' $true
    $sql = Get-OrCreateObject -Object $tracing -Name 'SqlTracing'
    $sqlOn = ($SqlTracing -ne 'Off')
    Set-JsonProperty $sql 'Enabled' $sqlOn
    Set-JsonProperty $sql 'ShowDbStatements' $sqlOn
    Set-SignalExporter -Signal $tracing -Path '/v1/traces' -ExporterName $TracingExporterName

    $logs = Get-OrCreateObject -Object $otel -Name 'Logs'
    Set-JsonProperty $logs 'Enabled' (-not $DisableLogs)
    Set-SignalExporter -Signal $logs -Path '/v1/logs' -ExporterName $LogsExporterName

    $out = $json | ConvertTo-Json -Depth 64
    if ($PSCmdlet.ShouldProcess($file, 'Save OpenTelemetry section')) {
        Copy-Item -LiteralPath $file -Destination "$file.bak-$stamp" -Force
        $enc = New-Object System.Text.UTF8Encoding($hasBom)
        [IO.File]::WriteAllText($file, $out, $enc)
        Write-Ok "Saved (backup: $file.bak-$stamp)"
    }
}

# ---------------------------------------------------------------------
$envVars = [ordered]@{
    OTEL_SPAN_EVENT_COUNT_LIMIT  = '10240'
    OTEL_METRICS_EXEMPLAR_FILTER = 'trace_based'
}
$configDirs = @($AppSettingsPath | ForEach-Object { (Split-Path -Parent (Resolve-Path -LiteralPath $_).Path).TrimEnd('\') })

# WEBCON services whose exe is in the folder of a modified appsettings file (e.g. the Service; excludes Search Service etc.)
$serviceDirs = @()
if (-not $WebconServiceName) {
    $WebconServiceName = @(Get-CimInstance Win32_Service | Where-Object {
        ($_.Name -like '*webcon*' -or $_.DisplayName -like '*WEBCON*') -and $_.Name -notlike 'obs-*' -and
        $_.PathName -match '^"?([^"]+\.exe)' -and ($configDirs -contains (Split-Path -Parent $Matches[1]).TrimEnd('\'))
    } | Select-Object -ExpandProperty Name)
}
foreach ($svc in $WebconServiceName) {
    $img = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if ($img -match '^"?([^"]+\.exe)') { $serviceDirs += (Split-Path -Parent $Matches[1]).TrimEnd('\') }
}

# Applications under IIS (ASP.NET Core Module): folders without a Windows service, with a web.config containing <aspNetCore>.
# OTEL_* variables go to <environmentVariables>; saving web.config restarts the application (no iisreset).
if (-not $SkipServiceEnvironment) {
    foreach ($dir in ($configDirs | Where-Object { $serviceDirs -notcontains $_ })) {
        $webConfig = Join-Path $dir 'web.config'
        if (-not (Test-Path -LiteralPath $webConfig)) { continue }
        $xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $true
        $xml.Load($webConfig)
        $anc = $xml.SelectSingleNode('/configuration/system.webServer/aspNetCore')
        if (-not $anc -or $anc.GetAttribute('processPath') -like '%LAUNCHER_PATH%') { continue }
        Write-Step "IIS environment variables: $webConfig"
        $envNode = $anc.SelectSingleNode('environmentVariables')
        if (-not $envNode) { $envNode = $anc.AppendChild($xml.CreateElement('environmentVariables')) }
        foreach ($k in $envVars.Keys) {
            $var = $envNode.SelectSingleNode("environmentVariable[@name='$k']")
            if (-not $var) {
                $var = $envNode.AppendChild($xml.CreateElement('environmentVariable'))
                $var.SetAttribute('name', $k)
            }
            $var.SetAttribute('value', $envVars[$k])
        }
        # IIS application = Portal (the Service is a Windows service)
        $ra = $envNode.SelectSingleNode("environmentVariable[@name='OTEL_RESOURCE_ATTRIBUTES']")
        if (-not $ra) {
            $ra = $envNode.AppendChild($xml.CreateElement('environmentVariable'))
            $ra.SetAttribute('name', 'OTEL_RESOURCE_ATTRIBUTES')
        }
        $ra.SetAttribute('value', (Merge-ResourceAttribute -Current $ra.GetAttribute('value') -Component 'portal'))
        if ($PSCmdlet.ShouldProcess($webConfig, 'Set OTEL_* variables (restarts the IIS application)')) {
            Copy-Item -LiteralPath $webConfig -Destination "$webConfig.bak-$stamp" -Force
            $xml.Save($webConfig)
            Write-Ok "$($envVars.Keys -join ', '), OTEL_RESOURCE_ATTRIBUTES ($($ra.GetAttribute('value'))) (backup: $webConfig.bak-$stamp)"
        }
    }
}

if (-not $SkipServiceEnvironment -and $WebconServiceName) {
    Write-Step 'WEBCON service environment variables'
    foreach ($svc in $WebconServiceName) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        if (-not (Test-Path $key)) { Write-Warn "Service $svc not found"; continue }
        $current = @()
        $prop = Get-ItemProperty -Path $key -Name 'Environment' -ErrorAction SilentlyContinue
        if ($prop) { $current = @($prop.Environment) }
        $map = [ordered]@{}
        foreach ($line in $current) { if ($line -match '^([^=]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] } }
        foreach ($k in $envVars.Keys) { $map[$k] = $envVars[$k] }
        $map['OTEL_RESOURCE_ATTRIBUTES'] = Merge-ResourceAttribute -Current $map['OTEL_RESOURCE_ATTRIBUTES'] -Component 'service'
        $newValue = @($map.Keys | ForEach-Object { "$_=$($map[$_])" })
        if ($PSCmdlet.ShouldProcess($svc, 'Set OTEL_* variables')) {
            New-ItemProperty -Path $key -Name 'Environment' -PropertyType MultiString -Value $newValue -Force | Out-Null
            Write-Ok "$svc : $($envVars.Keys -join ', '), OTEL_RESOURCE_ATTRIBUTES ($($map['OTEL_RESOURCE_ATTRIBUTES']))"
        }
    }
} elseif (-not $WebconServiceName) {
    Write-Warn 'No WEBCON services detected - skipping environment variables and restart (specify -WebconServiceName).'
}

# ---------------------------------------------------------------------
if (-not $NoRestart) {
    Write-Step 'Restart WEBCON'
    foreach ($svc in $WebconServiceName) {
        if ($PSCmdlet.ShouldProcess($svc, 'Restart-Service')) {
            Restart-Service -Name $svc -Force
            Write-Ok "Restarted $svc"
        }
    }
    if ($RestartIis -and $PSCmdlet.ShouldProcess('IIS', 'iisreset')) {
        & iisreset.exe | Out-Null
        Write-Ok 'iisreset completed'
    }
} else {
    Write-Warn 'Restart skipped - changes take effect after the Portal/Service is restarted.'
}
