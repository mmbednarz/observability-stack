#Requires -Version 5.1
<#
.SYNOPSIS
    Instaluje self-hosted stos obserwowalności dla WEBCON na Windows Server:
    Grafana Alloy (collector) + Prometheus (metryki) + Tempo (ślady OTLP) + Loki (logi) + Grafana.

.DESCRIPTION
    Wszystkie komponenty działają jako usługi Windows (WinSW), nasłuchują na localhost
    (poza Grafaną przy -GrafanaListenAll). Skrypt jest idempotentny - ponowne uruchomienie
    aktualizuje wersje (versions.psd1) i konfiguracje (config-templates).

.PARAMETER Root
    Katalog instalacji (bin, config, data, logs, services, secrets).

.PARAMETER SqlServer
    Instancja SQL Server do monitorowania (np. "SQLDEV01", "SQLDEV01\BPS", "SQLDEV01,1433").
    Pominięcie = pytanie interaktywne; puste = bez metryk SQL Server.

.PARAMETER SqlLogin
    Dedykowany login SQL dla exportera. Hasło jest pobierane interaktywnie (lub -SqlPassword).
    Uprawnienia są weryfikowane przed instalacją (VIEW SERVER STATE, VIEW ANY DEFINITION).

.PARAMETER WebconSqlReaderLogin
    Login SQL tylko do odczytu dla źródła danych Grafany "WEBCON SQL" (dashboard WEBCON – Utrzymanie),
    z uprawnieniami z sql\grant-webcon-reader-permissions.sql. Hasło: -WebconSqlReaderPassword, istniejący
    sekret grafana-sql-reader.txt albo pytanie interaktywne. Pominięcie = zachowanie poprzedniej konfiguracji;
    puste = bez źródła danych SQL.

.PARAMETER WebconSqlServer
    Instancja SQL Server z bazą treści WEBCON. Domyślnie -SqlServer.

.PARAMETER WebconContentDatabase
    Baza treści WEBCON (domyślnie WEBCON_Content).

.PARAMETER SqlSpanThresholdSeconds
    Spany SQL krótsze niż próg są odrzucane w Alloy. 0 = zachowuj wszystkie.

.PARAMETER ServiceLogPath
    Glob plików logów Serilog WEBCON Serwisu (np. 'D:\WEBCON\Service\Logs\*.log').
    Puste = bez zbierania logów Serwisu z plików.

.PARAMETER WebconPortalServiceName
    Awaryjne mapowanie nazw usług: nazwa usługi (ServiceName z appsettings WEBCON), pod którą Portal wysyła telemetrię
    BEZ znacznika webcon.component (Set-WebconTelemetry.ps1 ustawia znacznik - wtedy parametr niepotrzebny).
    Alloy zamienia ją na "Portal". Pominięcie = poprzednia wartość; puste = bez mapowania.

.PARAMETER WebconServiceServiceName
    Jak -WebconPortalServiceName, dla Serwisu WEBCON (zamiana na "WebCon.WorkFlow").

.PARAMETER PortalProbe
    Sonda dostępności Portalu WEBCON (/health) - adresy z powiązań IIS witryny Portalu (domyślnie $true).
    W trybie zdalnym sondę uruchamia agent na hoście WEBCON. Pominięcie = poprzednia wartość.

.PARAMETER ProbeUrl
    Dodatkowe adresy HTTP(S) do sprawdzania dostępności (kod 2xx), np. Portal produkcyjny lub load balancer.
    Pominięcie = poprzednia lista; '' = bez dodatkowych adresów.

.PARAMETER WebconDbMetrics
    Metryki z bazy treści WEBCON (zaległe timeouty, akcje cykliczne, kolejka maili, rozmiary tabel kolejek i logów).
    Wymaga metryk SQL i uprawnień kolumnowych loginu exportera (sql\grant-webcon-db-metrics.sql); brak uprawnień
    = ostrzeżenie, instalacja trwa dalej. Pominięcie = poprzednia wartość.

.PARAMETER AllowDowngrade
    Zezwala na instalację wersji starszej niż zainstalowana (konfiguracja i reguły alertów nowszej wersji mogą nie pasować
    do starszej). Bez przełącznika obniżenie wersji przerywa instalację.

.PARAMETER ConfigureWebcon
    Po instalacji uruchamia scripts\Set-WebconTelemetry.ps1 (konfiguracja OpenTelemetry w appsettings WEBCON).

.PARAMETER WebconHost
    Tryb zdalny: host z WEBCON (Portal + Serwis). Instalator generuje paczkę agenta (C:\Observability\agent-bundle + .zip)
    ze skryptami do uruchomienia na hostach docelowych. Pominięcie = zachowanie poprzedniej konfiguracji; puste = bez hosta.

.PARAMETER SqlHost
    Tryb zdalny: host SQL Server z bazami WEBCON. Metryki SQL zbiera agent na tym hoście (nie podawaj -SqlServer).
    Loginy exportera i czytelnika Grafany tworzy skrypt hosta SQL z hasłami wygenerowanymi tutaj.

.PARAMETER SqlInstanceName
    Tryb zdalny: nazwa instancji na -SqlHost (MSSQLSERVER = domyślna, np. SQLEXPRESS).

.PARAMETER SqlPort
    Tryb zdalny: port TCP instancji (źródło 'WEBCON SQL' w Grafanie; -EnableSqlTcp na hoście SQL ustawia go jako statyczny).

.PARAMETER CentralAddress
    Adres tej VM widziany z hostów agentów. Domyślnie FQDN.

.PARAMETER AgentAddress
    Adresy IP hostów agentów dopuszczone w firewallu (OTLP 4317/4318, remote write 9999). Domyślnie z DNS -WebconHost / -SqlHost.

.EXAMPLE
    .\Install-ObservabilityStack.ps1 -SqlServer 'SQLDEV01' -SqlLogin 'svc_obs_mssql_exporter' -ServiceLogPath 'C:\Program Files\WEBCON\WEBCON BPS WorkFlow Service\Logs\*.log'
