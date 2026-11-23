#Requires -Version 5.1
<#
.SYNOPSIS
    Installs a self-hosted observability stack for WEBCON on Windows Server:
    Grafana Alloy (collector) + Prometheus (metrics) + Tempo (OTLP traces) + Loki (logs) + Grafana.

.DESCRIPTION
    All components run as Windows services (WinSW) and listen on localhost
    (except Grafana with -GrafanaListenAll). The script is idempotent - running it again
    updates versions (versions.psd1) and configurations (config-templates).

.PARAMETER Root
    Installation directory (bin, config, data, logs, services, secrets).

.PARAMETER SqlServer
    SQL Server instance to monitor (e.g. "SQLDEV01", "SQLDEV01\BPS", "SQLDEV01,1433").
    Omitted = interactive prompt; empty = no SQL Server metrics.

.PARAMETER SqlLogin
    Dedicated SQL login for the exporter. The password is prompted for interactively (or -SqlPassword).
    Permissions are verified before installation (VIEW SERVER STATE, VIEW ANY DEFINITION).

.PARAMETER WebconSqlReaderLogin
    Read-only SQL login for the "WEBCON SQL" Grafana data source (WEBCON – Operations dashboard),
    with permissions from sql\grant-webcon-reader-permissions.sql. Password: -WebconSqlReaderPassword, the existing
    grafana-sql-reader.txt secret or an interactive prompt. Omitted = keep the previous configuration;
    empty = no SQL data source.

.PARAMETER WebconSqlServer
    SQL Server instance hosting the WEBCON content database. Defaults to -SqlServer.

.PARAMETER WebconContentDatabase
    WEBCON content database (default: WEBCON_Content).

.PARAMETER SqlSpanThresholdSeconds
    SQL spans shorter than the threshold are dropped in Alloy. 0 = keep all.

.PARAMETER ServiceLogPath
    Glob for the Serilog log files of the WEBCON WorkFlow Service (e.g. 'D:\WEBCON\Service\Logs\*.log').
    Empty = Service logs are not collected from files.

.PARAMETER WebconPortalServiceName
    Fallback service name mapping: the service name (ServiceName from WEBCON appsettings) under which the Portal sends telemetry
    WITHOUT the webcon.component marker (Set-WebconTelemetry.ps1 sets the marker - the parameter is then unnecessary).
    Alloy replaces it with "Portal". Omitted = previous value; empty = no mapping.

.PARAMETER WebconServiceServiceName
    Like -WebconPortalServiceName, for the WEBCON WorkFlow Service (replaced with "WebCon.WorkFlow").

.PARAMETER PortalProbe
    WEBCON Portal availability probe (/health) at the -PortalUrl address (default: $true).
    In remote mode the probe is run by the agent on the WEBCON host. Omitted = previous value.

.PARAMETER PortalUrl
    Main WEBCON Portal address, the one users open, e.g. https://bps.example.com. The probe connects locally
    on the WEBCON host and verifies the certificate for the host name from this address. Without the parameter
    the installer asks (suggestion from IIS bindings with a host name); -NonInteractive - address from an IIS
    binding with a host name; with bindings without a name (*) the probe is skipped. Omitted = previous value;
    '' = detection from IIS.

.PARAMETER ProbeUrl
    Additional HTTP(S) addresses to check for availability (2xx code), e.g. the production Portal or a load balancer.
    Omitted = previous list; '' = no additional addresses.

.PARAMETER WebconDbMetrics
    Metrics from the WEBCON content database (overdue timeouts, cyclical actions, email queue, queue and log table sizes).
    Requires SQL metrics and column-level permissions for the exporter login (sql\grant-webcon-db-metrics.sql); missing permissions
    = warning, the installation continues. Omitted = previous value.

.PARAMETER AllowDowngrade
    Allows installing a version older than the installed one (configuration and alert rules of the newer version may not match
    the older one). Without this switch, a downgrade stops the installation.

.PARAMETER ConfigureWebcon
    After installation, runs scripts\Set-WebconTelemetry.ps1 (OpenTelemetry configuration in WEBCON appsettings).

.PARAMETER WebconHost
    Remote mode: the WEBCON host (Portal + Service). The installer generates an agent bundle (C:\Observability\agent-bundle + .zip)
    with scripts to run on the target hosts. Omitted = keep the previous configuration; empty = no host.

.PARAMETER SqlHost
    Remote mode: the SQL Server host with the WEBCON databases. SQL metrics are collected by the agent on that host (do not specify -SqlServer).
    The exporter and Grafana reader logins are created by the SQL host script with passwords generated here.

