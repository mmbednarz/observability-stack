#Requires -Version 5.1
<#
.SYNOPSIS
    Instaluje agenta Grafana Alloy na hoście WEBCON i/lub SQL Server i kieruje metryki, ślady i logi do stosu centralnego.

.DESCRIPTION
    Uruchamiany z paczki agent-bundle, którą generuje Install-ObservabilityStack.ps1 z -WebconHost / -SqlHost
    (zwykle przez wygenerowane skrypty 01-* / 02-*). Skrypt jest idempotentny.

    Obie role:   windows_exporter (metryki hosta), usługa obs-alloy, wyjście do stosu: OTLP gRPC + remote write.
    Rola Sql:    loginy exportera mssql i czytelnika Grafany (hasła z paczki), uprawnienia (sql\*.sql), TCP instancji,
                 exporter mssql (połączenie lokalne), reguła firewall dla Grafany stosu.
    Rola Webcon: OTLP z WEBCON przyjmowany lokalnie (127.0.0.1:4317/4318), filtry Alloy (sekrety, próg SQL, duplikaty logów)
                 przed wysłaniem do sieci, scripts\Set-WebconTelemetry.ps1 (zmiana appsettings + restart WEBCON).

.PARAMETER Role
    Sql, Webcon albo obie (WEBCON i SQL na jednym hoście).

.PARAMETER EnableSqlTcp
    Włącza TCP instancji SQL i ustawia statyczny port z paczki (IPAll). RESTARTUJE INSTANCJĘ SQL.
    Bez przełącznika skrypt przerywa się, gdy TCP jest wyłączone (exporter mssql wymaga TCP także lokalnie).

.PARAMETER SkipWebconConfig
    Bez zmiany konfiguracji WEBCON (appsettings) - tylko agent.

.PARAMETER Force
    Bez pytań przy zmianie appsettings WEBCON (zmiana restartuje WEBCON).

.EXAMPLE
    .\Install-ObservabilityAgent.ps1 -Role Sql -EnableSqlTcp
.EXAMPLE
    .\Install-ObservabilityAgent.ps1 -Role Webcon
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Webcon', 'Sql')][string[]]$Role,
    [string]$Root = 'C:\Observability',
    [string]$SettingsPath = (Join-Path $PSScriptRoot 'agent-settings.json'),
    [switch]$EnableSqlTcp,
    [switch]$SkipWebconConfig,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\modules\ObservabilityStack.psm1') -Force -DisableNameChecking
Assert-Administrator

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    throw "Brak $SettingsPath - uruchom skrypt z katalogu paczki agent-bundle wygenerowanej przez Install-ObservabilityStack.ps1."
}
$Settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Versions = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'versions.psd1')
$Layout   = Get-StackLayout -Root $Root
$Release  = Get-StackRelease -SourceRoot $PSScriptRoot
$IsSql    = $Role -contains 'Sql'
$IsWebcon = $Role -contains 'Webcon'
$ServiceId = 'obs-alloy'

Write-Host ''
Write-Host "Observability Stack (WEBCON) $($Release.Version) - agent ($($Role -join ', '))" -ForegroundColor White
Write-Host "Stos: $($Settings.CentralAddress)   Katalog: $($Layout.Root)" -ForegroundColor White
Write-StackDisclaimer
Write-Host ''
Assert-InstallLocation -SourceRoot $PSScriptRoot -Layout $Layout

# ---------------------------------------------------------------------
Write-Step 'Host'
if (Get-Service -Name 'obs-prometheus' -ErrorAction SilentlyContinue) {
    throw 'Na tym hoście jest stos centralny (obs-prometheus) - agent jest przeznaczony dla hostów WEBCON / SQL.'
}
$expectedHosts = @()
if ($IsSql) { $expectedHosts += $Settings.SqlHost }
if ($IsWebcon) { $expectedHosts += $Settings.WebconHost }
foreach ($h in ($expectedHosts | Where-Object { $_ } | Select-Object -Unique)) {
    if ($h.Split('.')[0] -ne $env:COMPUTERNAME) { Write-Warn "Paczka przygotowana dla hosta $h, a to jest $env:COMPUTERNAME." }
    else { Write-Ok "$env:COMPUTERNAME" }
}

