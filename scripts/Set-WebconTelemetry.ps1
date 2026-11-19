#Requires -Version 5.1
<#
.SYNOPSIS
    Konfiguruje OpenTelemetry w WEBCON 2026.2+ (Portal, Serwis) - eksport OTLP/HTTP do lokalnego Alloy.

.DESCRIPTION
    Modyfikuje sekcję "OpenTelemetry" w plikach appsettings(.Production).json WEBCON:
      - Metrics / Tracing / Logs: Enabled = true
      - Exporters.<nazwa> -> http://localhost:4318/v1/{metrics|traces|logs}, Protocol = http
        (nazwy jak w przykładach WEBCON 2026: Metrics/Tracing -> "Otlp", Logs -> "Loki"; zmiana: -*ExporterName)
      - pozostałe eksportery w tych sekcjach -> Enabled = false (chyba że -KeepOtherExporters)
      - SqlTracing zgodnie z -SqlTracing
    Ustawia zmienne OTEL_SPAN_EVENT_COUNT_LIMIT, OTEL_METRICS_EXEMPLAR_FILTER i OTEL_RESOURCE_ATTRIBUTES
    (znacznik komponentu webcon.component = service / portal; istniejące atrybuty są zachowywane):
      - usługi Windows WEBCON (Serwis) - rejestr usługi; wykrywane są tylko usługi z exe w katalogu zmienianego appsettings
      - Portal pod IIS - web.config (<aspNetCore><environmentVariables>); zapis restartuje aplikację
    Znacznik pozwala Alloy nadać stałe nazwy usług ("Portal", "WebCon.WorkFlow") niezależnie od ServiceName
    w appsettings - docs/projekt/projekt-nazwy-uslug-webcon.md.
    Przed każdą zmianą tworzy kopię pliku (*.bak-<timestamp>). Upgrade WEBCON może nadpisać pliki -
    wtedy uruchom skrypt ponownie.

    Logi przez OTLP eksportuje Portal i (od 2026.2) Serwis; starsze wersje Serwisu - pliki Serilog (-ServiceLogPath instalatora).

.PARAMETER AppSettingsPath
    Pliki do zmiany. Brak = wyszukanie plików z sekcją "OpenTelemetry" w -SearchRoot.

.PARAMETER SearchRoot
    Katalogi przeszukiwane przy braku -AppSettingsPath. Domyślnie <Program Files>\WEBCON i <Program Files (x86)>\WEBCON
    (istniejące).

.PARAMETER SqlTracing
    Threshold - SQL tracing włączony, krótkie spany odrzuca Alloy (próg z instalacji, domyślnie 1 s)
    All       - SQL tracing włączony, bez filtrowania (próg instalatora = 0)
    Off       - SQL tracing wyłączony w WEBCON

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
                if ($p.Value.Enabled) { Write-Info "  wyłączam eksporter $($p.Name)" }
                $p.Value.Enabled = $false
            }
        }
    }
    $exporter = [ordered]@{
        Enabled  = $true
        Endpoint = "$OtlpEndpoint$Path"
        Protocol = 'http'
    }
    # Bez pustego Headers: WEBCON 2026.2.5 nie startuje przy "Headers": "" (IndexOutOfRangeException przy budowaniu hosta)
    $old = $exporters.PSObject.Properties[$ExporterName]
    if ($old -and $old.Value -is [System.Management.Automation.PSCustomObject] -and $old.Value.PSObject.Properties['Headers'] -and $old.Value.Headers) {
        $exporter.Headers = $old.Value.Headers
    }
    Set-JsonProperty -Object $exporters -Name $ExporterName -Value ([pscustomobject]$exporter)
}