.PARAMETER SqlInstanceName
    Remote mode: instance name on -SqlHost (MSSQLSERVER = default instance, e.g. SQLEXPRESS).

.PARAMETER SqlPort
    Remote mode: TCP port of the instance ('WEBCON SQL' data source in Grafana; -EnableSqlTcp on the SQL host sets it as static).

.PARAMETER CentralAddress
    Address of this VM as seen from the agent hosts. Defaults to the FQDN.

.PARAMETER AgentAddress
    IP addresses of the agent hosts allowed in the firewall (OTLP 4317/4318, remote write 9999). Defaults to DNS of -WebconHost / -SqlHost.

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
    # 8 days: the WEBCON – Operations dashboard has a 7-day range; with 7 days the oldest day would be partially deleted
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
    [string]$PortalUrl,
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
Write-Host "Observability Stack (WEBCON) $($Release.Version) - installation" -ForegroundColor White
Write-Host "Directory: $($Layout.Root)   Installation files: $RepoRoot" -ForegroundColor White
Write-StackDisclaimer
Write-Host ''

$previous = Get-InstallSettings -Root $Layout.Root

# ---------------------------------------------------------------------
# Version and location of the installation files (docs/projekt/projekt-dystrybucja-i-wersje.md)
Write-Step 'Version'
Assert-InstallLocation -SourceRoot $RepoRoot -Layout $Layout
$PreviousVersion = ''
if ($previous -and $previous.StackVersion) { $PreviousVersion = [string]$previous.StackVersion }
if (-not $previous) {
    Write-Ok "Installing $($Release.Version)"
} elseif (-not $PreviousVersion) {
    Write-Ok "Upgrading a pre-release installation -> $($Release.Version)"
} else {
    $cmp = (ConvertTo-StackVersion $Release.Version).CompareTo((ConvertTo-StackVersion $PreviousVersion))
    if ($cmp -lt 0) {
        if (-not $AllowDowngrade) {
            throw ("The installed version ($PreviousVersion) is newer than the one being installed ($($Release.Version)). Configuration and alert " +
                   "rules of the newer version may not match the older one - use a newer package or -AllowDowngrade.")
        }
        Write-Warn "Downgrading $PreviousVersion -> $($Release.Version) (-AllowDowngrade)"
    } elseif ($PreviousVersion -eq $Release.Version) {
        Write-Ok "Reinstalling $($Release.Version)"
    } else {
        Write-Ok "Upgrading $PreviousVersion -> $($Release.Version)"
    }
}
if ($Release.Dev) { Write-Info 'Development version (repository clone) - documentation links point to the latest release (/latest).' }
# Files from a ZIP downloaded from the internet (Zone.Identifier) - the copy in app\ must be unblocked
foreach ($f in $PackageFiles) { Unblock-File -LiteralPath (Join-Path $RepoRoot $f) -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------
# Remote mode (agents on the WEBCON / SQL hosts). An upgrade without -WebconHost/-SqlHost keeps the previous hosts.
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
    Write-Step 'Remote mode (agents)'
    if ($PSBoundParameters.ContainsKey('SqlServer') -and $SqlServer) {
        throw 'In remote mode SQL metrics are collected by the agent on the SQL host (-SqlHost) - do not specify -SqlServer.'
    }
    # The mssql exporter does not run on the stack VM - skip the exporter login section (as with -SqlServer '')
    $SqlServer = ''
    $PSBoundParameters['SqlServer'] = ''
    if (-not $CentralAddress) { $CentralAddress = [Net.Dns]::GetHostEntry('').HostName }
    if (-not $AgentAddress) {
        $AgentAddress = @()
        foreach ($h in @($WebconHost, $SqlHost) | Where-Object { $_ } | Select-Object -Unique) {
            try {
                $AgentAddress += @([Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() })
            } catch {
                throw "Cannot resolve the IP address of host $h (DNS) - specify -AgentAddress."
            }
        }
        $AgentAddress = @($AgentAddress | Select-Object -Unique)
    }
    $CentralIPv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Select-Object -ExpandProperty IPAddress)
    if ($WebconHost) { Write-Ok "WEBCON host: $WebconHost" }
    if ($SqlHost)    { Write-Ok "SQL host:    $SqlHost (instance $SqlInstanceName, port $SqlPort)" }
    Write-Ok "Stack address for agents: $CentralAddress; firewall allows: $($AgentAddress -join ', ')"
    $Ports.Add($ReceivePort, 'Alloy remote write (agents)')
}