.EXAMPLE
    .\Install-ObservabilityStack.ps1 -WebconHost 'WEBCON01' -SqlHost 'SQL01' -SqlInstanceName 'BPS' -GrafanaListenAll
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\Observability',
    [string]$EnvironmentName = $env:COMPUTERNAME,

    [ValidateRange(1, 3650)][int]$RetentionMetricsDays = 15,
    # 8 dni: dashboard WEBCON – Utrzymanie ma zakres 7 dni, przy 7 dniach najstarszy dzień byłby częściowo usunięty
    [ValidateRange(1, 3650)][int]$RetentionTracesDays = 8,
    [ValidateRange(1, 3650)][int]$RetentionLogsDays = 7,

    [ValidateRange(0, 3600)][double]$SqlSpanThresholdSeconds = 1.0,
    [string]$AlloyMemoryLimit = '1GiB',

    [string]$SqlServer,
    [string]$SqlLogin,
    [Security.SecureString]$SqlPassword,
    [bool]$SqlEncrypt = $true,
    [bool]$SqlTrustServerCertificate = $true,

    [string]$WebconSqlReaderLogin,
    [Security.SecureString]$WebconSqlReaderPassword,
    [string]$WebconSqlServer,
    [string]$WebconContentDatabase = 'WEBCON_Content',

    [string]$ServiceLogPath,

    [string]$WebconPortalServiceName,
    [string]$WebconServiceServiceName,

    [bool]$PortalProbe = $true,
    [string[]]$ProbeUrl,
    [bool]$WebconDbMetrics = $false,

    [string]$WebconHost,
    [string]$SqlHost,
    [string]$SqlInstanceName = 'MSSQLSERVER',
    [ValidateRange(1, 65535)][int]$SqlPort = 1433,
    [string]$CentralAddress,
    [string[]]$AgentAddress,

    [switch]$GrafanaListenAll,
    [switch]$OtlpListenAll,
    [switch]$SkipCommunityDashboards,
    [switch]$ForceDownload,
    [switch]$NonInteractive,
    [switch]$AllowDowngrade,

    [switch]$ConfigureWebcon
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'scripts\modules\ObservabilityStack.psm1') -Force -DisableNameChecking

Assert-Administrator

$Versions = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'versions.psd1')
$Layout   = Get-StackLayout -Root $Root
$Templates = Join-Path $RepoRoot 'config-templates'
$Release  = Get-StackRelease -SourceRoot $RepoRoot
$PackageFiles = Get-StackPackageFiles -SourceRoot $RepoRoot

$ServiceIds = [ordered]@{
    Prometheus = 'obs-prometheus'
    Loki       = 'obs-loki'
    Tempo      = 'obs-tempo'
    Alloy      = 'obs-alloy'
    Grafana    = 'obs-grafana'
}
$Ports = [ordered]@{
    4317 = 'Alloy OTLP gRPC'; 4318 = 'Alloy OTLP HTTP'; 12345 = 'Alloy UI'
    9090 = 'Prometheus'; 3100 = 'Loki HTTP'; 9096 = 'Loki gRPC'
    3200 = 'Tempo HTTP'; 9097 = 'Tempo gRPC'; 14317 = 'Tempo OTLP gRPC'; 7947 = 'Tempo memberlist'
    3000 = 'Grafana'
}
$ReceivePort = 9999
$ProcessInclude = '(?i)^(w3wp|sqlservr|dotnet|webcon.*|alloy.*|prometheus|loki.*|tempo|grafana)$'

Write-Host ''
Write-Host "Observability Stack (WEBCON) $($Release.Version) - instalacja" -ForegroundColor White
Write-Host "Katalog: $($Layout.Root)   Pliki instalacyjne: $RepoRoot" -ForegroundColor White
Write-StackDisclaimer
Write-Host ''

$previous = Get-InstallSettings -Root $Layout.Root

# ---------------------------------------------------------------------
# Wersja i położenie plików instalacyjnych (docs/projekt/projekt-dystrybucja-i-wersje.md)
Write-Step 'Wersja'
Assert-InstallLocation -SourceRoot $RepoRoot -Layout $Layout
$PreviousVersion = ''
if ($previous -and $previous.StackVersion) { $PreviousVersion = [string]$previous.StackVersion }
if (-not $previous) {
    Write-Ok "Instalacja $($Release.Version)"
} elseif (-not $PreviousVersion) {
    Write-Ok "Aktualizacja instalacji sprzed wydań -> $($Release.Version)"
} else {
    $cmp = (ConvertTo-StackVersion $Release.Version).CompareTo((ConvertTo-StackVersion $PreviousVersion))
    if ($cmp -lt 0) {
        if (-not $AllowDowngrade) {
            throw ("Zainstalowana jest nowsza wersja ($PreviousVersion) niż instalowana ($($Release.Version)). Konfiguracja i reguły " +
                   "alertów nowszej wersji mogą nie pasować do starszej - użyj nowszej paczki albo -AllowDowngrade.")
        }
        Write-Warn "Obniżenie wersji $PreviousVersion -> $($Release.Version) (-AllowDowngrade)"
    } elseif ($PreviousVersion -eq $Release.Version) {
        Write-Ok "Ponowna instalacja $($Release.Version)"
    } else {
        Write-Ok "Aktualizacja $PreviousVersion -> $($Release.Version)"
    }
}
if ($Release.Dev) { Write-Info 'Wersja deweloperska (klon repozytorium) - linki do dokumentacji wskazują gałąź main.' }
# Pliki z ZIP-a pobranego z internetu (Zone.Identifier) - kopia w app\ ma być odblokowana
foreach ($f in $PackageFiles) { Unblock-File -LiteralPath (Join-Path $RepoRoot $f) -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------
# Tryb zdalny (agenci na hostach WEBCON / SQL). Aktualizacja bez -WebconHost/-SqlHost zachowuje poprzednie hosty.
$RemoteMode = $false
if (-not $PSBoundParameters.ContainsKey('WebconHost') -and -not $PSBoundParameters.ContainsKey('SqlHost') -and
    $previous -and ($previous.WebconHost -or $previous.SqlHost)) {
    $WebconHost = $previous.WebconHost
    $SqlHost = $previous.SqlHost
    foreach ($k in 'SqlInstanceName', 'SqlPort', 'CentralAddress', 'AgentAddress') {
        if (-not $PSBoundParameters.ContainsKey($k) -and $previous.$k) { Set-Variable -Name $k -Value $previous.$k }
    }
}
if ($WebconHost -or $SqlHost) {
    $RemoteMode = $true
    Write-Step 'Tryb zdalny (agenci)'
    if ($PSBoundParameters.ContainsKey('SqlServer') -and $SqlServer) {
        throw 'W trybie zdalnym metryki SQL zbiera agent na hoście SQL (-SqlHost) - nie podawaj -SqlServer.'
    }
    # Exporter mssql nie działa na VM stosu - pomijamy sekcję loginu exportera (jak przy -SqlServer '')
    $SqlServer = ''
    $PSBoundParameters['SqlServer'] = ''
    if (-not $CentralAddress) { $CentralAddress = [Net.Dns]::GetHostEntry('').HostName }
    if (-not $AgentAddress) {
        $AgentAddress = @()
        foreach ($h in @($WebconHost, $SqlHost) | Where-Object { $_ } | Select-Object -Unique) {
            try {
                $AgentAddress += @([Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() })
            } catch {
                throw "Nie można ustalić adresu IP hosta $h (DNS) - podaj -AgentAddress."
            }
        }
        $AgentAddress = @($AgentAddress | Select-Object -Unique)
    }
    $CentralIPv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Select-Object -ExpandProperty IPAddress)
    if ($WebconHost) { Write-Ok "Host WEBCON: $WebconHost" }
    if ($SqlHost)    { Write-Ok "Host SQL:    $SqlHost (instancja $SqlInstanceName, port $SqlPort)" }
    Write-Ok "Adres stosu dla agentów: $CentralAddress; firewall dopuszcza: $($AgentAddress -join ', ')"
    $Ports.Add($ReceivePort, 'Alloy remote write (agenci)')
}