# ---------------------------------------------------------------------
Write-Step "Łączność ze stosem ($($Settings.CentralAddress))"
$blocked = @()
foreach ($p in @($Settings.OtlpPort, $Settings.ReceivePort)) {
    if (Test-TcpEndpoint -HostName $Settings.CentralAddress -Port $p) { Write-Ok "TCP $p" } else { $blocked += $p }
}
if ($blocked) {
    throw ("Brak połączenia z $($Settings.CentralAddress) na portach $($blocked -join ', '). Sprawdź DNS, sieć i firewall VM stosu " +
           "(reguła 'Observability - Agenci' dopuszcza: $($Settings.AgentAddress -join ', ') - inny adres tego hosta = " +
           "Install-ObservabilityStack.ps1 -AgentAddress ...).")
}

# ---------------------------------------------------------------------
Write-Step 'Zatrzymanie agenta (aktualizacja)'
$svc = Get-Service -Name $ServiceId -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Stopped') {
    Stop-Service -Name $ServiceId -Force
    $null = $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    Write-Ok "Zatrzymano $ServiceId"
} else { Write-Ok 'Brak działającego agenta.' }

$busy = @()
foreach ($p in 4317, 4318, 12345) {
    if (Test-TcpPortInUse -Port $p) { $busy += "$p zajęty przez $(Get-PortOwner -Port $p)" }
}
if ($busy) { throw ("Zajęte porty agenta:`n  " + ($busy -join "`n  ")) }

foreach ($k in 'Root', 'Bin', 'Config', 'Data', 'Logs', 'Services', 'Downloads') { New-Directory $Layout[$k] }
Protect-SecretsDirectory -Path $Layout.Secrets