# ---------------------------------------------------------------------
Write-Step 'Directories'
foreach ($k in 'Root', 'Bin', 'Config', 'Data', 'Logs', 'Services', 'Downloads') { New-Directory $Layout[$k] }
Protect-SecretsDirectory -Path $Layout.Secrets
Write-Ok 'Directory structure ready (secrets: ACL SYSTEM + Administrators).'

# ---------------------------------------------------------------------
Write-Step 'Stopping existing stack services (upgrade)'
# Reverse order (Grafana first): if Grafana is still running after Prometheus / Loki stop, it evaluates alert rules
# with a "connection refused" error, saves that state and restores it after start ("Warming state cache") - false
# evaluation errors in the smoke test until the next evaluation (1 min).
$stopOrder = @($ServiceIds.Values)
[array]::Reverse($stopOrder)
foreach ($id in $stopOrder) {
    $svc = Get-Service -Name $id -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $id -Force
        $null = $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        Write-Ok "Stopped $id"
    }
}

Write-Step 'Checking free ports'
$busy = @()
foreach ($p in $Ports.Keys) {
    if (Test-TcpPortInUse -Port $p) { $busy += "$p ($($Ports[$p])) in use by $(Get-PortOwner -Port $p)" }
}
if ($busy) { throw ("Ports in use:`n  " + ($busy -join "`n  ") + "`nFree the ports (e.g. a local Jaeger/Seq) and run again.") }
Write-Ok 'All ports are free.'

# ---------------------------------------------------------------------
Write-Step 'SQL Server - exporter login'
$EnableMssql = $false
$ReuseMssql = $false
$MssqlConnString = $null
# Upgrade: without -SqlServer keep the login from the previous installation (mssql.conn secret); -SqlServer '' disables SQL
if (-not $PSBoundParameters.ContainsKey('SqlServer') -and $previous -and $previous.SqlServer -and
    (Test-Path -LiteralPath (Join-Path $Layout.Secrets 'mssql.conn'))) {
    $SqlServer = $previous.SqlServer
    $SqlLogin = $previous.SqlLogin
    $ReuseMssql = $true
    $EnableMssql = $true
    Write-Ok "Kept the exporter login from the previous installation ($SqlLogin @ $SqlServer). To change: -SqlServer/-SqlLogin, to disable: -SqlServer ''."
}
if (-not $ReuseMssql -and -not $PSBoundParameters.ContainsKey('SqlServer') -and -not $NonInteractive) {
    $SqlServer = Read-Host 'SQL Server instance to monitor (Enter = skip SQL metrics)'
}
if ($ReuseMssql) {
    # no changes - the mssql.conn secret stays
} elseif ($SqlServer) {
    if (-not $SqlLogin) {
        if ($NonInteractive) { throw 'Specify -SqlLogin.' }
        $SqlLogin = Read-Host "Exporter SQL login for $SqlServer"
    }
    if (-not $SqlPassword) {
        if ($NonInteractive) { throw 'Specify -SqlPassword.' }
        $SqlPassword = Read-Host "Password for $SqlLogin" -AsSecureString
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
            Write-Host 'Missing permissions - to be run by a DBA:' -ForegroundColor Yellow
            Write-Host $result.Remediation
            Write-Host ''
        }
        throw 'SQL login verification failed. Fix the permissions and run the installation again (or skip SQL metrics with an empty -SqlServer).'
    }
    $MssqlConnString = New-MssqlExporterConnectionString -Server $SqlServer -Login $SqlLogin -Password (ConvertFrom-SecureStringPlain $SqlPassword) -Encrypt $SqlEncrypt -TrustServerCertificate $SqlTrustServerCertificate
    $EnableMssql = $true
} elseif ($RemoteMode -and $SqlHost) {
    Write-Ok "SQL Server metrics are collected by the agent on host $SqlHost."
} else {
    Write-Warn 'SQL Server metrics skipped.'
}