# OTEL_RESOURCE_ATTRIBUTES: lista klucz=wartość rozdzielona przecinkami - ustawia webcon.component, resztę zachowuje
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
Write-Step 'Pliki konfiguracyjne WEBCON'
if (-not $AppSettingsPath) {
    if (-not $SearchRoot) {
        # WEBCON bywa instalowany w Program Files (x86) (zweryfikowano 2026.2.5 na Windows Server 2019)
        $SearchRoot = @($env:ProgramFiles, ${env:ProgramFiles(x86)} | Where-Object { $_ } | Select-Object -Unique |
            ForEach-Object { Join-Path $_ 'WEBCON' })
    }
    $roots = @($SearchRoot | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $roots) { throw "Brak katalogu $($SearchRoot -join ', ') - podaj -AppSettingsPath lub -SearchRoot." }
    Write-Info "Przeszukiwane: $($roots -join ', ')"
    # Filtr nazw w Where-Object: PS 5.1 ignoruje -Include razem z -LiteralPath (czytałby wszystkie pliki, np. zablokowane indeksy Solr)
    $candidates = Get-ChildItem -LiteralPath $roots -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -eq 'appsettings.json' -or $_.Name -eq 'appsettings.Production.json') -and $_.FullName -notmatch '\\(bin|obj)\\' } |
        Where-Object { Select-String -LiteralPath $_.FullName -Pattern '"OpenTelemetry"' -SimpleMatch -Quiet -ErrorAction SilentlyContinue }
    # Jeśli w katalogu jest appsettings.Production.json z sekcją OpenTelemetry - zmieniamy tylko jego (nadpisuje bazowy)
    $byDir = $candidates | Group-Object DirectoryName
    $AppSettingsPath = foreach ($g in $byDir) {
        $prod = $g.Group | Where-Object Name -eq 'appsettings.Production.json'
        if ($prod) { $prod.FullName } else { $g.Group[0].FullName }
    }
    if (-not $AppSettingsPath) { throw "Nie znaleziono plików appsettings z sekcją OpenTelemetry w $($roots -join ', ')." }
    Write-Info 'Znalezione pliki:'
    $AppSettingsPath | ForEach-Object { Write-Info "  $_" }
    if (-not $Force -and -not $WhatIfPreference) {
        $answer = Read-Host 'Zmienić powyższe pliki? (T/N)'
        if ($answer -notmatch '^(t|y)') { Write-Warn 'Przerwano.'; return }
    }
}

$stamp = Get-Date -Format 'yyyyMMddHHmmss'
foreach ($file in $AppSettingsPath) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Brak pliku $file" }
    Write-Step $file
    $bytes = [IO.File]::ReadAllBytes($file)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        throw "Nie można sparsować $file (komentarze / przecinki końcowe?). Popraw plik lub uruchom w PowerShell 7. Błąd: $($_.Exception.Message)"
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
    if ($PSCmdlet.ShouldProcess($file, 'Zapis sekcji OpenTelemetry')) {
        Copy-Item -LiteralPath $file -Destination "$file.bak-$stamp" -Force
        $enc = New-Object System.Text.UTF8Encoding($hasBom)
        [IO.File]::WriteAllText($file, $out, $enc)
        Write-Ok "Zapisano (kopia: $file.bak-$stamp)"
    }
}