# ---------------------------------------------------------------------
if ($IsSql) {
    Write-Step "SQL Server - instancja $($Settings.SqlInstanceName)"
    $sqlSecrets = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'secrets\sql-logins.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $info = Get-SqlInstanceInfo -InstanceName $Settings.SqlInstanceName
    if ($info.State -ne 'Running') { throw "Usługa $($info.ServiceName) nie działa (stan: $($info.State))." }
    $sqlPort = [int]$Settings.SqlPort
    if ($info.TcpEnabled -and @($info.ListeningPorts) -contains $sqlPort) {
        Write-Ok "TCP włączone, port $sqlPort"
    } elseif ($EnableSqlTcp) {
        Write-Warn "Ustawiam TCP na statycznym porcie $sqlPort i restartuję $($info.ServiceName) - WEBCON chwilowo straci połączenie z bazą."
        Set-SqlTcpStaticPort -Info $info -Port $sqlPort
        $info = Get-SqlInstanceInfo -InstanceName $Settings.SqlInstanceName
        if (@($info.ListeningPorts) -notcontains $sqlPort) {
            throw "Po restarcie instancja nie nasłuchuje na porcie $sqlPort (port zajęty? sprawdź ERRORLOG SQL Server)."
        }
        Write-Ok "TCP włączone, port $sqlPort (instancja zrestartowana)"
    } elseif ($info.TcpEnabled -and @($info.ListeningPorts).Count -gt 0) {
        $sqlPort = [int]@($info.ListeningPorts)[0]
        Write-Warn ("Instancja nasłuchuje na porcie $sqlPort, a stos oczekuje $($Settings.SqlPort) (źródło 'WEBCON SQL' w Grafanie). " +
                    "Exporter użyje portu $sqlPort. Port statyczny: uruchom ponownie z -EnableSqlTcp (restart instancji) " +
                    "albo zainstaluj stos ponownie z -SqlPort $sqlPort.")
    } else {
        throw ("TCP instancji $($Settings.SqlInstanceName) jest wyłączone - exporter mssql i Grafana wymagają TCP. " +
               "Uruchom ponownie z -EnableSqlTcp (włączenie TCP na porcie $sqlPort + RESTART instancji SQL) " +
               "albo włącz TCP w SQL Server Configuration Manager.")
    }

    $adminCs = "Data Source=$($info.DataSource);Initial Catalog=master;Integrated Security=True;Application Name=webcon-observability-agent;Connect Timeout=15"
    $conn = New-Object System.Data.SqlClient.SqlConnection($adminCs)
    try {
        $conn.Open()
        $isSysadmin = [int](Invoke-SqlScalarQuery $conn "SELECT IS_SRVROLEMEMBER('sysadmin')")
        $readerDbExists = $false
        if ($Settings.ReaderLogin) {
            $dbId = Invoke-SqlScalarQuery $conn "SELECT DB_ID(N'$($Settings.WebconContentDatabase.Replace("'", "''"))')"
            $readerDbExists = ($null -ne $dbId -and $dbId -isnot [DBNull])
        }
    } finally { $conn.Dispose() }
    if ($isSysadmin -ne 1) {
        throw "Konto $env:USERDOMAIN\$env:USERNAME nie ma roli sysadmin w $($info.DataSource) - uruchom skrypt kontem DBA albo wykonaj sql\*.sql ręcznie."
    }

    Write-Step 'SQL Server - loginy i uprawnienia'
    # Wartości DECLARE w skryptach sql\*.sql zastępowane nazwami z paczki - skrypty pozostają jedynym źródłem uprawnień
    function Set-SqlDeclare([string]$Sql, [string]$Variable, [string]$Value) {
        $v = $Value.Replace("'", "''")
        return [regex]::Replace($Sql, "(DECLARE\s+@$Variable\s+[a-z]+(\(max\))?\s*=\s*N')[^']*(')", { param($m) $m.Groups[1].Value + $v + $m.Groups[3].Value })
    }
    Set-SqlLogin -ConnectionString $adminCs -Login $Settings.ExporterLogin -Password $sqlSecrets.ExporterPassword
    $sql = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'sql\grant-sql-exporter-permissions.sql'), [Text.Encoding]::UTF8)
    Invoke-SqlBatches -ConnectionString $adminCs -Sql (Set-SqlDeclare $sql 'login' $Settings.ExporterLogin)
    Write-Ok "Login $($Settings.ExporterLogin): VIEW SERVER STATE, VIEW ANY DEFINITION"

    $readerOk = $false
    if ($Settings.ReaderLogin) {
        Set-SqlLogin -ConnectionString $adminCs -Login $Settings.ReaderLogin -Password $sqlSecrets.ReaderPassword
        if ($readerDbExists) {
            $sql = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'sql\grant-webcon-reader-permissions.sql'), [Text.Encoding]::UTF8)
            $sql = Set-SqlDeclare $sql 'login' $Settings.ReaderLogin
            $sql = Set-SqlDeclare $sql 'databases' $Settings.WebconContentDatabase
            Invoke-SqlBatches -ConnectionString $adminCs -Sql $sql
            Write-Ok "Login $($Settings.ReaderLogin): SELECT na 5 tabelach $($Settings.WebconContentDatabase)"
            $readerOk = $true
        } else {
            Write-Warn "Brak bazy $($Settings.WebconContentDatabase) - login $($Settings.ReaderLogin) bez uprawnień (źródło 'WEBCON SQL' nie zadziała)."
        }
    }

    # Metryki z bazy treści (WEBCONDB): login exportera + SELECT na kolumnach (docs/projekt/projekt-dostepnosc-i-metryki-bazy.md)
    $webconDbOk = $false
    if ($Settings.WebconDbMetrics) {
        $dbId = $null
        $c2 = New-Object System.Data.SqlClient.SqlConnection($adminCs)
        try { $c2.Open(); $dbId = Invoke-SqlScalarQuery $c2 "SELECT DB_ID(N'$($Settings.WebconContentDatabase.Replace("'", "''"))')" } finally { $c2.Dispose() }
        if ($null -ne $dbId -and $dbId -isnot [DBNull]) {
            $sql = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'sql\grant-webcon-db-metrics.sql'), [Text.Encoding]::UTF8)
            $sql = Set-SqlDeclare $sql 'login' $Settings.ExporterLogin
            $sql = Set-SqlDeclare $sql 'databases' $Settings.WebconContentDatabase
            Invoke-SqlBatches -ConnectionString $adminCs -Sql $sql
            Write-Ok "Login $($Settings.ExporterLogin): metryki z bazy $($Settings.WebconContentDatabase) (SELECT na kolumnach)"
            $webconDbOk = $true
        } else {
            Write-Warn "Brak bazy $($Settings.WebconContentDatabase) - metryki z bazy WEBCON pominięte."
        }
    }

    Write-Step 'SQL Server - weryfikacja loginów (TCP, jak exporter)'
    $server = "localhost,$sqlPort"
    $secure = ConvertTo-SecureString -String $sqlSecrets.ExporterPassword -AsPlainText -Force
    $result = Test-SqlExporterPermissions -Server $server -Login $Settings.ExporterLogin -Password $secure `
        -Encrypt ([bool]$Settings.SqlEncrypt) -TrustServerCertificate ([bool]$Settings.SqlTrustServerCertificate)
    foreach ($c in $result.Checks) {
        $line = $c.Check
        if ($c.Detail) { $line = "$line - $($c.Detail)" }
        if ($c.Ok) { Write-Ok $line } else { Write-Warn $line }
    }
    if (-not $result.Success) { throw 'Weryfikacja loginu exportera nie powiodła się.' }
    if ($readerOk) {
        $r = Test-WebconSqlReaderPermissions -Server $server -Database $Settings.WebconContentDatabase -Login $Settings.ReaderLogin `
            -Password $sqlSecrets.ReaderPassword -Encrypt ([bool]$Settings.SqlEncrypt) -TrustServerCertificate ([bool]$Settings.SqlTrustServerCertificate)
        foreach ($c in $r.Checks) {
            $line = "$($Settings.ReaderLogin): $($c.Check)"
            if ($c.Detail) { $line = "$line - $($c.Detail)" }
            if ($c.Ok) { Write-Ok $line } else { Write-Warn $line }
        }
    }

    if ($Settings.ReaderLogin) {
        # Grafana stosu łączy się z SQL bezpośrednio (źródło 'WEBCON SQL') - tylko z adresów VM stosu
        $ruleName = 'Observability - SQL (Grafana)'
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $sqlPort -Action Allow `
            -RemoteAddress @($Settings.CentralIPv4) -Profile Any | Out-Null
        Write-Ok "Reguła '$ruleName' (TCP $sqlPort, z: $(@($Settings.CentralIPv4) -join ', '))"
    }

    Set-SecretFile -Path (Join-Path $Layout.Secrets 'mssql.conn') -Content (
        New-MssqlExporterConnectionString -Server $server -Login $Settings.ExporterLogin -Password $sqlSecrets.ExporterPassword `
            -Encrypt ([bool]$Settings.SqlEncrypt) -TrustServerCertificate ([bool]$Settings.SqlTrustServerCertificate))
    Write-Ok 'Zapisano connection string exportera (secrets\mssql.conn).'
}