# ---------------------------------------------------------------------
Write-Step 'SQL Server - Grafana data source (WEBCON content database)'
$EnableWebconSql = $false
$WebconSqlReaderPlain = $null
$saveReaderPwd = $false   # password from a parameter or Read-Host (not from an existing secret) - to be saved
$readerPwdFile = Join-Path $Layout.Secrets 'grafana-sql-reader.txt'
if ($RemoteMode) {
    # The login is created by the SQL host script from the agent bundle (password generated here) - verification: Test-ObservabilityStack.ps1 after the agent is installed
    if (-not $PSBoundParameters.ContainsKey('WebconSqlReaderLogin')) {
        $WebconSqlReaderLogin = 'svc_obs_grafana_reader'
        # previous choice only from a remote-mode installation ('' = deliberately disabled); in local mode an empty login = no data source
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
        Write-Ok "Data source 'WEBCON SQL': $WebconSqlReaderLogin @ $WebconSqlServer / $WebconContentDatabase (the login will be created by the SQL host script)"
    } else {
        Write-Warn "Data source 'WEBCON SQL' skipped (the WEBCON – Operations dashboard has no database panels)."
    }
} else {
    # Upgrade: without -WebconSqlReaderLogin keep the previous configuration; -WebconSqlReaderLogin '' disables the data source
    $reuseReader = $false
    if (-not $PSBoundParameters.ContainsKey('WebconSqlReaderLogin') -and $previous -and $previous.WebconSqlReaderLogin) {
        $WebconSqlReaderLogin = $previous.WebconSqlReaderLogin
        if (-not $PSBoundParameters.ContainsKey('WebconSqlServer')) { $WebconSqlServer = $previous.WebconSqlServer }
        if (-not $PSBoundParameters.ContainsKey('WebconContentDatabase')) { $WebconContentDatabase = $previous.WebconContentDatabase }
        $reuseReader = $true
    }
    if (-not $WebconSqlServer) { $WebconSqlServer = $SqlServer }
    if ($WebconSqlReaderLogin) {
        if (-not $WebconSqlServer) { throw 'Specify -WebconSqlServer (instance hosting the WEBCON content database) or -SqlServer.' }
        if ($WebconSqlReaderPassword) {
            $WebconSqlReaderPlain = ConvertFrom-SecureStringPlain $WebconSqlReaderPassword
            $saveReaderPwd = $true
        } elseif ((Test-Path -LiteralPath $readerPwdFile) -and
                  ($reuseReader -or ($previous -and $previous.WebconSqlReaderLogin -eq $WebconSqlReaderLogin))) {
            # the secret belongs to the same login (a new login without -WebconSqlReaderPassword = password prompt)
            $WebconSqlReaderPlain = [IO.File]::ReadAllText($readerPwdFile, [Text.Encoding]::UTF8)
            Write-Ok 'Login password taken from the existing grafana-sql-reader.txt secret.'
        } elseif ($NonInteractive) {
            throw "Specify -WebconSqlReaderPassword (login $WebconSqlReaderLogin; the grafana-sql-reader.txt secret belongs to a different login or does not exist)."
        } else {
            $WebconSqlReaderPlain = ConvertFrom-SecureStringPlain (Read-Host "Password for $WebconSqlReaderLogin" -AsSecureString)
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
            Write-Ok "Data source 'WEBCON SQL': $WebconSqlReaderLogin @ $WebconSqlServer / $WebconContentDatabase"
        } elseif ($reuseReader) {
            # E.g. a WEBCON upgrade recreated the tables and removed the permissions - do not block the stack upgrade
            Write-Warn "Data source 'WEBCON SQL' skipped - run sql\grant-webcon-reader-permissions.sql and the installer again."
        } else {
            throw "Verification of login $WebconSqlReaderLogin failed. Run sql\grant-webcon-reader-permissions.sql (DBA) or skip the data source with an empty -WebconSqlReaderLogin."
        }
    } else {
        Write-Warn "Data source 'WEBCON SQL' skipped (the WEBCON – Operations dashboard has no database panels)."
    }
}