# ---------------------------------------------------------------------
Write-Step 'Katalogi'
foreach ($k in 'Root', 'Bin', 'Config', 'Data', 'Logs', 'Services', 'Downloads') { New-Directory $Layout[$k] }
Protect-SecretsDirectory -Path $Layout.Secrets
Write-Ok 'Struktura katalogów gotowa (secrets: ACL SYSTEM + Administrators).'

# ---------------------------------------------------------------------
Write-Step 'Zatrzymanie istniejących usług stosu (aktualizacja)'
# Odwrotna kolejność (Grafana pierwsza): Grafana działająca po zatrzymaniu Prometheusa / Loki ocenia reguły alertów
# z błędem "connection refused", zapisuje ten stan i odtwarza go po starcie ("Warming state cache") - fałszywe
# błędy ewaluacji w smoke teście do kolejnej ewaluacji (1 min).
$stopOrder = @($ServiceIds.Values)
[array]::Reverse($stopOrder)
foreach ($id in $stopOrder) {
    $svc = Get-Service -Name $id -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $id -Force
        $null = $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        Write-Ok "Zatrzymano $id"
    }
}

Write-Step 'Weryfikacja wolnych portów'
$busy = @()
foreach ($p in $Ports.Keys) {
    if (Test-TcpPortInUse -Port $p) { $busy += "$p ($($Ports[$p])) zajęty przez $(Get-PortOwner -Port $p)" }
}
if ($busy) { throw ("Zajęte porty:`n  " + ($busy -join "`n  ") + "`nZwolnij porty (np. lokalny Jaeger/Seq) i uruchom ponownie.") }
Write-Ok 'Wszystkie porty wolne.'

# ---------------------------------------------------------------------
Write-Step 'SQL Server - login exportera'
$EnableMssql = $false
$ReuseMssql = $false
$MssqlConnString = $null
# Aktualizacja: bez -SqlServer zachowujemy login z poprzedniej instalacji (sekret mssql.conn); -SqlServer '' wyłącza SQL
if (-not $PSBoundParameters.ContainsKey('SqlServer') -and $previous -and $previous.SqlServer -and
    (Test-Path -LiteralPath (Join-Path $Layout.Secrets 'mssql.conn'))) {
    $SqlServer = $previous.SqlServer
    $SqlLogin = $previous.SqlLogin
    $ReuseMssql = $true
    $EnableMssql = $true
    Write-Ok "Zachowano login exportera z poprzedniej instalacji ($SqlLogin @ $SqlServer). Zmiana: -SqlServer/-SqlLogin, wyłączenie: -SqlServer ''."
}
if (-not $ReuseMssql -and -not $PSBoundParameters.ContainsKey('SqlServer') -and -not $NonInteractive) {
    $SqlServer = Read-Host 'Instancja SQL Server do monitorowania (Enter = pomiń metryki SQL)'
}
if ($ReuseMssql) {
    # bez zmian - sekret mssql.conn pozostaje
} elseif ($SqlServer) {
    if (-not $SqlLogin) {
        if ($NonInteractive) { throw 'Podaj -SqlLogin.' }
        $SqlLogin = Read-Host "Login SQL exportera dla $SqlServer"
    }
    if (-not $SqlPassword) {
        if ($NonInteractive) { throw 'Podaj -SqlPassword.' }
        $SqlPassword = Read-Host "Hasło dla $SqlLogin" -AsSecureString
    }
    $result = Test-SqlExporterPermissions -Server $SqlServer -Login $SqlLogin -Password $SqlPassword -Encrypt $SqlEncrypt -TrustServerCertificate $SqlTrustServerCertificate
    foreach ($c in $result.Checks) {
        $line = $c.Check
        if ($c.Detail) { $line = "$line - $($c.Detail)" }
        if ($c.Ok) { Write-Ok $line } else { Write-Warn $line }
    }
    if (-not $result.Success) {
        if ($result.Remediation) {
            Write-Host ''
            Write-Host 'Brakujące uprawnienia - do wykonania przez DBA:' -ForegroundColor Yellow
            Write-Host $result.Remediation
            Write-Host ''
        }
        throw 'Weryfikacja loginu SQL nie powiodła się. Popraw uprawnienia i uruchom instalację ponownie (albo pomiń metryki SQL pustym -SqlServer).'
    }
    $MssqlConnString = New-MssqlExporterConnectionString -Server $SqlServer -Login $SqlLogin -Password (ConvertFrom-SecureStringPlain $SqlPassword) -Encrypt $SqlEncrypt -TrustServerCertificate $SqlTrustServerCertificate
    $EnableMssql = $true
} elseif ($RemoteMode -and $SqlHost) {
    Write-Ok "Metryki SQL Server zbiera agent na hoście $SqlHost."
} else {
    Write-Warn 'Metryki SQL Server pominięte.'
}