# ---------------------------------------------------------------------
Write-Step 'Binarki (z paczki)'
$Exe = @{}
foreach ($name in 'WinSW', 'Alloy') {
    $pkg = $Settings.Packages.$name
    if ($pkg.Version -ne $Versions[$name].Version) { throw "Niespójna paczka: $name $($pkg.Version) vs versions.psd1 $($Versions[$name].Version)." }
    $Exe[$name] = Install-StackComponent -Name $name -Definition $Versions[$name] -Layout $Layout `
        -ArchivePath (Join-Path $PSScriptRoot "packages\$($pkg.File)") -Sha256 $pkg.Sha256
}

# ---------------------------------------------------------------------
Write-Step 'Konfiguracja Alloy'
$vars = @{
    OTLP_BIND          = '127.0.0.1'
    ALLOY_MEMORY_LIMIT = $Settings.AlloyMemoryLimit
    SQL_THRESHOLD_NS   = $Settings.SqlSpanThresholdNs
    SQL_THRESHOLD_TEXT = $Settings.SqlSpanThresholdText
    CENTRAL_OTLP       = "$($Settings.CentralAddress):$($Settings.OtlpPort)"
    REMOTE_WRITE_URL   = "http://$($Settings.CentralAddress):$($Settings.ReceivePort)/api/v1/metrics/write"
    RECEIVE_PORT       = ''
    WINDOWS_COLLECTORS = Get-WindowsCollectorList
    PROCESS_INCLUDE    = $Settings.ProcessInclude
    SECRETS_DIR_ALLOY  = ConvertTo-AlloyPath $Layout.Secrets
    CONFIG_DIR_ALLOY   = ConvertTo-AlloyPath $Layout.Config
    SERVICE_LOG_GLOB   = ''
    WEBCON_CONTENT_DB  = [string]$Settings.WebconContentDatabase
    BLACKBOX_MODULES   = ''
    BLACKBOX_TARGETS   = ''
}
# SERVICENAME_FALLBACK: mapowanie nazw usług WEBCON po nazwie robi stos centralny (agent przekazuje nazwy bez zmian)
$removeBlocks = @('CENTRAL', 'CENTRAL_SELF', 'RECEIVE', 'SERVICELOGS', 'SERVICENAME_FALLBACK')
if (-not $IsSql) { $removeBlocks += 'MSSQL' }
if (-not ($IsSql -and $webconDbOk)) { $removeBlocks += 'WEBCONDB' }
# Sonda Portalu: powiązania IIS i "Host: localhost" są dostępne tylko na hoście WEBCON
$portalTargets = @()
if ($IsWebcon -and $Settings.PortalProbe -ne $false) {
    $portalTargets = @(Get-WebconPortalProbeTarget)
    foreach ($t in $portalTargets) { Write-Ok "Sonda Portalu: $($t.Url) (witryna IIS '$($t.Site)')" }
    if (-not $portalTargets.Count) { Write-Info 'Nie wykryto Portalu WEBCON w IIS - bez sondy Portalu.' }
}
$bb = New-BlackboxConfig -PortalTarget $portalTargets
$vars.BLACKBOX_MODULES = $bb.Modules
$vars.BLACKBOX_TARGETS = $bb.Targets
if (-not $bb.Count) { $removeBlocks += 'BLACKBOX' }
$templates = Join-Path $PSScriptRoot 'config-templates'
$alloyConfig = Join-Path $Layout.Config 'alloy\config.alloy'
Write-Utf8NoBom -Path $alloyConfig -Content (Expand-StackTemplate -TemplatePath (Join-Path $templates 'alloy\config.alloy') -Variables $vars -RemoveBlocks $removeBlocks)
Write-Ok 'config\alloy\config.alloy'
if ($IsSql) {
    Write-Utf8NoBom -Path (Join-Path $Layout.Config 'alloy\mssql-queries.yaml') -Content (
        Expand-StackTemplate -TemplatePath (Join-Path $templates 'alloy\mssql-queries.yaml') -Variables $vars)
    Write-Ok 'config\alloy\mssql-queries.yaml'
    Write-Utf8NoBom -Path (Join-Path $Layout.Config 'alloy\webcon-db-queries.yaml') -Content (
        Expand-StackTemplate -TemplatePath (Join-Path $templates 'alloy\webcon-db-queries.yaml') -Variables $vars)
    Write-Ok 'config\alloy\webcon-db-queries.yaml'
}
$r = Invoke-NativeTool -FilePath $Exe.Alloy -Arguments @('fmt', $alloyConfig)
if ($r.ExitCode -ne 0) { throw "Alloy: błąd składni config.alloy (alloy fmt)`n$($r.Output)" }
Write-Ok 'config.alloy (składnia)'
New-Directory (Join-Path $Layout.Data 'alloy')

# ---------------------------------------------------------------------
Write-Step 'Usługa agenta'
$roleText = $Role -join ', '
Install-WinSWService -Id $ServiceId -DisplayName 'Observability - Alloy (agent)' `
    -Description "Grafana Alloy - agent stosu obserwowalności WEBCON ($roleText) -> $($Settings.CentralAddress)" `
    -Executable $Exe.Alloy `
    -Arguments ("run `"$($Layout.Config)\alloy\config.alloy`" --storage.path=`"$($Layout.Data)\alloy`" " +
                "--server.http.listen-addr=127.0.0.1:12345 --disable-reporting") `
    -WorkingDirectory "$($Layout.Data)\alloy" -LogDirectory "$($Layout.Logs)\alloy" `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services