# ---------------------------------------------------------------------
# Availability and WEBCON database metrics (docs/projekt/projekt-dostepnosc-i-metryki-bazy.md)
Write-Step 'Portal availability (HTTP probes)'
if (-not $PSBoundParameters.ContainsKey('PortalProbe') -and $previous -and $null -ne $previous.PortalProbe) { $PortalProbe = [bool]$previous.PortalProbe }
if (-not $PSBoundParameters.ContainsKey('ProbeUrl') -and $previous -and $previous.ProbeUrl) { $ProbeUrl = @($previous.ProbeUrl) }
$ProbeUrl = @($ProbeUrl | Where-Object { $_ })
foreach ($u in $ProbeUrl) {
    if ($u -notmatch '^https?://[^\s"`\\]+$') { throw "-ProbeUrl: invalid address '$u' (expected http:// or https://)." }
}
# Portal address (docs/projekt/projekt-sonda-portalu-adres.md): parameter > previous value > prompt (suggestion from IIS)
$portalUrlKnown = $PSBoundParameters.ContainsKey('PortalUrl')
if (-not $portalUrlKnown -and $previous -and $null -ne $previous.PortalUrl) { $PortalUrl = [string]$previous.PortalUrl; $portalUrlKnown = $true }
if ($PortalUrl) { $PortalUrl = ConvertTo-PortalUrl $PortalUrl } else { $PortalUrl = '' }
$PortalBindings = @()
if ($PortalProbe -and -not $RemoteMode) { $PortalBindings = Get-WebconPortalBinding }   # returns an array (return ,) - no @()
if ($PortalProbe -and -not $portalUrlKnown -and -not $NonInteractive) {
    $suggestion = Get-PortalUrlSuggestion -Binding $PortalBindings
    $prompt = 'Main Portal address to monitor, e.g. https://bps.example.com'
    if ($suggestion) { $prompt = "$prompt (Enter = $suggestion)" }
    elseif ($RemoteMode) { $prompt = "$prompt (Enter = detection from IIS bindings by the agent)" }
    else { $prompt = "$prompt (Enter = no Portal probe)" }
    $answer = (Read-Host $prompt).Trim()
    if (-not $answer) { $answer = $suggestion }
    if ($answer) { $PortalUrl = ConvertTo-PortalUrl $answer }
}
$PortalTarget = $null
if (-not $PortalProbe) {
    Write-Info 'Portal probe disabled (-PortalProbe $false).'
} elseif ($RemoteMode) {
    if ($PortalUrl) { Write-Ok "Portal: $PortalUrl - probe in the agent on the WEBCON host." }
    else { Write-Info 'Portal probe: agent on the WEBCON host - address from IIS bindings with a host name (-PortalUrl sets the address).' }
} else {
    $resolved = Resolve-PortalProbeTarget -PortalUrl $PortalUrl -Binding $PortalBindings
    foreach ($m in $resolved.Messages) {
        switch ($m.Level) { 'ok' { Write-Ok $m.Text } 'warn' { Write-Warn $m.Text } default { Write-Info $m.Text } }
    }
    $PortalTarget = $resolved.Target
}
foreach ($u in $ProbeUrl) { Write-Ok "Additional address: $u" }
$Blackbox = New-BlackboxConfig -PortalTarget $PortalTarget -ProbeUrl $ProbeUrl

Write-Step 'WEBCON content database metrics'
if (-not $PSBoundParameters.ContainsKey('WebconDbMetrics') -and $previous -and $null -ne $previous.WebconDbMetrics) { $WebconDbMetrics = [bool]$previous.WebconDbMetrics }
if (-not $PSBoundParameters.ContainsKey('WebconContentDatabase') -and $previous -and $previous.WebconContentDatabase) { $WebconContentDatabase = $previous.WebconContentDatabase }
if ($WebconContentDatabase -notmatch '^[^\[\]''";]+$') { throw "-WebconContentDatabase: invalid characters in database name '$WebconContentDatabase'." }
$EnableWebconDb = $false
if (-not $WebconDbMetrics) {
    Write-Info 'Disabled (-WebconDbMetrics $true enables them).'
} elseif ($RemoteMode) {
    if ($SqlHost) { Write-Ok "Collected by the agent on host $SqlHost (database $WebconContentDatabase; permissions are granted by the SQL host script)." }
    else { Write-Warn 'Skipped - remote mode without -SqlHost.' }
} elseif (-not $EnableMssql) {
    Write-Warn 'Skipped - they require SQL Server metrics (-SqlServer / -SqlLogin).'
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
    # Missing permissions do not block the installation (D5) - the error is visible only in the integrations/mssql-webcon job
    $EnableWebconDb = $true
    if ($result.Success) {
        Write-Ok "Database metrics: $dbLogin @ $dbServer / $WebconContentDatabase"
    } else {
        Write-Warn "Missing permissions - DBA: sql\grant-webcon-db-metrics.sql (@login = N'$dbLogin', @databases = N'$WebconContentDatabase'). Metrics will appear without reinstalling."
    }
    $dbPassword = $null
}

# ---------------------------------------------------------------------
Write-Step 'Downloading and installing binaries'
$Exe = @{}
foreach ($name in 'WinSW', 'Prometheus', 'Loki', 'Tempo', 'Alloy', 'Grafana') {
    $Exe[$name] = Install-StackComponent -Name $name -Definition $Versions[$name] -Layout $Layout -Force:$ForceDownload
}