# ---------------------------------------------------------------------
Write-Step 'SQL Server - źródło danych Grafany (baza treści WEBCON)'
$EnableWebconSql = $false
$WebconSqlReaderPlain = $null
$saveReaderPwd = $false   # hasło z parametru lub z Read-Host (nie z istniejącego sekretu) - do zapisania
$readerPwdFile = Join-Path $Layout.Secrets 'grafana-sql-reader.txt'
if ($RemoteMode) {
    # Login tworzy skrypt hosta SQL z paczki agenta (hasło generowane tutaj) - weryfikacja: Test-ObservabilityStack.ps1 po instalacji agenta
    if (-not $PSBoundParameters.ContainsKey('WebconSqlReaderLogin')) {
        $WebconSqlReaderLogin = 'svc_obs_grafana_reader'
        # poprzedni wybór tylko z instalacji w trybie zdalnym ('' = świadomie wyłączone); w trybie lokalnym pusty login = brak źródła
        if ($previous -and ($previous.WebconHost -or $previous.SqlHost) -and $null -ne $previous.WebconSqlReaderLogin) {
            $WebconSqlReaderLogin = $previous.WebconSqlReaderLogin
        }
    }
    if (-not $PSBoundParameters.ContainsKey('WebconContentDatabase') -and $previous -and $previous.WebconContentDatabase) {
        $WebconContentDatabase = $previous.WebconContentDatabase
    }
    if ($SqlHost -and $WebconSqlReaderLogin) {
        $WebconSqlServer = "$SqlHost,$SqlPort"
        if ((Test-Path -LiteralPath $readerPwdFile) -and $previous -and $previous.WebconSqlReaderLogin -eq $WebconSqlReaderLogin) {
            $WebconSqlReaderPlain = [IO.File]::ReadAllText($readerPwdFile, [Text.Encoding]::UTF8)
        } else {
            $WebconSqlReaderPlain = New-RandomPassword
            $saveReaderPwd = $true
        }
        $EnableWebconSql = $true
        Write-Ok "Źródło danych 'WEBCON SQL': $WebconSqlReaderLogin @ $WebconSqlServer / $WebconContentDatabase (login utworzy skrypt hosta SQL)"
    } else {
        Write-Warn "Źródło danych 'WEBCON SQL' pominięte (dashboard WEBCON – Utrzymanie bez paneli z bazy)."
    }
} else {
    # Aktualizacja: bez -WebconSqlReaderLogin zachowujemy poprzednią konfigurację; -WebconSqlReaderLogin '' wyłącza źródło
    $reuseReader = $false
    if (-not $PSBoundParameters.ContainsKey('WebconSqlReaderLogin') -and $previous -and $previous.WebconSqlReaderLogin) {
        $WebconSqlReaderLogin = $previous.WebconSqlReaderLogin
        if (-not $PSBoundParameters.ContainsKey('WebconSqlServer')) { $WebconSqlServer = $previous.WebconSqlServer }
        if (-not $PSBoundParameters.ContainsKey('WebconContentDatabase')) { $WebconContentDatabase = $previous.WebconContentDatabase }
        $reuseReader = $true
    }
    if (-not $WebconSqlServer) { $WebconSqlServer = $SqlServer }
    if ($WebconSqlReaderLogin) {
        if (-not $WebconSqlServer) { throw 'Podaj -WebconSqlServer (instancja z bazą treści WEBCON) albo -SqlServer.' }
        if ($WebconSqlReaderPassword) {
            $WebconSqlReaderPlain = ConvertFrom-SecureStringPlain $WebconSqlReaderPassword
            $saveReaderPwd = $true
        } elseif ((Test-Path -LiteralPath $readerPwdFile) -and
                  ($reuseReader -or ($previous -and $previous.WebconSqlReaderLogin -eq $WebconSqlReaderLogin))) {
            # sekret należy do tego samego loginu (nowy login bez -WebconSqlReaderPassword = pytanie o hasło)
            $WebconSqlReaderPlain = [IO.File]::ReadAllText($readerPwdFile, [Text.Encoding]::UTF8)
            Write-Ok 'Hasło loginu z istniejącego sekretu grafana-sql-reader.txt.'
        } elseif ($NonInteractive) {
            throw "Podaj -WebconSqlReaderPassword (login $WebconSqlReaderLogin; istniejący sekret grafana-sql-reader.txt dotyczy innego loginu lub go brak)."
        } else {
            $WebconSqlReaderPlain = ConvertFrom-SecureStringPlain (Read-Host "Hasło dla $WebconSqlReaderLogin" -AsSecureString)
            $saveReaderPwd = $true
        }
        $result = Test-WebconSqlReaderPermissions -Server $WebconSqlServer -Database $WebconContentDatabase -Login $WebconSqlReaderLogin `
            -Password $WebconSqlReaderPlain -Encrypt $SqlEncrypt -TrustServerCertificate $SqlTrustServerCertificate
        foreach ($c in $result.Checks) {
            $line = $c.Check
            if ($c.Detail) { $line = "$line - $($c.Detail)" }
            if ($c.Ok) { Write-Ok $line } else { Write-Warn $line }
        }
        if ($result.Success) {
            $EnableWebconSql = $true
            Write-Ok "Źródło danych 'WEBCON SQL': $WebconSqlReaderLogin @ $WebconSqlServer / $WebconContentDatabase"
        } elseif ($reuseReader) {
            # Np. aktualizacja WEBCON odtworzyła tabele i usunęła uprawnienia - nie blokujemy aktualizacji stosu
            Write-Warn "Źródło danych 'WEBCON SQL' pominięte - uruchom ponownie sql\grant-webcon-reader-permissions.sql i instalator."
        } else {
            throw "Weryfikacja loginu $WebconSqlReaderLogin nie powiodła się. Uruchom sql\grant-webcon-reader-permissions.sql (DBA) albo pomiń źródło pustym -WebconSqlReaderLogin."
        }
    } else {
        Write-Warn "Źródło danych 'WEBCON SQL' pominięte (dashboard WEBCON – Utrzymanie bez paneli z bazy)."
    }
}

# ---------------------------------------------------------------------
# Dostępność i metryki z bazy WEBCON (docs/projekt/projekt-dostepnosc-i-metryki-bazy.md)
Write-Step 'Dostępność Portalu (sondy HTTP)'
if (-not $PSBoundParameters.ContainsKey('PortalProbe') -and $previous -and $null -ne $previous.PortalProbe) { $PortalProbe = [bool]$previous.PortalProbe }
if (-not $PSBoundParameters.ContainsKey('ProbeUrl') -and $previous -and $previous.ProbeUrl) { $ProbeUrl = @($previous.ProbeUrl) }
$ProbeUrl = @($ProbeUrl | Where-Object { $_ })
foreach ($u in $ProbeUrl) {
    if ($u -notmatch '^https?://[^\s"`\\]+$') { throw "-ProbeUrl: niepoprawny adres '$u' (oczekiwany http:// lub https://)." }
}
$PortalTargets = @()
if (-not $PortalProbe) {
    Write-Info 'Sonda Portalu wyłączona (-PortalProbe $false).'
} elseif ($RemoteMode) {
    Write-Info 'Sonda Portalu: agent na hoście WEBCON (powiązania IIS są na tamtym hoście).'
} else {
    $PortalTargets = @(Get-WebconPortalProbeTarget)
    if ($PortalTargets.Count) {
        foreach ($t in $PortalTargets) { Write-Ok "Portal: $($t.Url) (witryna IIS '$($t.Site)')" }
    } else {
        Write-Info 'Nie wykryto Portalu WEBCON w IIS (witryna z WebCon.WorkFlow.Bootstrapper) - bez sondy Portalu.'
    }
}
foreach ($u in $ProbeUrl) { Write-Ok "Dodatkowy adres: $u" }
$Blackbox = New-BlackboxConfig -PortalTarget $PortalTargets -ProbeUrl $ProbeUrl