Start-Service -Name $ServiceId
if (Wait-HttpReady -Url 'http://127.0.0.1:12345/-/ready' -TimeoutSec 120) { Write-Ok 'Alloy gotowy (http://127.0.0.1:12345)' }
else { throw 'Alloy nie zgłosił gotowości - sprawdź Dziennik zdarzeń Application (źródło Alloy).' }

# ---------------------------------------------------------------------
if ($IsWebcon -and -not $SkipWebconConfig) {
    Write-Step 'Konfiguracja OpenTelemetry w WEBCON (restart Portalu i Serwisu)'
    $p = @{ OtlpEndpoint = 'http://127.0.0.1:4318'; SqlTracing = 'Threshold' }
    if ([int64]$Settings.SqlSpanThresholdNs -eq 0) { $p.SqlTracing = 'All' }
    if ($Force) { $p.Force = $true }
    & (Join-Path $PSScriptRoot 'scripts\Set-WebconTelemetry.ps1') @p
}

# ---------------------------------------------------------------------
Write-Step 'Test przepływu do stosu'
# Log testowy przez agenta (OTLP -> filtry -> stos); Test-ObservabilityStack.ps1 na VM stosu szuka service_name="obs-agent-test"
$nowNs = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000
$body = @{ resourceLogs = @(@{
    resource  = @{ attributes = @(
        @{ key = 'service.name'; value = @{ stringValue = 'obs-agent-test' } },
        @{ key = 'host.name'; value = @{ stringValue = $env:COMPUTERNAME } }) }
    scopeLogs = @(@{ scope = @{ name = 'agent-test' }
        logRecords = @(@{ timeUnixNano = [string]$nowNs; severityText = 'INFO'; severityNumber = 9
                          body = @{ stringValue = "agent $env:COMPUTERNAME ($roleText) zainstalowany" } }) })
}) } | ConvertTo-Json -Depth 20 -Compress
try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:4318/v1/logs' -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 | Out-Null
    Write-Ok 'Wysłano log testowy (service_name="obs-agent-test")'
} catch { Write-Warn "Nie wysłano logu testowego: $($_.Exception.Message)" }