# ---------------------------------------------------------------------
Write-Step 'Secrets'
$grafanaPwdFile = Join-Path $Layout.Secrets 'grafana-admin.txt'
$newGrafanaPassword = $null
if (-not (Test-Path -LiteralPath $grafanaPwdFile)) {
    $newGrafanaPassword = New-RandomPassword
    Set-SecretFile -Path $grafanaPwdFile -Content $newGrafanaPassword
    Write-Ok 'Generated the Grafana admin password.'
} else {
    Write-Ok 'Grafana admin password already exists (unchanged).'
}
$mssqlConnFile = Join-Path $Layout.Secrets 'mssql.conn'
if ($EnableMssql -and -not $ReuseMssql) {
    Set-SecretFile -Path $mssqlConnFile -Content $MssqlConnString
    Write-Ok 'Saved the SQL exporter connection string.'
}
if ($EnableWebconSql -and $saveReaderPwd) {
    Set-SecretFile -Path $readerPwdFile -Content $WebconSqlReaderPlain
    Write-Ok 'Saved the password of the WEBCON SQL data source login.'
}
# Remote mode: password of the mssql exporter login (agent on the SQL host) - stored here so that a reinstallation produces the same bundle
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
        Write-Ok 'Generated the SQL exporter login password (agent on the SQL host).'
    }
}

# ---------------------------------------------------------------------
Write-Step 'Generating configuration'
$thresholdNs = [int64]([math]::Round($SqlSpanThresholdSeconds * 1e9))
$thresholdText = "$SqlSpanThresholdSeconds s"
if ($thresholdNs -eq 0) { $thresholdText = 'disabled - all SQL spans are kept' }

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
    # Grafana alerts (provisioning\alerting): stack host, data volume, WEBCON hosts excluded from alert W9
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
    # Grafana (go-mssqldb): host:port or host\instance
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

# Fallback mapping of WEBCON service names without the webcon.component marker (docs/projekt/projekt-nazwy-uslug-webcon.md)
foreach ($k in 'WebconPortalServiceName', 'WebconServiceServiceName') {
    if (-not $PSBoundParameters.ContainsKey($k) -and $previous -and $previous.$k) { Set-Variable -Name $k -Value $previous.$k }
    $v = Get-Variable -Name $k -ValueOnly
    if ($v -and $v -notmatch '^[A-Za-z0-9_.:\-]+$') { throw "-$k contains invalid characters: '$v' (allowed: letters, digits, _ . : -)." }
}
if ($WebconPortalServiceName -and $WebconPortalServiceName -eq $WebconServiceServiceName) {
    throw "-WebconPortalServiceName and -WebconServiceServiceName have the same value ('$WebconPortalServiceName') - the Portal and the Service cannot be told apart by name. Run scripts\Set-WebconTelemetry.ps1 (webcon.component marker)."
}
$vars.WEBCON_PORTAL_SERVICE_NAME = [string]$WebconPortalServiceName
$vars.WEBCON_SERVICE_SERVICE_NAME = [string]$WebconServiceServiceName
if (-not $WebconPortalServiceName -and -not $WebconServiceServiceName) { $removeBlocks += 'SERVICENAME_FALLBACK' }

# Availability probes and WEBCON database metrics
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
Write-Step 'Validating configuration'
$promtool = Join-Path (Split-Path -Parent $Exe.Prometheus) 'promtool.exe'
if (Test-Path -LiteralPath $promtool) {
    $r = Invoke-NativeTool -FilePath $promtool -Arguments @('check', 'config', (Join-Path $Layout.Config 'prometheus\prometheus.yml'))
    if ($r.ExitCode -ne 0) { throw "promtool: invalid prometheus.yml`n$($r.Output)" }
    Write-Ok 'prometheus.yml'
}
$r = Invoke-NativeTool -FilePath $Exe.Loki -Arguments @("-config.file=$(Join-Path $Layout.Config 'loki\loki.yaml')", '-verify-config')
if ($r.ExitCode -ne 0) { throw "Loki: invalid loki.yaml`n$($r.Output)" }
Write-Ok 'loki.yaml'
$r = Invoke-NativeTool -FilePath $Exe.Alloy -Arguments @('fmt', (Join-Path $Layout.Config 'alloy\config.alloy'))
if ($r.ExitCode -ne 0) { throw "Alloy: config.alloy syntax error (alloy fmt)`n$($r.Output)" }
Write-Ok 'config.alloy (syntax)'