# ---------------------------------------------------------------------
$envVars = [ordered]@{
    OTEL_SPAN_EVENT_COUNT_LIMIT  = '10240'
    OTEL_METRICS_EXEMPLAR_FILTER = 'trace_based'
}
$configDirs = @($AppSettingsPath | ForEach-Object { (Split-Path -Parent (Resolve-Path -LiteralPath $_).Path).TrimEnd('\') })

# Usługi WEBCON, których exe leży w katalogu zmienianego appsettings (np. Serwis; bez Search Service itp.)
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

# Aplikacje pod IIS (ASP.NET Core Module): katalogi bez usługi Windows z web.config zawierającym <aspNetCore>.
# Zmienne OTEL_* trafiają do <environmentVariables>; zapis web.config restartuje aplikację (bez iisreset).
if (-not $SkipServiceEnvironment) {
    foreach ($dir in ($configDirs | Where-Object { $serviceDirs -notcontains $_ })) {
        $webConfig = Join-Path $dir 'web.config'
        if (-not (Test-Path -LiteralPath $webConfig)) { continue }
        $xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $true
        $xml.Load($webConfig)
        $anc = $xml.SelectSingleNode('/configuration/system.webServer/aspNetCore')
        if (-not $anc -or $anc.GetAttribute('processPath') -like '%LAUNCHER_PATH%') { continue }
        Write-Step "Zmienne środowiskowe IIS: $webConfig"
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
        # Aplikacja IIS = Portal (Serwis to usługa Windows)
        $ra = $envNode.SelectSingleNode("environmentVariable[@name='OTEL_RESOURCE_ATTRIBUTES']")
        if (-not $ra) {
            $ra = $envNode.AppendChild($xml.CreateElement('environmentVariable'))
            $ra.SetAttribute('name', 'OTEL_RESOURCE_ATTRIBUTES')
        }
        $ra.SetAttribute('value', (Merge-ResourceAttribute -Current $ra.GetAttribute('value') -Component 'portal'))
        if ($PSCmdlet.ShouldProcess($webConfig, 'Ustawienie zmiennych OTEL_* (restart aplikacji IIS)')) {
            Copy-Item -LiteralPath $webConfig -Destination "$webConfig.bak-$stamp" -Force
            $xml.Save($webConfig)
            Write-Ok "$($envVars.Keys -join ', '), OTEL_RESOURCE_ATTRIBUTES ($($ra.GetAttribute('value'))) (kopia: $webConfig.bak-$stamp)"
        }
    }
}

if (-not $SkipServiceEnvironment -and $WebconServiceName) {
    Write-Step 'Zmienne środowiskowe usług WEBCON'
    foreach ($svc in $WebconServiceName) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        if (-not (Test-Path $key)) { Write-Warn "Brak usługi $svc"; continue }
        $current = @()
        $prop = Get-ItemProperty -Path $key -Name 'Environment' -ErrorAction SilentlyContinue
        if ($prop) { $current = @($prop.Environment) }
        $map = [ordered]@{}
        foreach ($line in $current) { if ($line -match '^([^=]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] } }
        foreach ($k in $envVars.Keys) { $map[$k] = $envVars[$k] }
        $map['OTEL_RESOURCE_ATTRIBUTES'] = Merge-ResourceAttribute -Current $map['OTEL_RESOURCE_ATTRIBUTES'] -Component 'service'
        $newValue = @($map.Keys | ForEach-Object { "$_=$($map[$_])" })
        if ($PSCmdlet.ShouldProcess($svc, 'Ustawienie zmiennych OTEL_*')) {
            New-ItemProperty -Path $key -Name 'Environment' -PropertyType MultiString -Value $newValue -Force | Out-Null
            Write-Ok "$svc : $($envVars.Keys -join ', '), OTEL_RESOURCE_ATTRIBUTES ($($map['OTEL_RESOURCE_ATTRIBUTES']))"
        }
    }
} elseif (-not $WebconServiceName) {
    Write-Warn 'Nie wykryto usług WEBCON - pomijam zmienne środowiskowe i restart (podaj -WebconServiceName).'
}

# ---------------------------------------------------------------------
if (-not $NoRestart) {
    Write-Step 'Restart WEBCON'
    foreach ($svc in $WebconServiceName) {
        if ($PSCmdlet.ShouldProcess($svc, 'Restart-Service')) {
            Restart-Service -Name $svc -Force
            Write-Ok "Zrestartowano $svc"
        }
    }
    if ($RestartIis -and $PSCmdlet.ShouldProcess('IIS', 'iisreset')) {
        & iisreset.exe | Out-Null
        Write-Ok 'iisreset wykonany'
    }
} else {
    Write-Warn 'Pominięto restart - zmiany zadziałają po restarcie Portalu/Serwisu.'
}