# Remote write metryk hosta: liczniki agenta (pierwszy scrape po ~15 s)
function Get-AgentCounter([string]$Name) {
    $sum = 0.0
    $lines = (Invoke-WebRequest 'http://127.0.0.1:12345/metrics' -UseBasicParsing -TimeoutSec 5).Content -split "`n"
    foreach ($l in $lines) { if ($l -match "^$Name\{[^}]*\} ([0-9.eE+-]+)$") { $sum += [double]$Matches[1] } }
    return $sum
}
$deadline = (Get-Date).AddSeconds(60)
$sent = 0; $failedSamples = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    try {
        $sent = Get-AgentCounter 'prometheus_remote_storage_samples_total'
        $failedSamples = Get-AgentCounter 'prometheus_remote_storage_samples_failed_total'
    } catch { }
    if ($sent -gt 0 -or $failedSamples -gt 0) { break }
}
if ($sent -gt 0 -and $failedSamples -eq 0) { Write-Ok "Remote write do stosu: $sent próbek" }
elseif ($failedSamples -gt 0) { Write-Warn "Remote write: $failedSamples próbek odrzuconych - sprawdź Dziennik zdarzeń Application (źródło Alloy)" }
else { Write-Warn 'Remote write: brak wysłanych próbek po 60 s - sprawdź Dziennik zdarzeń Application (źródło Alloy)' }

# ---------------------------------------------------------------------
# Kopia skryptów w app\ (odinstalowanie i Set-WebconTelemetry.ps1 po usunięciu paczki) - bez sekretów i agent-settings.json
Write-Step 'Kopia skryptów agenta'
$agentFiles = @('Uninstall-ObservabilityAgent.ps1', 'scripts\modules\ObservabilityStack.psm1', 'scripts\Set-WebconTelemetry.ps1', 'LICENSE', 'VERSION') +
    @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'sql') -Filter '*.sql' | ForEach-Object { "sql\$($_.Name)" })
$AppDir = Copy-StackApp -SourceRoot $PSScriptRoot -Layout $Layout -Release $Release -Files ($agentFiles | Where-Object { Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) })

# ---------------------------------------------------------------------
Write-Host ''
Write-Host 'Podsumowanie' -ForegroundColor White
Write-Info "Agent       $ServiceId ($roleText) -> $($Settings.CentralAddress)"
Write-Info 'Alloy UI    http://127.0.0.1:12345 (graf komponentów, stan eksporterów)'
if ($IsWebcon) { Write-Info 'OTLP        http://127.0.0.1:4318 (WEBCON wysyła lokalnie)' }
Write-Info 'Logi        Dziennik zdarzeń Application, źródło Alloy'
Write-Info "Sprawdzenie na VM stosu: .\Test-ObservabilityStack.ps1"
Write-Info "Wersja      $($Release.Version); odinstalowanie: $AppDir\Uninstall-ObservabilityAgent.ps1"
Write-Warn "Usuń paczkę agenta z tego hosta ($PSScriptRoot) - zawiera hasła loginów SQL."