# ---------------------------------------------------------------------
Write-Step 'Grafana dashboards'
$dashRoot = Join-Path $Layout.Config 'grafana\dashboards'
New-Directory $dashRoot
# The directory is fully managed by the installer: remove dashboards that are no longer in the repository
# or in CommunityDashboards (e.g. host\windows-exporter.json = 19957, webcon\webcon-overview.json)
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
        Write-Warn "Removed obsolete dashboard: $rel"
    }
}
# {{DOCS_URL}} in the documentation links = documentation of the installed version in the public repository
$docsUrl = Get-StackDocsUrl -Release $Release
foreach ($f in Get-ChildItem -LiteralPath $repoDashRoot -Recurse -File -Filter '*.json') {
    $rel = $f.FullName.Substring($repoDashRoot.Length).TrimStart('\')
    $dst = Join-Path $dashRoot $rel
    New-Directory (Split-Path -Parent $dst)
    Write-Utf8NoBom -Path $dst -Content ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8).Replace('{{DOCS_URL}}', $docsUrl))
}
Write-Ok "Package dashboards copied (documentation: $docsUrl)."
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
            Write-Warn "Failed to download dashboard #$($d.Id): $($_.Exception.Message)"
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------
Write-Step 'Registering Windows services (WinSW)'
$cfg = $Layout.Config
$dat = $Layout.Data

Install-WinSWService -Id $ServiceIds.Prometheus -DisplayName 'Observability - Prometheus' `
    -Description 'Prometheus - metrics (WEBCON observability stack)' `
    -Executable $Exe.Prometheus `
    -Arguments ("--config.file=`"$cfg\prometheus\prometheus.yml`" --storage.tsdb.path=`"$dat\prometheus`" " +
                "--storage.tsdb.retention.time=$($RetentionMetricsDays)d --web.listen-address=127.0.0.1:9090 " +
                "--web.enable-remote-write-receiver --web.enable-lifecycle --enable-feature=exemplar-storage") `
    -WorkingDirectory "$dat\prometheus" -LogDirectory "$($Layout.Logs)\prometheus" `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