Write-Step 'Metryki z bazy treści WEBCON'
if (-not $PSBoundParameters.ContainsKey('WebconDbMetrics') -and $previous -and $null -ne $previous.WebconDbMetrics) { $WebconDbMetrics = [bool]$previous.WebconDbMetrics }
if (-not $PSBoundParameters.ContainsKey('WebconContentDatabase') -and $previous -and $previous.WebconContentDatabase) { $WebconContentDatabase = $previous.WebconContentDatabase }
if ($WebconContentDatabase -notmatch '^[^\[\]''";]+$') { throw "-WebconContentDatabase: niedozwolone znaki w nazwie bazy '$WebconContentDatabase'." }
$EnableWebconDb = $false
if (-not $WebconDbMetrics) {
    Write-Info 'Wyłączone (-WebconDbMetrics $true włącza).'
} elseif ($RemoteMode) {
    if ($SqlHost) { Write-Ok "Zbiera agent na hoście $SqlHost (baza $WebconContentDatabase; uprawnienia nadaje skrypt hosta SQL)." }
    else { Write-Warn 'Pominięte - tryb zdalny bez -SqlHost.' }
} elseif (-not $EnableMssql) {
    Write-Warn 'Pominięte - wymagają metryk SQL Server (-SqlServer / -SqlLogin).'
} else {
    if ($ReuseMssql) {
        $c = ConvertFrom-MssqlConnectionUrl ([IO.File]::ReadAllText((Join-Path $Layout.Secrets 'mssql.conn'), [Text.Encoding]::UTF8))
        $dbServer = $c.Server; $dbLogin = $c.Login; $dbPassword = $c.Password
    } else {
        $dbServer = $SqlServer; $dbLogin = $SqlLogin; $dbPassword = ConvertFrom-SecureStringPlain $SqlPassword
    }
    $result = Test-WebconDbMetricsPermissions -Server $dbServer -Database $WebconContentDatabase -Login $dbLogin -Password $dbPassword `
        -Encrypt $SqlEncrypt -TrustServerCertificate $SqlTrustServerCertificate
    foreach ($c in $result.Checks) {
        $line = $c.Check
        if ($c.Detail) { $line = "$line - $($c.Detail)" }
        if ($c.Ok) { Write-Ok $line } else { Write-Warn $line }
    }
    # Brak uprawnień nie blokuje instalacji (D5) - błąd widać tylko w jobie integrations/mssql-webcon
    $EnableWebconDb = $true
    if ($result.Success) {
        Write-Ok "Metryki z bazy: $dbLogin @ $dbServer / $WebconContentDatabase"
    } else {
        Write-Warn "Brak uprawnień - DBA: sql\grant-webcon-db-metrics.sql (@login = N'$dbLogin', @databases = N'$WebconContentDatabase'). Metryki pojawią się bez ponownej instalacji."
    }
    $dbPassword = $null
}

# ---------------------------------------------------------------------
Write-Step 'Pobieranie i instalacja binarek'
$Exe = @{}
foreach ($name in 'WinSW', 'Prometheus', 'Loki', 'Tempo', 'Alloy', 'Grafana') {
    $Exe[$name] = Install-StackComponent -Name $name -Definition $Versions[$name] -Layout $Layout -Force:$ForceDownload
}

# ---------------------------------------------------------------------
Write-Step 'Sekrety'
$grafanaPwdFile = Join-Path $Layout.Secrets 'grafana-admin.txt'
$newGrafanaPassword = $null
if (-not (Test-Path -LiteralPath $grafanaPwdFile)) {
    $newGrafanaPassword = New-RandomPassword
    Set-SecretFile -Path $grafanaPwdFile -Content $newGrafanaPassword
    Write-Ok 'Wygenerowano hasło admina Grafany.'
} else {
    Write-Ok 'Hasło admina Grafany już istnieje (bez zmian).'
}
$mssqlConnFile = Join-Path $Layout.Secrets 'mssql.conn'
if ($EnableMssql -and -not $ReuseMssql) {
    Set-SecretFile -Path $mssqlConnFile -Content $MssqlConnString
    Write-Ok 'Zapisano connection string exportera SQL.'
}
if ($EnableWebconSql -and $saveReaderPwd) {
    Set-SecretFile -Path $readerPwdFile -Content $WebconSqlReaderPlain
    Write-Ok 'Zapisano hasło loginu źródła danych WEBCON SQL.'
}
# Tryb zdalny: hasło loginu exportera mssql (agent na hoście SQL) - przechowywane tu, by ponowna instalacja dała tę samą paczkę
$AgentExporterLogin = 'svc_obs_mssql_exporter'
if ($SqlLogin) { $AgentExporterLogin = $SqlLogin }
$AgentExporterPlain = $null
if ($RemoteMode -and $SqlHost) {
    $exporterPwdFile = Join-Path $Layout.Secrets 'agent-mssql-exporter.txt'
    if (Test-Path -LiteralPath $exporterPwdFile) {
        $AgentExporterPlain = [IO.File]::ReadAllText($exporterPwdFile, [Text.Encoding]::UTF8)
    } else {
        $AgentExporterPlain = New-RandomPassword
        Set-SecretFile -Path $exporterPwdFile -Content $AgentExporterPlain
        Write-Ok 'Wygenerowano hasło loginu exportera SQL (agent na hoście SQL).'
    }
}

# ---------------------------------------------------------------------
Write-Step 'Generowanie konfiguracji'
$thresholdNs = [int64]([math]::Round($SqlSpanThresholdSeconds * 1e9))
$thresholdText = "$SqlSpanThresholdSeconds s"
if ($thresholdNs -eq 0) { $thresholdText = 'wyłączony - zachowywane wszystkie spany SQL' }

$otlpBind = '127.0.0.1'
if ($OtlpListenAll -or $RemoteMode) { $otlpBind = '0.0.0.0' }
$grafanaBind = '127.0.0.1'
if ($GrafanaListenAll) { $grafanaBind = '0.0.0.0' }

$vars = @{
    ENVIRONMENT        = $EnvironmentName
    DATA_FWD           = ConvertTo-ForwardSlash $Layout.Data
    LOGS_FWD           = ConvertTo-ForwardSlash $Layout.Logs
    CONFIG_FWD         = ConvertTo-ForwardSlash $Layout.Config
    SECRETS_FWD        = ConvertTo-ForwardSlash $Layout.Secrets
    SECRETS_DIR_ALLOY  = ConvertTo-AlloyPath $Layout.Secrets
    CONFIG_DIR_ALLOY   = ConvertTo-AlloyPath $Layout.Config
    OTLP_BIND          = $otlpBind
    GRAFANA_BIND       = $grafanaBind
    ALLOY_MEMORY_LIMIT = $AlloyMemoryLimit
    SQL_THRESHOLD_NS   = $thresholdNs
    SQL_THRESHOLD_TEXT = $thresholdText
    PROCESS_INCLUDE    = $ProcessInclude
    SERVICE_LOG_GLOB   = ''
    RETENTION_TRACES   = "$($RetentionTracesDays * 24)h"
    RETENTION_LOGS     = "$($RetentionLogsDays * 24)h"
    WINDOWS_COLLECTORS = Get-WindowsCollectorList
    REMOTE_WRITE_URL   = 'http://127.0.0.1:9090/api/v1/write'
    RECEIVE_PORT       = $ReceivePort
    CENTRAL_OTLP       = ''
    # alerty Grafany (provisioning\alerting): host stosu, wolumin danych, hosty WEBCON wykluczane z alertu W9
    STACK_HOST         = $env:COMPUTERNAME
    DATA_VOLUME        = (Split-Path -Qualifier $Layout.Data)
    DATA_DIR           = $Layout.Data
    LOGS_DIR           = $Layout.Logs
    WEBCON_SELF_HOSTS  = $env:COMPUTERNAME
}
if ($RemoteMode -and $WebconHost) { $vars.WEBCON_SELF_HOSTS = $WebconHost.Split('.')[0] }
$removeBlocks = @('AGENT')
if (-not $RemoteMode) { $removeBlocks += 'RECEIVE' }
if (-not $EnableMssql) { $removeBlocks += 'MSSQL' }
if ($EnableWebconSql) {
    # Grafana (go-mssqldb): host:port lub host\instancja
    $s = ConvertFrom-SqlServerName -Server $WebconSqlServer
    $url = $s.Host
    if ($s.Port) { $url = "$($s.Host):$($s.Port)" } elseif ($s.Instance) { $url = "$($s.Host)\$($s.Instance)" }
    $vars.WEBCONSQL_URL = $url
    $vars.WEBCONSQL_LOGIN = $WebconSqlReaderLogin
    $vars.WEBCONSQL_DATABASE = $WebconContentDatabase
    $vars.WEBCONSQL_ENCRYPT = 'false'
    if ($SqlEncrypt) { $vars.WEBCONSQL_ENCRYPT = 'true' }
    $vars.WEBCONSQL_TLS_SKIP_VERIFY = 'false'
    if ($SqlTrustServerCertificate) { $vars.WEBCONSQL_TLS_SKIP_VERIFY = 'true' }
} else {
    $removeBlocks += 'WEBCONSQL'
}
if ($ServiceLogPath) { $vars.SERVICE_LOG_GLOB = ConvertTo-AlloyPath $ServiceLogPath } else { $removeBlocks += 'SERVICELOGS' }

# Awaryjne mapowanie nazw usług WEBCON bez znacznika webcon.component (docs/projekt/projekt-nazwy-uslug-webcon.md)
foreach ($k in 'WebconPortalServiceName', 'WebconServiceServiceName') {
    if (-not $PSBoundParameters.ContainsKey($k) -and $previous -and $previous.$k) { Set-Variable -Name $k -Value $previous.$k }
    $v = Get-Variable -Name $k -ValueOnly
    if ($v -and $v -notmatch '^[A-Za-z0-9_.:\-]+$') { throw "-$k ma niedozwolone znaki: '$v' (dozwolone: litery, cyfry, _ . : -)." }
}
if ($WebconPortalServiceName -and $WebconPortalServiceName -eq $WebconServiceServiceName) {
    throw "-WebconPortalServiceName i -WebconServiceServiceName mają tę samą wartość ('$WebconPortalServiceName') - Portalu i Serwisu nie da się rozróżnić po nazwie. Uruchom scripts\Set-WebconTelemetry.ps1 (znacznik webcon.component)."
}
$vars.WEBCON_PORTAL_SERVICE_NAME = [string]$WebconPortalServiceName
$vars.WEBCON_SERVICE_SERVICE_NAME = [string]$WebconServiceServiceName
if (-not $WebconPortalServiceName -and -not $WebconServiceServiceName) { $removeBlocks += 'SERVICENAME_FALLBACK' }

# Sondy dostępności i metryki z bazy WEBCON
$vars.BLACKBOX_MODULES = $Blackbox.Modules
$vars.BLACKBOX_TARGETS = $Blackbox.Targets
if (-not $Blackbox.Count) { $removeBlocks += 'BLACKBOX' }
$vars.WEBCON_CONTENT_DB = $WebconContentDatabase
if (-not $EnableWebconDb) { $removeBlocks += 'WEBCONDB' }

$rendered = @(
    @{ T = 'alloy\config.alloy';                                     O = 'alloy\config.alloy' }
    @{ T = 'alloy\mssql-queries.yaml';                               O = 'alloy\mssql-queries.yaml' }
    @{ T = 'alloy\webcon-db-queries.yaml';                           O = 'alloy\webcon-db-queries.yaml' }
    @{ T = 'prometheus\prometheus.yml';                              O = 'prometheus\prometheus.yml' }
    @{ T = 'tempo\tempo.yaml';                                       O = 'tempo\tempo.yaml' }
    @{ T = 'loki\loki.yaml';                                         O = 'loki\loki.yaml' }
    @{ T = 'grafana\grafana.ini';                                    O = 'grafana\grafana.ini' }
    @{ T = 'grafana\provisioning\datasources\datasources.yaml';      O = 'grafana\provisioning\datasources\datasources.yaml' }
    @{ T = 'grafana\provisioning\dashboards\dashboards.yaml';        O = 'grafana\provisioning\dashboards\dashboards.yaml' }
    @{ T = 'grafana\provisioning\alerting\rules-webcon.yaml';       O = 'grafana\provisioning\alerting\rules-webcon.yaml' }
    @{ T = 'grafana\provisioning\alerting\rules-stack.yaml';        O = 'grafana\provisioning\alerting\rules-stack.yaml' }
)
foreach ($r in $rendered) {
    $content = Expand-StackTemplate -TemplatePath (Join-Path $Templates $r.T) -Variables $vars -RemoveBlocks $removeBlocks
    Write-Utf8NoBom -Path (Join-Path $Layout.Config $r.O) -Content $content
    Write-Ok "config\$($r.O)"
}
foreach ($d in 'prometheus', 'loki', 'tempo', 'alloy', 'grafana') { New-Directory (Join-Path $Layout.Data $d) }

# ---------------------------------------------------------------------
Write-Step 'Walidacja konfiguracji'
$promtool = Join-Path (Split-Path -Parent $Exe.Prometheus) 'promtool.exe'
if (Test-Path -LiteralPath $promtool) {
    $r = Invoke-NativeTool -FilePath $promtool -Arguments @('check', 'config', (Join-Path $Layout.Config 'prometheus\prometheus.yml'))
    if ($r.ExitCode -ne 0) { throw "promtool: niepoprawny prometheus.yml`n$($r.Output)" }
    Write-Ok 'prometheus.yml'
}
$r = Invoke-NativeTool -FilePath $Exe.Loki -Arguments @("-config.file=$(Join-Path $Layout.Config 'loki\loki.yaml')", '-verify-config')
if ($r.ExitCode -ne 0) { throw "Loki: niepoprawny loki.yaml`n$($r.Output)" }
Write-Ok 'loki.yaml'
$r = Invoke-NativeTool -FilePath $Exe.Alloy -Arguments @('fmt', (Join-Path $Layout.Config 'alloy\config.alloy'))
if ($r.ExitCode -ne 0) { throw "Alloy: błąd składni config.alloy (alloy fmt)`n$($r.Output)" }
Write-Ok 'config.alloy (składnia)'

# ---------------------------------------------------------------------
Write-Step 'Dashboardy Grafany'
$dashRoot = Join-Path $Layout.Config 'grafana\dashboards'
New-Directory $dashRoot
# Katalog jest w całości zarządzany przez instalator: usuń dashboardy, których nie ma już w repozytorium
# ani w CommunityDashboards (np. host\windows-exporter.json = 19957, webcon\webcon-overview.json)
$repoDashRoot = Join-Path $RepoRoot 'dashboards'
$keepDash = @{}
foreach ($f in Get-ChildItem -LiteralPath $repoDashRoot -Recurse -File -Filter '*.json') {
    $keepDash[$f.FullName.Substring($repoDashRoot.Length).TrimStart('\').ToLowerInvariant()] = $true
}
foreach ($d in $Versions.CommunityDashboards) { $keepDash[(Join-Path $d.Folder $d.File).ToLowerInvariant()] = $true }
foreach ($f in Get-ChildItem -LiteralPath $dashRoot -Recurse -File -Filter '*.json') {
    $rel = $f.FullName.Substring($dashRoot.Length).TrimStart('\')
    if (-not $keepDash.ContainsKey($rel.ToLowerInvariant())) {
        Remove-Item -LiteralPath $f.FullName -Force
        Write-Warn "Usunięto nieaktualny dashboard: $rel"
    }
}
# {{DOCS_URL}} w linkach "Dokumentacja" = dokumentacja zainstalowanej wersji w publicznym repozytorium
$docsUrl = Get-StackDocsUrl -Release $Release
foreach ($f in Get-ChildItem -LiteralPath $repoDashRoot -Recurse -File -Filter '*.json') {
    $rel = $f.FullName.Substring($repoDashRoot.Length).TrimStart('\')
    $dst = Join-Path $dashRoot $rel
    New-Directory (Split-Path -Parent $dst)
    Write-Utf8NoBom -Path $dst -Content ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8).Replace('{{DOCS_URL}}', $docsUrl))
}
Write-Ok "Dashboardy z paczki skopiowane (dokumentacja: $docsUrl)."
if (-not $SkipCommunityDashboards) {
    foreach ($d in $Versions.CommunityDashboards) {
        $folder = Join-Path $dashRoot $d.Folder
        New-Directory $folder
        $out = Join-Path $folder $d.File
        try {
            Invoke-Download -Url "https://grafana.com/api/dashboards/$($d.Id)/revisions/latest/download" -Destination $out -Retries 2
            $json = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)
            $json = [regex]::Replace($json, '\$\{DS_[A-Z0-9_]+\}', 'prometheus')
            Write-Utf8NoBom -Path $out -Content $json
            Write-Ok "grafana.com #$($d.Id) -> $($d.Folder)\$($d.File)"
        } catch {
            Write-Warn "Nie pobrano dashboardu #$($d.Id): $($_.Exception.Message)"
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------
Write-Step 'Rejestracja usług Windows (WinSW)'
$cfg = $Layout.Config
$dat = $Layout.Data

Install-WinSWService -Id $ServiceIds.Prometheus -DisplayName 'Observability - Prometheus' `
    -Description 'Prometheus - metryki (stos obserwowalności WEBCON)' `
    -Executable $Exe.Prometheus `
    -Arguments ("--config.file=`"$cfg\prometheus\prometheus.yml`" --storage.tsdb.path=`"$dat\prometheus`" " +
                "--storage.tsdb.retention.time=$($RetentionMetricsDays)d --web.listen-address=127.0.0.1:9090 " +
                "--web.enable-remote-write-receiver --web.enable-lifecycle --enable-feature=exemplar-storage") `
    -WorkingDirectory "$dat\prometheus" -LogDirectory "$($Layout.Logs)\prometheus" `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

Install-WinSWService -Id $ServiceIds.Loki -DisplayName 'Observability - Loki' `
    -Description 'Grafana Loki - logi (stos obserwowalności WEBCON)' `
    -Executable $Exe.Loki -Arguments "-config.file=`"$cfg\loki\loki.yaml`"" `
    -WorkingDirectory "$dat\loki" -LogDirectory "$($Layout.Logs)\loki" `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

Install-WinSWService -Id $ServiceIds.Tempo -DisplayName 'Observability - Tempo' `
    -Description 'Grafana Tempo - ślady OTLP (stos obserwowalności WEBCON)' `
    -Executable $Exe.Tempo -Arguments "-config.file=`"$cfg\tempo\tempo.yaml`"" `
    -WorkingDirectory "$dat\tempo" -LogDirectory "$($Layout.Logs)\tempo" `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

Install-WinSWService -Id $ServiceIds.Alloy -DisplayName 'Observability - Alloy' `
    -Description 'Grafana Alloy - collector OTLP/metryk/logów (stos obserwowalności WEBCON)' `
    -Executable $Exe.Alloy `
    -Arguments ("run `"$cfg\alloy\config.alloy`" --storage.path=`"$dat\alloy`" " +
                "--server.http.listen-addr=127.0.0.1:12345 --disable-reporting") `
    -WorkingDirectory "$dat\alloy" -LogDirectory "$($Layout.Logs)\alloy" `
    -DependsOn @($ServiceIds.Prometheus, $ServiceIds.Loki, $ServiceIds.Tempo) `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

$grafanaHome = Split-Path -Parent (Split-Path -Parent $Exe.Grafana)
Install-WinSWService -Id $ServiceIds.Grafana -DisplayName 'Observability - Grafana' `
    -Description 'Grafana - wizualizacja (stos obserwowalności WEBCON)' `
    -Executable $Exe.Grafana `
    -Arguments "server --homepath `"$grafanaHome`" --config `"$cfg\grafana\grafana.ini`"" `
    -WorkingDirectory $grafanaHome -LogDirectory "$($Layout.Logs)\grafana" `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

# ---------------------------------------------------------------------
Write-Step 'Start usług'
$ready = [ordered]@{
    Prometheus = 'http://127.0.0.1:9090/-/ready'
    Loki       = 'http://127.0.0.1:3100/ready'
    Tempo      = 'http://127.0.0.1:3200/ready'
    Alloy      = 'http://127.0.0.1:12345/-/ready'
    Grafana    = 'http://127.0.0.1:3000/api/health'
}
$failed = @()
foreach ($name in $ready.Keys) {
    Start-Service -Name $ServiceIds[$name]
    # Loki/Tempo zgłaszają gotowość po ~15-30 s (ring)
    if (Wait-HttpReady -Url $ready[$name] -TimeoutSec 120) {
        Write-Ok "$name gotowy ($($ready[$name]))"
    } else {
        Write-Warn "$name nie zgłosił gotowości - sprawdź $($Layout.Logs)\$($name.ToLower())"
        $failed += $name
    }
}

# ---------------------------------------------------------------------
Write-Step 'Firewall'
$rules = @()
if ($GrafanaListenAll) { $rules += @{ Name = 'Observability - Grafana'; Port = 3000 } }
if ($OtlpListenAll)    { $rules += @{ Name = 'Observability - OTLP'; Port = '4317,4318' } }
# Agenci: bez TLS i uwierzytelnienia - jedyną ochroną jest ograniczenie do adresów hostów agentów
if ($RemoteMode) { $rules += @{ Name = 'Observability - Agenci'; Port = "4317,4318,$ReceivePort"; RemoteAddress = $AgentAddress } }
Get-NetFirewallRule -DisplayName 'Observability - Agenci' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
foreach ($rule in $rules) {
    Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $ports = @($rule.Port -split ',')
    $fw = @{ DisplayName = $rule.Name; Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = $ports; Action = 'Allow'; Profile = @('Domain', 'Private') }
    $from = ''
    if ($rule.ContainsKey('RemoteAddress')) {
        # adresy jawne - profil nie ogranicza (VM w sieci rozpoznanej jako Public)
        $fw.RemoteAddress = $rule.RemoteAddress
        $fw.Profile = 'Any'
        $from = ", z: $($rule.RemoteAddress -join ', ')"
    }
    New-NetFirewallRule @fw | Out-Null
    Write-Ok "Reguła '$($rule.Name)' (TCP $($rule.Port)$from)"
}
if (-not $rules) { Write-Ok 'Brak zmian - wszystkie usługi tylko na localhost.' }

# ---------------------------------------------------------------------
$BundleDir = $null
if ($RemoteMode) {
    Write-Step 'Paczka agenta (hosty WEBCON / SQL)'
    $BundleDir = New-AgentBundle -Layout $Layout -RepoRoot $RepoRoot -Versions $Versions -WebconHost $WebconHost -SqlHost $SqlHost -Settings ([ordered]@{
        GeneratedAt          = (Get-Date).ToString('s')
        EnvironmentName      = $EnvironmentName
        CentralAddress       = $CentralAddress
        CentralIPv4          = @($CentralIPv4)
        AgentAddress         = @($AgentAddress)
        OtlpPort             = 4317
        ReceivePort          = $ReceivePort
        WebconHost           = $WebconHost
        SqlHost              = $SqlHost
        SqlInstanceName      = $SqlInstanceName
        SqlPort              = $SqlPort
        SqlEncrypt           = $SqlEncrypt
        SqlTrustServerCertificate = $SqlTrustServerCertificate
        WebconContentDatabase = $WebconContentDatabase
        WebconDbMetrics      = [bool]$WebconDbMetrics
        PortalProbe          = [bool]$PortalProbe
        ExporterLogin        = $AgentExporterLogin
        ReaderLogin          = $(if ($EnableWebconSql) { $WebconSqlReaderLogin } else { '' })
        SqlSpanThresholdNs   = $thresholdNs
        SqlSpanThresholdText = $thresholdText
        AlloyMemoryLimit     = $AlloyMemoryLimit
        ProcessInclude       = $ProcessInclude
    }) -Secrets @{ ExporterPassword = $AgentExporterPlain; ReaderPassword = $WebconSqlReaderPlain } -Release $Release
}

# ---------------------------------------------------------------------
Save-InstallSettings -Layout $Layout -Settings @{
    Root                    = $Layout.Root
    EnvironmentName         = $EnvironmentName
    InstalledAt             = (Get-Date).ToString('s')
    StackVersion            = $Release.Version
    StackCommit             = $Release.Commit
    InstalledFrom           = $RepoRoot
    Versions                = @{
        Alloy = $Versions.Alloy.Version; Prometheus = $Versions.Prometheus.Version; Tempo = $Versions.Tempo.Version
        Loki = $Versions.Loki.Version; Grafana = $Versions.Grafana.Version; WinSW = $Versions.WinSW.Version
    }
    SqlServer               = $SqlServer
    SqlLogin                = $SqlLogin
    WebconSqlReaderLogin    = $WebconSqlReaderLogin
    WebconSqlServer         = $WebconSqlServer
    WebconContentDatabase   = $WebconContentDatabase
    RetentionTracesDays     = $RetentionTracesDays
    SqlSpanThresholdSeconds = $SqlSpanThresholdSeconds
    ServiceLogPath          = $ServiceLogPath
    WebconPortalServiceName  = [string]$WebconPortalServiceName
    WebconServiceServiceName = [string]$WebconServiceServiceName
    PortalProbe             = [bool]$PortalProbe
    ProbeUrl                = @($ProbeUrl)
    WebconDbMetrics         = [bool]$WebconDbMetrics
    ServiceIds              = $ServiceIds
    WebconHost              = $WebconHost
    SqlHost                 = $SqlHost
    SqlInstanceName         = $SqlInstanceName
    SqlPort                 = $SqlPort
    CentralAddress          = $CentralAddress
    AgentAddress            = @($AgentAddress | Where-Object { $_ })
}

Write-Step 'Kopia plików instalacyjnych'
$AppDir = Copy-StackApp -SourceRoot $RepoRoot -Layout $Layout -Release $Release -Files $PackageFiles

if ($ConfigureWebcon) {
    Write-Step 'Konfiguracja OpenTelemetry w WEBCON'
    $sqlMode = 'Threshold'
    if ($thresholdNs -eq 0) { $sqlMode = 'All' }
    & (Join-Path $RepoRoot 'scripts\Set-WebconTelemetry.ps1') -SqlTracing $sqlMode
}

# ---------------------------------------------------------------------
Write-Host ''
Write-Host 'Podsumowanie' -ForegroundColor White
Write-Info "Grafana     http://localhost:3000  (admin / hasło: $grafanaPwdFile)"
if ($newGrafanaPassword) { Write-Info "            Nowe hasło admina: $newGrafanaPassword" }
Write-Info 'OTLP        http://localhost:4318 (HTTP), localhost:4317 (gRPC)'
Write-Info 'Alloy UI    http://localhost:12345'
Write-Info 'Prometheus  http://localhost:9090'
Write-Info "Próg SQL    $thresholdText"
Write-Info "Logi usług  $($Layout.Logs)"
Write-Info "Wersja      $($Release.Version); skrypty (smoke test, odinstalowanie, zmiana parametrów): $AppDir"
if (-not (Test-PathInside -Path $RepoRoot -Parent $AppDir)) { Write-Info "            Pliki instalacyjne ($RepoRoot) można usunąć." }
if ($RemoteMode) {
    Write-Host ''
    Write-Host 'Następne kroki (agenci)' -ForegroundColor White
    Write-Info "1. Skopiuj $BundleDir.zip na hosty docelowe i rozpakuj (np. C:\Install\agent-bundle)."
    Write-Info '   Paczka zawiera hasła loginów SQL - usuń ją z hostów po instalacji.'
    $n = 2
    foreach ($w in (Get-ChildItem -LiteralPath $BundleDir -Filter '0*.ps1' | Sort-Object Name)) {
        Write-Info "$n. $($w.Name)  (PowerShell jako administrator, na hoście z nazwy pliku)"
        $n++
    }
    Write-Info "$n. Tutaj: $AppDir\Test-ObservabilityStack.ps1"
    Write-Info "Szczegóły: $BundleDir\README.txt"
} else {
    if (-not $ConfigureWebcon) {
        Write-Info "WEBCON      uruchom $AppDir\scripts\Set-WebconTelemetry.ps1, aby skierować telemetrię do Alloy."
    }
    Write-Info "Test        $AppDir\Test-ObservabilityStack.ps1"
}
if ($failed) {
    Write-Warn "Nie wystartowały poprawnie: $($failed -join ', ')"
    exit 1
}