Install-WinSWService -Id $ServiceIds.Loki -DisplayName 'Observability - Loki' `
    -Description 'Grafana Loki - logs (WEBCON observability stack)' `
    -Executable $Exe.Loki -Arguments "-config.file=`"$cfg\loki\loki.yaml`"" `
    -WorkingDirectory "$dat\loki" -LogDirectory "$($Layout.Logs)\loki" `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

Install-WinSWService -Id $ServiceIds.Tempo -DisplayName 'Observability - Tempo' `
    -Description 'Grafana Tempo - OTLP traces (WEBCON observability stack)' `
    -Executable $Exe.Tempo -Arguments "-config.file=`"$cfg\tempo\tempo.yaml`"" `
    -WorkingDirectory "$dat\tempo" -LogDirectory "$($Layout.Logs)\tempo" `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

Install-WinSWService -Id $ServiceIds.Alloy -DisplayName 'Observability - Alloy' `
    -Description 'Grafana Alloy - OTLP/metrics/logs collector (WEBCON observability stack)' `
    -Executable $Exe.Alloy `
    -Arguments ("run `"$cfg\alloy\config.alloy`" --storage.path=`"$dat\alloy`" " +
                "--server.http.listen-addr=127.0.0.1:12345 --disable-reporting") `
    -WorkingDirectory "$dat\alloy" -LogDirectory "$($Layout.Logs)\alloy" `
    -DependsOn @($ServiceIds.Prometheus, $ServiceIds.Loki, $ServiceIds.Tempo) `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

$grafanaHome = Split-Path -Parent (Split-Path -Parent $Exe.Grafana)
Install-WinSWService -Id $ServiceIds.Grafana -DisplayName 'Observability - Grafana' `
    -Description 'Grafana - visualization (WEBCON observability stack)' `
    -Executable $Exe.Grafana `
    -Arguments "server --homepath `"$grafanaHome`" --config `"$cfg\grafana\grafana.ini`"" `
    -WorkingDirectory $grafanaHome -LogDirectory "$($Layout.Logs)\grafana" `
    -WinSWExe $Exe.WinSW -ServicesRoot $Layout.Services

# ---------------------------------------------------------------------
Write-Step 'Starting services'
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
    # Loki/Tempo report readiness after ~15-30 s (ring)
    if (Wait-HttpReady -Url $ready[$name] -TimeoutSec 120) {
        Write-Ok "$name ready ($($ready[$name]))"
    } else {
        Write-Warn "$name did not report readiness - check $($Layout.Logs)\$($name.ToLower())"
        $failed += $name
    }
}

if ($failed -notcontains 'Grafana') {
    # alert folders renamed to English (0.9.x) - remove the old, empty Polish folders
    Remove-GrafanaEmptyFolder -PasswordFile $grafanaPwdFile -Title @(('Stos obserwowalno' + [char]0x015B + 'ci ' + [char]0x2013 + ' alerty'), ('WEBCON ' + [char]0x2013 + ' alerty'))
}

# ---------------------------------------------------------------------
Write-Step 'Firewall'
$rules = @()
if ($GrafanaListenAll) { $rules += @{ Name = 'Observability - Grafana'; Port = 3000 } }
if ($OtlpListenAll)    { $rules += @{ Name = 'Observability - OTLP'; Port = '4317,4318' } }
# Agents: no TLS or authentication - the only protection is restricting access to the agent host addresses
if ($RemoteMode) { $rules += @{ Name = 'Observability - Agenci'; Port = "4317,4318,$ReceivePort"; RemoteAddress = $AgentAddress } }
Get-NetFirewallRule -DisplayName 'Observability - Agenci' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
foreach ($rule in $rules) {
    Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $ports = @($rule.Port -split ',')
    $fw = @{ DisplayName = $rule.Name; Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = $ports; Action = 'Allow'; Profile = @('Domain', 'Private') }
    $from = ''
    if ($rule.ContainsKey('RemoteAddress')) {
        # explicit addresses - no profile restriction (VM on a network identified as Public)
        $fw.RemoteAddress = $rule.RemoteAddress
        $fw.Profile = 'Any'
        $from = ", from: $($rule.RemoteAddress -join ', ')"
    }
    New-NetFirewallRule @fw | Out-Null
    Write-Ok "Rule '$($rule.Name)' (TCP $($rule.Port)$from)"
}
if (-not $rules) { Write-Ok 'No changes - all services listen on localhost only.' }

# ---------------------------------------------------------------------
$BundleDir = $null
if ($RemoteMode) {
    Write-Step 'Agent bundle (WEBCON / SQL hosts)'
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
        PortalUrl            = [string]$PortalUrl
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
    PortalUrl               = [string]$PortalUrl
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

Write-Step 'Copying installation files'
$AppDir = Copy-StackApp -SourceRoot $RepoRoot -Layout $Layout -Release $Release -Files $PackageFiles

if ($ConfigureWebcon) {
    Write-Step 'Configuring OpenTelemetry in WEBCON'
    $sqlMode = 'Threshold'
    if ($thresholdNs -eq 0) { $sqlMode = 'All' }
    & (Join-Path $RepoRoot 'scripts\Set-WebconTelemetry.ps1') -SqlTracing $sqlMode
}

# ---------------------------------------------------------------------
Write-Host ''
Write-Host 'Summary' -ForegroundColor White
Write-Info "Grafana     http://localhost:3000  (admin / password: $grafanaPwdFile)"
if ($newGrafanaPassword) { Write-Info "            New admin password: $newGrafanaPassword" }
Write-Info 'OTLP        http://localhost:4318 (HTTP), localhost:4317 (gRPC)'
Write-Info 'Alloy UI    http://localhost:12345'
Write-Info 'Prometheus  http://localhost:9090'
Write-Info "SQL filter  $thresholdText"
Write-Info "Logs        $($Layout.Logs)"
Write-Info "Version     $($Release.Version); scripts (smoke test, uninstall, parameter changes): $AppDir"
if (-not (Test-PathInside -Path $RepoRoot -Parent $AppDir)) { Write-Info "            The installation files ($RepoRoot) can be deleted." }
if ($RemoteMode) {
    Write-Host ''
    Write-Host 'Next steps (agents)' -ForegroundColor White
    Write-Info "1. Copy $BundleDir.zip to the target hosts and extract it (e.g. C:\Install\agent-bundle)."
    Write-Info '   The bundle contains SQL login passwords - delete it from the hosts after installation.'
    $n = 2
    foreach ($w in (Get-ChildItem -LiteralPath $BundleDir -Filter '0*.ps1' | Sort-Object Name)) {
        Write-Info "$n. $($w.Name)  (PowerShell as administrator, on the host named in the file name)"
        $n++
    }
    Write-Info "$n. Here: $AppDir\Test-ObservabilityStack.ps1"
    Write-Info "Details: $BundleDir\README.txt"
} else {
    if (-not $ConfigureWebcon) {
        Write-Info "WEBCON      run $AppDir\scripts\Set-WebconTelemetry.ps1 to send telemetry to Alloy."
    }
    Write-Info "Test        $AppDir\Test-ObservabilityStack.ps1"
}
if ($failed) {
    Write-Warn "Failed to start correctly: $($failed -join ', ')"
    exit 1
}
