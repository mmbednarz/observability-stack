#Requires -Version 5.1
<#
    Wspólne funkcje stosu obserwowalności WEBCON.
    Kompatybilność: Windows PowerShell 5.1 i PowerShell 7+ (bez ternary, ??, -Parallel).
    Pliki .ps1/.psm1 muszą być zapisane jako UTF-8 z BOM (polskie znaki w PS 5.1).
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------
# Logowanie
# ---------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "    $Message" }

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Skrypt wymaga uruchomienia jako Administrator.'
    }
}

# ---------------------------------------------------------------------
# Układ katalogów
# ---------------------------------------------------------------------
function Get-StackLayout {
    param([Parameter(Mandatory)][string]$Root)
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $layout = [ordered]@{
        Root      = $Root
        Bin       = Join-Path $Root 'bin'
        Config    = Join-Path $Root 'config'
        Data      = Join-Path $Root 'data'
        Logs      = Join-Path $Root 'logs'
        Services  = Join-Path $Root 'services'
        Secrets   = Join-Path $Root 'secrets'
        Downloads = Join-Path $Root 'downloads'
    }
    return $layout
}

function ConvertTo-ForwardSlash { param([string]$Path) return ($Path -replace '\\', '/') }

# Ścieżka Windows jako literał w stringu Alloy ("C:\\dir\\file")
function ConvertTo-AlloyPath { param([string]$Path) return ($Path -replace '\\', '\\') }

function New-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# ---------------------------------------------------------------------
# Sieć / porty
# ---------------------------------------------------------------------
function Test-TcpPortInUse {
    param([Parameter(Mandatory)][int]$Port)
    $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return [bool]($listeners | Where-Object { $_.Port -eq $Port })
}

function Get-PortOwner {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
        $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($proc) { return "$($proc.ProcessName) (PID $($proc.Id))" }
        return "PID $($conn.OwningProcess)"
    } catch { return 'nieznany proces' }
}

function Test-TcpEndpoint {
    <# Szybki test połączenia TCP (Test-NetConnection w PS 5.1 czeka ~20 s przy blokadzie) #>
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 3000)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

function Wait-HttpReady {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 90
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---------------------------------------------------------------------
# Pobieranie i rozpakowywanie
# ---------------------------------------------------------------------
function Initialize-WebClient {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [int]$Retries = 3
    )
    Initialize-WebClient
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # w PS 5.1 pasek postępu spowalnia IWR wielokrotnie
    try {
        for ($i = 1; $i -le $Retries; $i++) {
            try {
                Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
                return
            } catch {
                if ($i -eq $Retries) { throw "Nie udało się pobrać $Url : $($_.Exception.Message)" }
                Start-Sleep -Seconds (3 * $i)
            }
        }
    } finally { $ProgressPreference = $old }
}

function Get-ExpectedSha256 {
    param(
        [string]$ChecksumUrl,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$TempDir
    )
    if (-not $ChecksumUrl) { return $null }
    $sumFile = Join-Path $TempDir ("checksum-" + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
        Invoke-Download -Url $ChecksumUrl -Destination $sumFile -Retries 2
    } catch {
        Write-Warn "Brak pliku sum kontrolnych ($ChecksumUrl) - pomijam weryfikację."
        return $null
    }
    $lines = Get-Content -LiteralPath $sumFile
    Remove-Item -LiteralPath $sumFile -Force -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        $t = $line.Trim()
        if (-not $t) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -eq 1 -and $parts[0] -match '^[0-9a-fA-F]{64}$') { return $parts[0].ToLowerInvariant() }
        if ($parts.Count -ge 2) {
            $name = $parts[-1].TrimStart('*')
            if ($name -eq $FileName) { return $parts[0].ToLowerInvariant() }
        }
    }
    Write-Warn "Plik sum kontrolnych nie zawiera wpisu dla $FileName - pomijam weryfikację."
    return $null
}

function Install-StackComponent {
    <#
        Pobiera artefakt, weryfikuje SHA256, rozpakowuje i umieszcza w bin\<Name>.
        Zwraca pełną ścieżkę do pliku wykonywalnego.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Definition,
        [Parameter(Mandatory)]$Layout,
        [switch]$Force,
        # Agent: artefakt z paczki (bez pobierania), suma SHA256 policzona przez instalator stosu
        [string]$ArchivePath,
        [string]$Sha256
    )
    $version  = $Definition.Version
    $url      = $Definition.Url -f $version
    $fileName = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
    $target   = Join-Path $Layout.Bin $Name
    $marker   = Join-Path $target '.version'

    if ((Test-Path -LiteralPath $marker) -and -not $Force) {
        $installed = (Get-Content -LiteralPath $marker -Raw).Trim()
        if ($installed -eq $version) {
            $exe = Get-ChildItem -LiteralPath $target -Recurse -Filter $Definition.Exe -File | Select-Object -First 1
            if ($exe) {
                Write-Ok "$Name $version już zainstalowany."
                return $exe.FullName
            }
        }
    }

    New-Directory $Layout.Downloads
    if ($ArchivePath) {
        $archive = $ArchivePath
        $expected = $Sha256
    } else {
        $archive = Join-Path $Layout.Downloads $fileName
        if (-not (Test-Path -LiteralPath $archive) -or $Force) {
            Write-Info "Pobieranie $url"
            Invoke-Download -Url $url -Destination $archive
        }
        $checksumUrl = $null
        if ($Definition.ChecksumUrl) { $checksumUrl = $Definition.ChecksumUrl -f $version }
        $expected = Get-ExpectedSha256 -ChecksumUrl $checksumUrl -FileName $fileName -TempDir $Layout.Downloads
    }
    if ($expected) {
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            if (-not $ArchivePath) { Remove-Item -LiteralPath $archive -Force }
            throw "Niezgodna suma SHA256 dla $fileName (oczekiwana $expected, otrzymana $actual)."
        }
        Write-Ok "SHA256 $fileName zgodna."
    }

    $staging = Join-Path $Layout.Downloads ("extract-$Name-" + [Guid]::NewGuid().ToString('N'))
    New-Directory $staging
    try {
        if ($fileName -like '*.zip') {
            Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
        } elseif ($fileName -like '*.tar.gz' -or $fileName -like '*.tgz') {
            $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
            if (-not (Test-Path -LiteralPath $tar)) { throw 'Brak tar.exe (wymagany Windows Server 2019+ / Windows 10 1803+).' }
            & $tar -xzf $archive -C $staging
            if ($LASTEXITCODE -ne 0) { throw "tar.exe zakończył się kodem $LASTEXITCODE" }
        } else {
            Copy-Item -LiteralPath $archive -Destination (Join-Path $staging $fileName) -Force
        }

        $exe = Get-ChildItem -LiteralPath $staging -Recurse -Filter $Definition.Exe -File | Select-Object -First 1
        if (-not $exe) { throw "Nie znaleziono $($Definition.Exe) w $fileName." }

        # Katalog główny dystrybucji: dla Grafany to katalog nadrzędny "bin", dla pozostałych katalog z exe
        $sourceRoot = $exe.Directory.FullName
        if ($Name -eq 'Grafana' -and $exe.Directory.Name -eq 'bin') { $sourceRoot = $exe.Directory.Parent.FullName }

        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        New-Directory $target
        Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $target -Recurse -Force
        Set-Content -LiteralPath $marker -Value $version -Encoding ASCII
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    $installedExe = Get-ChildItem -LiteralPath $target -Recurse -Filter $Definition.Exe -File | Select-Object -First 1
    Write-Ok "$Name $version zainstalowany w $target"
    return $installedExe.FullName
}

function Invoke-NativeTool {
    <#
        Uruchamia narzędzie natywne i zwraca @{ ExitCode; Output }.
        PS 5.1 przy ErrorActionPreference=Stop zamienia każdą linię stderr (np. logi Loki/Alloy) na wyjątek -
        dlatego lokalnie Continue, a o wyniku decyduje kod wyjścia.
    #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
    return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

# ---------------------------------------------------------------------
# Szablony i pliki
# ---------------------------------------------------------------------
function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    New-Directory (Split-Path -Parent $Path)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Expand-StackTemplate {
    <#
        Podstawia {{KLUCZ}} wartościami z $Variables.
        Bloki "// @@BEGIN NAZWA" ... "// @@END NAZWA" (lub "# @@BEGIN ...") są usuwane, gdy NAZWA jest w $RemoveBlocks.
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][hashtable]$Variables,
        [string[]]$RemoveBlocks = @()
    )
    $text = [IO.File]::ReadAllText($TemplatePath, [Text.Encoding]::UTF8)
    foreach ($block in $RemoveBlocks) {
        $pattern = '(?ms)^[ \t]*(//|#)[ \t]*@@BEGIN ' + [regex]::Escape($block) + '\b.*?^[ \t]*(//|#)[ \t]*@@END ' + [regex]::Escape($block) + '\b[^\r\n]*\r?\n?'
        $text = [regex]::Replace($text, $pattern, '')
    }
    # Usuń pozostałe znaczniki bloków (bloki aktywne)
    $text = [regex]::Replace($text, '(?m)^[ \t]*(//|#)[ \t]*@@(BEGIN|END) [A-Z_]+[^\r\n]*\r?\n', '')
    foreach ($key in $Variables.Keys) {
        $text = $text.Replace('{{' + $key + '}}', [string]$Variables[$key])
    }
    $left = [regex]::Matches($text, '\{\{[A-Z0-9_]+\}\}') | ForEach-Object { $_.Value } | Select-Object -Unique
    if ($left) { throw "Niepodstawione zmienne w ${TemplatePath}: $($left -join ', ')" }
    return $text
}

function Set-SecretFile {
    <# Zapisuje sekret do pliku i zawęża ACL do SYSTEM + Administrators. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    Write-Utf8NoBom -Path $Path -Content $Content
    $null = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F'
    if ($LASTEXITCODE -ne 0) { throw "icacls nie ustawił ACL dla $Path" }
}

function Protect-SecretsDirectory {
    param([Parameter(Mandatory)][string]$Path)
    New-Directory $Path
    $null = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) { throw "icacls nie ustawił ACL dla $Path" }
}

function New-RandomPassword {
    param([int]$Length = 24)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    # Wielkie + małe litery + cyfra: wymóg złożoności SQL Server (CHECK_POLICY = ON)
    do {
        $bytes = New-Object byte[] $Length
        $rng.GetBytes($bytes)
        $sb = New-Object Text.StringBuilder
        foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
        $candidate = $sb.ToString()
    } while (-not ($candidate -cmatch '[A-Z]' -and $candidate -cmatch '[a-z]' -and $candidate -match '[0-9]'))
    return $candidate
}

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ---------------------------------------------------------------------
# Usługi Windows (WinSW 2.x)
# ---------------------------------------------------------------------
function Install-WinSWService {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$WinSWExe,
        [Parameter(Mandatory)][string]$ServicesRoot,
        [string[]]$DependsOn = @(),
        [hashtable]$Environment = @{}
    )
    $svcDir = Join-Path $ServicesRoot $Id
    New-Directory $svcDir
    New-Directory $LogDirectory
    New-Directory $WorkingDirectory

    $existing = Get-Service -Name $Id -ErrorAction SilentlyContinue
    $wrapper = Join-Path $svcDir "$Id.exe"
    if ($existing) {
        if ($existing.Status -ne 'Stopped') { Stop-Service -Name $Id -Force -ErrorAction SilentlyContinue }
        $null = $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    }

    Copy-Item -LiteralPath $WinSWExe -Destination $wrapper -Force

    # XML budowany przez XmlDocument - poprawne escapowanie argumentów
    $xml = New-Object System.Xml.XmlDocument
    $root = $xml.CreateElement('service'); [void]$xml.AppendChild($root)
    function Add-Node([System.Xml.XmlElement]$Parent, [string]$Name, [string]$Text) {
        $n = $Parent.OwnerDocument.CreateElement($Name)
        if ($null -ne $Text) { $n.InnerText = $Text }
        [void]$Parent.AppendChild($n)
        return $n
    }
    [void](Add-Node $root 'id' $Id)
    [void](Add-Node $root 'name' $DisplayName)
    [void](Add-Node $root 'description' $Description)
    [void](Add-Node $root 'executable' $Executable)
    [void](Add-Node $root 'arguments' $Arguments)
    [void](Add-Node $root 'workingdirectory' $WorkingDirectory)
    [void](Add-Node $root 'startmode' 'Automatic')
    [void](Add-Node $root 'stoptimeout' '30 sec')
    [void](Add-Node $root 'logpath' $LogDirectory)
    $log = Add-Node $root 'log' $null
    $log.SetAttribute('mode', 'roll-by-size')
    [void](Add-Node $log 'sizeThreshold' '10240')
    [void](Add-Node $log 'keepFiles' '8')
    foreach ($delay in @('10 sec', '30 sec', '60 sec')) {
        $f = Add-Node $root 'onfailure' $null
        $f.SetAttribute('action', 'restart'); $f.SetAttribute('delay', $delay)
    }
    [void](Add-Node $root 'resetfailure' '1 hour')
    foreach ($d in $DependsOn) { [void](Add-Node $root 'depend' $d) }
    foreach ($k in $Environment.Keys) {
        $e = Add-Node $root 'env' $null
        $e.SetAttribute('name', $k); $e.SetAttribute('value', [string]$Environment[$k])
    }
    $xmlPath = Join-Path $svcDir "$Id.xml"
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($xmlPath, $settings)
    try { $xml.Save($writer) } finally { $writer.Close() }

    if (-not $existing) {
        & $wrapper install | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "WinSW install dla $Id zakończył się kodem $LASTEXITCODE" }
        Write-Ok "Usługa $Id zarejestrowana."
    } else {
        Write-Ok "Usługa $Id zaktualizowana (konfiguracja WinSW)."
    }
}

function Uninstall-WinSWService {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$ServicesRoot)
    $svc = Get-Service -Name $Id -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Info "Usługa $Id nie istnieje."; return }
    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name $Id -Force -ErrorAction SilentlyContinue
        $null = $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    }
    $wrapper = Join-Path (Join-Path $ServicesRoot $Id) "$Id.exe"
    if (Test-Path -LiteralPath $wrapper) {
        & $wrapper uninstall | Out-Null
    } else {
        & sc.exe delete $Id | Out-Null
    }
    Write-Ok "Usługa $Id usunięta."
}

# ---------------------------------------------------------------------
# SQL Server
# ---------------------------------------------------------------------
function ConvertFrom-SqlServerName {
    <# "host", "host\INST", "host,1433", "host\INST,1433" -> obiekt #>
    param([Parameter(Mandatory)][string]$Server)
    $hostPart = $Server; $port = $null; $instance = $null
    if ($hostPart -match '^(.*),(\d+)$') { $hostPart = $Matches[1]; $port = [int]$Matches[2] }
    if ($hostPart -match '^(.*)\\(.+)$') { $hostPart = $Matches[1]; $instance = $Matches[2] }
    if ($hostPart -eq '.' -or $hostPart -eq '(local)') { $hostPart = 'localhost' }
    return [pscustomobject]@{ Host = $hostPart; Instance = $instance; Port = $port }
}

function New-MssqlExporterConnectionString {
    <# Connection string w formacie go-mssqldb (URL) dla prometheus.exporter.mssql #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Login,
        [Parameter(Mandatory)][string]$Password,
        [bool]$Encrypt = $true,
        [bool]$TrustServerCertificate = $true
    )
    $s = ConvertFrom-SqlServerName -Server $Server
    $user = [Uri]::EscapeDataString($Login)
    $pass = [Uri]::EscapeDataString($Password)
    $hostPort = $s.Host
    if ($s.Port) { $hostPort = "$($s.Host):$($s.Port)" }
    $path = ''
    if ($s.Instance -and -not $s.Port) { $path = '/' + [Uri]::EscapeDataString($s.Instance) }
    $enc = 'disable'
    if ($Encrypt) { $enc = 'true' }
    $trust = 'false'
    if ($TrustServerCertificate) { $trust = 'true' }
    return "sqlserver://${user}:${pass}@${hostPort}${path}?database=master&encrypt=$enc&TrustServerCertificate=$trust&app+name=alloy-mssql-exporter"
}

function Invoke-SqlScalarQuery {
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection, [Parameter(Mandatory)][string]$Query)
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 30
    return $cmd.ExecuteScalar()
}

function Test-SqlExporterPermissions {
    <#
        Łączy się loginem SQL i sprawdza uprawnienia wymagane przez prometheus.exporter.mssql.
        Zwraca obiekt z polami: Success, Checks (lista), Remediation (T-SQL).
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Login,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [bool]$Encrypt = $true,
        [bool]$TrustServerCertificate = $true
    )
    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
        $checks.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
    }

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Server
    $builder['Initial Catalog'] = 'master'
    $builder['User ID'] = $Login
    $builder['Password'] = (ConvertFrom-SecureStringPlain $Password)
    $builder['Encrypt'] = $Encrypt
    $builder['TrustServerCertificate'] = $TrustServerCertificate
    $builder['Application Name'] = 'webcon-observability-check'
    $builder['Connect Timeout'] = 15

    $conn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    $missing = New-Object System.Collections.Generic.List[string]
    try {
        try {
            $conn.Open()
            Add-Check 'Połączenie (SQL login, baza master)' $true "Wersja: $($conn.ServerVersion)"
        } catch {
            Add-Check 'Połączenie (SQL login, baza master)' $false $_.Exception.Message
            return [pscustomobject]@{ Success = $false; Checks = $checks; Remediation = $null }
        }

        $edition = [string](Invoke-SqlScalarQuery $conn "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128))")
        if ($edition -like '*Azure*' -or $edition -eq 'SQL Azure') {
            Add-Check 'Typ serwera' $false "Edycja '$edition' - exporter jest przewidziany dla SQL Server (on-prem / VM)."
        }

        $isSysadmin = [int](Invoke-SqlScalarQuery $conn "SELECT IS_SRVROLEMEMBER('sysadmin')")
        if ($isSysadmin -eq 1) {
            Add-Check 'Brak roli sysadmin (least privilege)' $false 'Login jest sysadmin - działa, ale ma nadmiarowe uprawnienia. Zalecany dedykowany login z GRANT jak w sql/grant-sql-exporter-permissions.sql.'
        } else {
            Add-Check 'Brak roli sysadmin (least privilege)' $true ''
        }

        foreach ($perm in @('VIEW SERVER STATE', 'VIEW ANY DEFINITION')) {
            $has = [int](Invoke-SqlScalarQuery $conn "SELECT HAS_PERMS_BY_NAME(NULL, NULL, '$perm')")
            Add-Check "Uprawnienie $perm" ($has -eq 1) ''
            if ($has -ne 1) { $missing.Add($perm) }
        }

        $probes = [ordered]@{
            'sys.dm_os_performance_counters' = 'SELECT TOP (1) 1 FROM sys.dm_os_performance_counters'
            'sys.dm_os_wait_stats'           = 'SELECT TOP (1) 1 FROM sys.dm_os_wait_stats'
            'sys.dm_io_virtual_file_stats'   = 'SELECT TOP (1) 1 FROM sys.dm_io_virtual_file_stats(NULL, NULL)'
            'sys.dm_os_sys_memory'           = 'SELECT TOP (1) 1 FROM sys.dm_os_sys_memory'
            'sys.master_files'               = 'SELECT COUNT(*) FROM sys.master_files'
        }
        foreach ($k in $probes.Keys) {
            try {
                $v = Invoke-SqlScalarQuery $conn $probes[$k]
                $ok = $true
                $detail = ''
                if ($k -eq 'sys.master_files' -and [int]$v -eq 0) { $ok = $false; $detail = 'Brak widocznych plików baz (wymaga VIEW ANY DEFINITION).' }
                Add-Check "Odczyt $k" $ok $detail
            } catch {
                Add-Check "Odczyt $k" $false $_.Exception.Message
            }
        }
    } finally {
        $conn.Dispose()
    }

    $remediation = $null
    if ($missing.Count -gt 0) {
        $q = '[' + $Login.Replace(']', ']]') + ']'
        $lines = @('USE [master];')
        foreach ($p in $missing) { $lines += "GRANT $p TO $q;" }
        $remediation = $lines -join [Environment]::NewLine
    }
    $success = -not ($checks | Where-Object { -not $_.Ok -and $_.Check -ne 'Brak roli sysadmin (least privilege)' })
    return [pscustomobject]@{ Success = [bool]$success; Checks = $checks; Remediation = $remediation }
}

function Test-WebconSqlReaderPermissions {
    <#
        Łączy się loginem źródła danych Grafany "WEBCON SQL" z bazą treści i sprawdza SELECT na tabelach
        z sql\grant-webcon-reader-permissions.sql. Zwraca obiekt z polami: Success, Checks (lista).
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Login,
        [Parameter(Mandatory)][string]$Password,
        [bool]$Encrypt = $true,
        [bool]$TrustServerCertificate = $true
    )
    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
        $checks.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
    }

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Server
    $builder['Initial Catalog'] = $Database
    $builder['User ID'] = $Login
    $builder['Password'] = $Password
    $builder['Encrypt'] = $Encrypt
    $builder['TrustServerCertificate'] = $TrustServerCertificate
    $builder['Application Name'] = 'webcon-observability-check'
    $builder['Connect Timeout'] = 15

    $conn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    try {
        try {
            $conn.Open()
            Add-Check "Połączenie (SQL login, baza $Database)" $true ''
        } catch {
            Add-Check "Połączenie (SQL login, baza $Database)" $false $_.Exception.Message
            return [pscustomobject]@{ Success = $false; Checks = $checks }
        }
        foreach ($t in 'ActiveTasks', 'WFAvaiblePaths', 'WFSteps', 'WorkFlows', 'WFDefinitions') {
            try {
                $null = Invoke-SqlScalarQuery $conn "SELECT TOP (1) 1 FROM dbo.$t"
                Add-Check "SELECT dbo.$t" $true ''
            } catch {
                Add-Check "SELECT dbo.$t" $false $_.Exception.Message
            }
        }
        # Nadmiarowe uprawnienia - zapytania w Grafanie może pisać każdy edytor dashboardów
        $wide = [int](Invoke-SqlScalarQuery $conn "SELECT IS_SRVROLEMEMBER('sysadmin') + ISNULL(IS_ROLEMEMBER('db_owner'), 0) + ISNULL(IS_ROLEMEMBER('db_datareader'), 0)")
        if ($wide -gt 0) {
            Add-Check 'Tylko odczyt wybranych tabel (least privilege)' $false 'Login ma sysadmin / db_owner / db_datareader - edytorzy Grafany zobaczą dane formularzy. Zalecany login z sql\grant-webcon-reader-permissions.sql.'
        } else {
            Add-Check 'Tylko odczyt wybranych tabel (least privilege)' $true ''
        }
    } finally {
        $conn.Dispose()
    }
    $success = -not ($checks | Where-Object { -not $_.Ok -and $_.Check -ne 'Tylko odczyt wybranych tabel (least privilege)' })
    return [pscustomobject]@{ Success = [bool]$success; Checks = $checks }
}

function ConvertFrom-MssqlConnectionUrl {
    <# Odwrotność New-MssqlExporterConnectionString: sqlserver://login:hasło@host[:port][/instancja]?... -> Server, Login, Password #>
    param([Parameter(Mandatory)][string]$ConnectionString)
    $u = [Uri]$ConnectionString.Trim()
    $parts = $u.UserInfo.Split(':', 2)
    $server = $u.Host
    $instance = [Uri]::UnescapeDataString($u.AbsolutePath.Trim('/'))
    if ($u.Port -gt 0) { $server = "$($u.Host),$($u.Port)" } elseif ($instance) { $server = "$($u.Host)\$instance" }
    return [pscustomobject]@{
        Server   = $server
        Login    = [Uri]::UnescapeDataString($parts[0])
        Password = [Uri]::UnescapeDataString($parts[1])
    }
}

# Kolumny używane w config-templates/alloy/webcon-db-queries.yaml (= GRANT w sql/grant-webcon-db-metrics.sql)
$script:WebconDbMetricsColumns = [ordered]@{
    'WFMails'                 = @('MAIL_AttemptsNumber')
    'WFRecurrentActionsStats' = @('RAS_TimeLastFailure', 'RAS_TimeLastSuccess', 'RAS_ServiceName', 'RAS_Status', 'RAS_NextLaunch')
    'WFElementTimeouts'       = @('ETM_TIMID', 'ETM_ServiceName', 'ETM_Status', 'ETM_ExpireTime', 'ETM_OccurrenceErrorsCount', 'ETM_OccurrenceCount', 'ETM_LastAttemptTime', 'ETM_AttemptsNumber')
    'WFTimeouts'              = @('TIM_ID', 'TIM_STPID', 'TIM_IsNightOnly', 'TIM_RepeatCount')
    'WFSteps'                 = @('STP_ID', 'STP_WFID')
    'WorkFlows'               = @('WF_ID', 'WF_WFDEFID')
    'WFDefinitions'           = @('DEF_ID', 'DEF_EnableTimeouts')
}

function Test-WebconDbMetricsPermissions {
    <#
        Sprawdza (jako login exportera) dostęp do bazy treści i SELECT na kolumnach z webcon-db-queries.yaml.
        Zwraca obiekt z polami: Success, Checks (lista).
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Login,
        [Parameter(Mandatory)][string]$Password,
        [bool]$Encrypt = $true,
        [bool]$TrustServerCertificate = $true
    )
    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
        $checks.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
    }
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Server
    $builder['Initial Catalog'] = $Database
    $builder['User ID'] = $Login
    $builder['Password'] = $Password
    $builder['Encrypt'] = $Encrypt
    $builder['TrustServerCertificate'] = $TrustServerCertificate
    $builder['Application Name'] = 'webcon-observability-check'
    $builder['Connect Timeout'] = 15
    $conn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    try {
        try {
            $conn.Open()
            Add-Check "Dostęp do bazy $Database" $true ''
        } catch {
            Add-Check "Dostęp do bazy $Database" $false $_.Exception.Message
            return [pscustomobject]@{ Success = $false; Checks = $checks }
        }
        foreach ($t in $script:WebconDbMetricsColumns.Keys) {
            $missing = @()
            foreach ($c in $script:WebconDbMetricsColumns[$t]) {
                $has = Invoke-SqlScalarQuery $conn "SELECT HAS_PERMS_BY_NAME(N'dbo.$t', N'OBJECT', N'SELECT', N'$c', N'COLUMN')"
                if ([string]$has -ne '1') { $missing += $c }
            }
            if ($missing) { Add-Check "SELECT dbo.$t" $false "brak: $($missing -join ', ')" } else { Add-Check "SELECT dbo.$t (kolumny)" $true '' }
        }
    } finally {
        $conn.Dispose()
    }
    $success = -not ($checks | Where-Object { -not $_.Ok })
    return [pscustomobject]@{ Success = [bool]$success; Checks = $checks }
}

function Get-WebconPortalProbeTarget {
    <#
        Adresy /health Portalu WEBCON z powiązań IIS: witryna, której aplikacja "/" wskazuje katalog z web.config
        uruchamiającym WebCon.WorkFlow.Bootstrapper (ASP.NET Core Module). Powiązania http/https z nazwą hosta
        -> <schemat>://<host>[:port]/health; powiązanie bez nazwy -> FQDN serwera, tylko gdy witryna nie ma powiązań
        z nazwą. Pomija zatrzymane witryny. Zwraca listę obiektów: Url, Host, Site.
    #>
    $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
    if (-not (Test-Path -LiteralPath $appcmd)) { return ,@() }
    $xml = [xml](& $appcmd list site /config /xml)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($site in @($xml.appcmd.SITE)) {
        if ($site.state -ne 'Started') { continue }
        $root = @($site.site.application) | Where-Object { $_.path -eq '/' } | Select-Object -First 1
        if (-not $root) { continue }
        $vdir = @($root.virtualDirectory) | Where-Object { $_.path -eq '/' } | Select-Object -First 1
        if (-not $vdir) { continue }
        $webConfig = Join-Path ([Environment]::ExpandEnvironmentVariables($vdir.physicalPath)) 'web.config'
        if (-not (Test-Path -LiteralPath $webConfig)) { continue }
        if (-not (Select-String -LiteralPath $webConfig -Pattern 'WebCon.WorkFlow.Bootstrapper' -SimpleMatch -Quiet)) { continue }
        $named = @(); $unnamed = @()
        foreach ($b in @($site.site.bindings.binding)) {
            if ($b.protocol -ne 'http' -and $b.protocol -ne 'https') { continue }
            $p = $b.bindingInformation.Split(':')   # adres:port:host
            $port = [int]$p[1]
            $h = ''
            if ($p.Count -ge 3) { $h = $p[2] }
            $item = [pscustomobject]@{ Protocol = $b.protocol; Port = $port; Host = $h }
            if ($h -and $h -ne '*') { $named += $item } else { $unnamed += $item }
        }
        $use = $named
        if (-not $use) {
            $fqdn = [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
            $use = @($unnamed | ForEach-Object { [pscustomobject]@{ Protocol = $_.Protocol; Port = $_.Port; Host = $fqdn } })
        }
        foreach ($u in $use) {
            $portPart = ''
            if (-not (($u.Protocol -eq 'https' -and $u.Port -eq 443) -or ($u.Protocol -eq 'http' -and $u.Port -eq 80))) { $portPart = ":$($u.Port)" }
            $url = "$($u.Protocol)://$($u.Host)$portPart/health"
            if (-not ($result | Where-Object { $_.Url -eq $url })) {
                $result.Add([pscustomobject]@{ Url = $url; Host = $u.Host; Site = $site.'SITE.NAME' })
            }
        }
    }
    # ToArray(): ",@(List)" rzuca w pwsh 7 "Argument types do not match"
    return ,($result.ToArray())
}

function New-BlackboxConfig {
    <#
        Fragmenty bloku BLACKBOX config.alloy: moduły (YAML, wcięcie pod "modules:") i bloki target.
        Portal: moduł na nazwę hosta (nagłówek Host: localhost + tls_config.server_name = host); -ProbeUrl: moduł http_2xx.
    #>
    param([object[]]$PortalTarget = @(), [string[]]$ProbeUrl = @())
    $modules = New-Object System.Collections.Generic.List[string]
    $targets = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($t in @($PortalTarget)) {
        if (-not $t) { continue }
        $i++
        $m = "webcon_health_$i"
        $modules.Add(@"
  ${m}:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      valid_status_codes: [200]
      no_follow_redirects: true
      headers:
        Host: localhost
      tls_config:
        server_name: '$($t.Host)'
      fail_if_body_not_matches_regexp:
        - '"status":"Healthy"'
"@)
        $targets.Add(@"
  target {
    name    = "portal_$i"
    address = "$($t.Url)"
    module  = "$m"
    labels  = { "probe" = "portal" }
  }
"@)
    }
    $j = 0
    foreach ($u in @($ProbeUrl)) {
        if (-not $u) { continue }
        $j++
        $targets.Add(@"
  target {
    name    = "custom_$j"
    address = "$u"
    module  = "http_2xx"
    labels  = { "probe" = "custom" }
  }
"@)
    }
    return [pscustomobject]@{
        Modules = (($modules | ForEach-Object { $_ -replace "`r", '' }) -join "`n")
        Targets = (($targets | ForEach-Object { $_ -replace "`r", '' }) -join "`n")
        Count   = $targets.Count
    }
}

# Kolektory windows_exporter w formacie listy Alloy; "iis" tylko przy zainstalowanym IIS (inaczej success=0 przy każdym scrape)
function Get-WindowsCollectorList {
    $c = @('cpu', 'logical_disk', 'memory', 'net', 'os', 'system', 'process', 'tcp')
    if (Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue) { $c += 'iis' }
    return (($c | ForEach-Object { '"' + $_ + '"' }) -join ', ')
}

# ---------------------------------------------------------------------
# SQL Server - lokalna instancja (agent na hoście SQL)
# ---------------------------------------------------------------------
function Get-SqlInstanceInfo {
    <#
        Instancja SQL Server na tym hoście: usługa, ustawienia TCP z rejestru, porty, na których faktycznie nasłuchuje,
        i Data Source do połączenia lokalnego (shared memory - działa także przy wyłączonym TCP).
    #>
    param([Parameter(Mandatory)][string]$InstanceName)
    $svcName = 'MSSQLSERVER'
    $dataSource = '.'
    if ($InstanceName -ne 'MSSQLSERVER') { $svcName = 'MSSQL$' + $InstanceName; $dataSource = ".\$InstanceName" }
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($svcName.Replace("'", "''"))'"
    if (-not $svc) { throw "Brak usługi SQL Server $svcName (instancja $InstanceName) na tym hoście." }

    $names = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
    $id = $names.$InstanceName
    if (-not $id) { throw "Brak instancji $InstanceName w rejestrze SQL Server." }
    $tcpKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\MSSQLServer\SuperSocketNetLib\Tcp"
    $tcp = Get-ItemProperty -Path $tcpKey
    $ipAll = Get-ItemProperty -Path "$tcpKey\IPAll"

    $ports = @()
    if ($svc.ProcessId) {
        # bez adresów pętli zwrotnej: tam nasłuchuje DAC
        $ports = @(Get-NetTCPConnection -State Listen -OwningProcess $svc.ProcessId -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1' } |
            Select-Object -ExpandProperty LocalPort -Unique)
    }
    return [pscustomobject]@{
        InstanceName    = $InstanceName
        ServiceName     = $svcName
        State           = $svc.State
        DataSource      = $dataSource
        TcpKey          = $tcpKey
        TcpEnabled      = ([int]$tcp.Enabled -eq 1)
        StaticPort      = [string]$ipAll.TcpPort
        DynamicPort     = [string]$ipAll.TcpDynamicPorts
        ListeningPorts  = $ports
    }
}

function Set-SqlTcpStaticPort {
    <# Włącza TCP i ustawia statyczny port (IPAll) instancji, restartuje instancję i uruchamia ponownie zależne usługi (np. Agent). #>
    param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)][int]$Port)
    Set-ItemProperty -Path $Info.TcpKey -Name Enabled -Value 1
    Set-ItemProperty -Path "$($Info.TcpKey)\IPAll" -Name TcpPort -Value ([string]$Port)
    Set-ItemProperty -Path "$($Info.TcpKey)\IPAll" -Name TcpDynamicPorts -Value ''
    $dependents = @(Get-Service -Name $Info.ServiceName -DependentServices | Where-Object Status -eq 'Running' | Select-Object -ExpandProperty Name)
    Restart-Service -Name $Info.ServiceName -Force
    foreach ($d in $dependents) { Start-Service -Name $d -ErrorAction SilentlyContinue }
}

function Invoke-SqlBatches {
    <# Wykonuje skrypt T-SQL z separatorami GO; komunikaty (PRINT / RAISERROR < 11) wypisuje jako informacje. #>
    param([Parameter(Mandatory)][string]$ConnectionString, [Parameter(Mandatory)][string]$Sql)
    $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $conn.add_InfoMessage({ param($s, $e) Write-Info "  SQL: $($e.Message)" })
    try {
        $conn.Open()
        foreach ($batch in [regex]::Split($Sql, '(?mi)^[ \t]*GO[ \t]*\r?$')) {
            if (-not $batch.Trim()) { continue }
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $batch
            $cmd.CommandTimeout = 120
            [void]$cmd.ExecuteNonQuery()
        }
    } finally { $conn.Dispose() }
}

function Set-SqlLogin {
    <# Tworzy login SQL albo ustawia mu hasło (hasło z paczki agenta = jedno źródło prawdy dla stosu i hosta SQL). #>
    param([Parameter(Mandatory)][string]$ConnectionString, [Parameter(Mandatory)][string]$Login, [Parameter(Mandatory)][string]$Password)
    $l = $Login.Replace("'", "''")
    $q = '[' + $Login.Replace(']', ']]') + ']'
    $p = $Password.Replace("'", "''")
    $sql = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$l') " +
           "CREATE LOGIN $q WITH PASSWORD = N'$p', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = [master]; " +
           "ELSE IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$l' AND PWDCOMPARE(N'$p', password_hash) = 1) " +
           "ALTER LOGIN $q WITH PASSWORD = N'$p';"   # ponowne uruchomienie: bez zmiany hasła (historia haseł przy CHECK_POLICY)
    Invoke-SqlBatches -ConnectionString $ConnectionString -Sql $sql
}

# ---------------------------------------------------------------------
# Paczka agenta (tryb zdalny)
# ---------------------------------------------------------------------
function Write-Utf8Bom {
    <# Skrypty .ps1 z polskimi znakami: UTF-8 z BOM (PS 5.1) #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    New-Directory (Split-Path -Parent $Path)
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function New-AgentBundle {
    <#
        Tworzy <Root>\agent-bundle (+ .zip): instalator agenta, moduł, szablony Alloy, skrypty SQL, binarki Alloy/WinSW
        z katalogu downloads, ustawienia (agent-settings.json), hasła loginów SQL i skrypty 01-/02- dla hostów.
        Zwraca ścieżkę katalogu paczki.
    #>
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Versions,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][hashtable]$Secrets,
        [Parameter(Mandatory)]$Release,
        [string]$WebconHost,
        [string]$SqlHost
    )
    $bundle = Join-Path $Layout.Root 'agent-bundle'
    if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
    # Paczka zawiera hasła SQL - ACL jak katalog secrets
    Protect-SecretsDirectory -Path $bundle

    $files = @(
        'Install-ObservabilityAgent.ps1', 'Uninstall-ObservabilityAgent.ps1', 'versions.psd1', 'LICENSE', 'VERSION',
        'scripts\modules\ObservabilityStack.psm1', 'scripts\Set-WebconTelemetry.ps1',
        'config-templates\alloy\config.alloy', 'config-templates\alloy\mssql-queries.yaml',
        'config-templates\alloy\webcon-db-queries.yaml',
        'sql\grant-sql-exporter-permissions.sql', 'sql\grant-webcon-reader-permissions.sql', 'sql\grant-webcon-db-metrics.sql'
    )
    foreach ($f in $files) {
        $dst = Join-Path $bundle $f
        New-Directory (Split-Path -Parent $dst)
        Copy-Item -LiteralPath (Join-Path $RepoRoot $f) -Destination $dst -Force
    }

    # Binarki z downloads stosu (pobrane i zweryfikowane przez Install-StackComponent)
    $packages = [ordered]@{}
    $pkgDir = Join-Path $bundle 'packages'
    New-Directory $pkgDir
    foreach ($name in 'Alloy', 'WinSW') {
        $def = $Versions[$name]
        $url = $def.Url -f $def.Version
        $fileName = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
        $src = Join-Path $Layout.Downloads $fileName
        if (-not (Test-Path -LiteralPath $src)) { Invoke-Download -Url $url -Destination $src }
        Copy-Item -LiteralPath $src -Destination (Join-Path $pkgDir $fileName) -Force
        $packages[$name] = [ordered]@{
            Version = $def.Version
            File    = $fileName
            Sha256  = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $Settings['Packages'] = $packages
    Write-Utf8NoBom -Path (Join-Path $bundle 'agent-settings.json') -Content ($Settings | ConvertTo-Json -Depth 5)
    Write-Utf8NoBom -Path (Join-Path $bundle 'RELEASE.json') -Content ([ordered]@{
        Version = $Release.Version; Commit = $Release.Commit; BuiltAt = $Release.BuiltAt } | ConvertTo-Json)
    Set-SecretFile -Path (Join-Path $bundle 'secrets\sql-logins.json') -Content ($Secrets | ConvertTo-Json)

    # Skrypty dla hostów: SQL przed WEBCON (ewentualny restart SQL i restart WEBCON w jednym oknie)
    $hosts = @()
    $sameHost = ($WebconHost -and $SqlHost -and $WebconHost -eq $SqlHost)
    if ($sameHost) {
        $hosts += @{ Name = "WebconSql-$WebconHost"; Role = 'Sql, Webcon'; Host = $WebconHost }
    } else {
        if ($SqlHost)    { $hosts += @{ Name = "Sql-$SqlHost"; Role = 'Sql'; Host = $SqlHost } }
        if ($WebconHost) { $hosts += @{ Name = "Webcon-$WebconHost"; Role = 'Webcon'; Host = $WebconHost } }
    }
    $i = 1
    $readme = New-Object System.Collections.Generic.List[string]
    $readme.Add('Paczka agenta - stos obserwowalności WEBCON')
    $readme.Add("Wygenerowana: $($Settings.GeneratedAt) na $env:COMPUTERNAME; stos: $($Settings.CentralAddress); wersja $($Release.Version)")
    $readme.Add($script:Disclaimer)
    $readme.Add('')
    $readme.Add('ZAWIERA HASŁA LOGINÓW SQL (secrets\sql-logins.json) - usuń paczkę z hostów po instalacji.')
    $readme.Add('')
    $readme.Add('Kolejność (PowerShell jako administrator, katalog rozpakowanej paczki):')
    foreach ($h in $hosts) {
        $script = ('{0:00}-{1}.ps1' -f $i, $h.Name)
        $roleText = $h.Role
        $content = @(
            '#Requires -Version 5.1'
            "# Wygenerowane przez Install-ObservabilityStack.ps1 ($($Settings.GeneratedAt)) - host: $($h.Host), role: $roleText"
            '# Dodatkowe parametry są przekazywane do Install-ObservabilityAgent.ps1, np. -EnableSqlTcp, -Force, -SkipWebconConfig'
            "& (Join-Path `$PSScriptRoot 'Install-ObservabilityAgent.ps1') -Role $roleText @args"
        ) -join "`r`n"
        Write-Utf8Bom -Path (Join-Path $bundle $script) -Content ($content + "`r`n")
        $line = "  $i. host $($h.Host): .\$script"
        if ($h.Role -like '*Sql*') { $line += '   (TCP instancji wyłączone: dodaj -EnableSqlTcp = restart instancji SQL)' }
        $readme.Add($line)
        $i++
    }
    $readme.Add("  $i. VM stosu ($env:COMPUTERNAME): .\Test-ObservabilityStack.ps1")
    $readme.Add('')
    $readme.Add("Wymagana łączność: host -> $($Settings.CentralAddress) TCP $($Settings.OtlpPort), $($Settings.ReceivePort)")
    $readme.Add("  (firewall stosu dopuszcza: $($Settings.AgentAddress -join ', '))")
    if ($SqlHost -and $Settings.ReaderLogin) {
        $readme.Add("Grafana -> $SqlHost TCP $($Settings.SqlPort) (źródło 'WEBCON SQL'; skrypt hosta SQL dodaje regułę firewall dla $($Settings.CentralIPv4 -join ', '))")
    }
    $readme.Add('')
    $readme.Add('Po instalacji paczkę można usunąć - odinstalowanie agenta: C:\Observability\app\Uninstall-ObservabilityAgent.ps1 [-RemoveFiles]')
    Write-Utf8NoBom -Path (Join-Path $bundle 'README.txt') -Content (($readme -join "`r`n") + "`r`n")

    $zip = "$bundle.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip -CompressionLevel Fastest }
    finally { $ProgressPreference = $old }
    $null = & icacls.exe $zip /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F'
    Write-Ok "Paczka: $bundle ($zip, $([math]::Round((Get-Item -LiteralPath $zip).Length / 1MB)) MB)"
    foreach ($h in $hosts) { Write-Ok "Host $($h.Host): role $($h.Role)" }
    return $bundle
}

# ---------------------------------------------------------------------
# Wydania, wersja, kopia app\ (docs/projekt/projekt-dystrybucja-i-wersje.md)
# ---------------------------------------------------------------------
$script:PublicRepoUrl = 'https://github.com/mmbednarz/observability-stack'
$script:Disclaimer = 'Projekt nieoficjalny, bez wsparcia i gwarancji (licencja MIT) - nie jest produktem WEBCON. Szczegóły: README.md.'

# Zawartość paczki wydania i kopii C:\Observability\app. Katalog = wpis zakończony "\" (rekurencyjnie).
# Nowy plik w repozytorium poza tymi wpisami nie trafi do paczki - build\New-ReleasePackage.ps1 to sprawdza.
$script:PackageEntries = @(
    'Install-ObservabilityStack.ps1', 'Install-ObservabilityAgent.ps1',
    'Uninstall-ObservabilityStack.ps1', 'Uninstall-ObservabilityAgent.ps1', 'Test-ObservabilityStack.ps1',
    'versions.psd1', 'VERSION', 'CHANGELOG.md', 'README.md', 'LICENSE', '.gitattributes',
    'config-templates\', 'dashboards\', 'scripts\', 'sql\', 'webcon\',
    'docs\README.md', 'docs\instalacja\', 'docs\uzytkownik\', 'docs\img\'
)
# Pliki lokalne, które nie trafiają do paczki ani do app\ (kopie, logi)
$script:PackageExcludeRegex = '(\.bak-[^\\]*|\.log|\.tmp)$'

function Write-StackDisclaimer { Write-Host $script:Disclaimer -ForegroundColor DarkGray }

function Get-StackPackageFiles {
    <# Ścieżki względne (z "\") plików paczki w katalogu źródłowym (repozytorium, paczka albo app\). #>
    param([Parameter(Mandatory)][string]$SourceRoot)
    $SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($e in $script:PackageEntries) {
        $p = Join-Path $SourceRoot $e.TrimEnd('\')
        if ($e.EndsWith('\')) {
            if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw "Brak katalogu paczki: $e (w $SourceRoot)" }
            foreach ($f in Get-ChildItem -LiteralPath $p -Recurse -File -Force) {
                $rel = $f.FullName.Substring($SourceRoot.Length + 1)
                if ($rel -notmatch $script:PackageExcludeRegex) { $files.Add($rel) }
            }
        } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            $files.Add($e)
        } else {
            throw "Brak pliku paczki: $e (w $SourceRoot)"
        }
    }
    return ,([string[]]($files.ToArray() | Sort-Object))
}

function Get-StackRelease {
    <#
        Wersja plików instalacyjnych: RELEASE.json (paczka wydania, app\) albo VERSION + commit z gita (klon).
        Klon: Version = "X.Y.Z+dev.<commit>" (metadane builda - ta sama pozycja co X.Y.Z przy porównaniu wersji).
    #>
    param([Parameter(Mandatory)][string]$SourceRoot)
    $releaseFile = Join-Path $SourceRoot 'RELEASE.json'
    if (Test-Path -LiteralPath $releaseFile) {
        $r = Get-Content -LiteralPath $releaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ Version = [string]$r.Version; Commit = [string]$r.Commit; BuiltAt = [string]$r.BuiltAt; Dev = ([string]$r.Version -like '*+dev*') }
    }
    $versionFile = Join-Path $SourceRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile)) { throw "Brak pliku VERSION ani RELEASE.json w $SourceRoot." }
    $base = ([IO.File]::ReadAllText($versionFile)).Trim()
    $commit = ''
    if ((Test-Path -LiteralPath (Join-Path $SourceRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        try { $commit = [string](& git -C $SourceRoot rev-parse --short HEAD 2>$null) } catch { $commit = '' }
        if ($LASTEXITCODE -ne 0) { $commit = '' }
    }
    $v = "$base+dev"
    if ($commit) { $v = "$base+dev.$commit" }
    return [pscustomobject]@{ Version = $v; Commit = $commit; BuiltAt = ''; Dev = $true }
}

function ConvertTo-StackVersion {
    <# Część X.Y.Z wersji (bez metadanych "+...") jako [version]; brak = 0.0.0. #>
    param([string]$Version)
    if (-not $Version) { return [version]'0.0.0' }
    $core = ($Version -split '[+-]')[0]
    try { return [version]$core } catch { throw "Niepoprawny numer wersji: '$Version'." }
}

function Test-PathInside {
    <# Czy $Path jest katalogiem $Parent lub leży w nim (bez rozróżniania wielkości liter). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    $q = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    return $p.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-InstallLocation {
    <# Pliki instalacyjne nie mogą leżeć w katalogu instalacji (poza app\) ani zawierać go. #>
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)]$Layout)
    $app = Join-Path $Layout.Root 'app'
    if ((Test-PathInside -Path $SourceRoot -Parent $Layout.Root) -and -not (Test-PathInside -Path $SourceRoot -Parent $app)) {
        throw ("Pliki instalacyjne ($SourceRoot) leżą w katalogu instalacji $($Layout.Root) - usunięcie stosu z -RemoveFiles " +
               "usunęłoby je razem z danymi. Przenieś je (np. do C:\Install) i uruchom ponownie.")
    }
    if (Test-PathInside -Path $Layout.Root -Parent $SourceRoot) {
        throw "Katalog instalacji $($Layout.Root) leży w katalogu plików instalacyjnych ($SourceRoot) - wybierz inny -Root."
    }
}

function Copy-StackApp {
    <#
        Tworzy od nowa <Root>\app z plików instalacyjnych (smoke test, odinstalowanie, zmiana parametrów bez paczki).
        $Files = ścieżki względne; brak = pełna lista paczki. Uruchomienie z app\ = pominięcie (ta sama wersja).
    #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)]$Release,
        [string[]]$Files
    )
    $app = Join-Path $Layout.Root 'app'
    if (Test-PathInside -Path $SourceRoot -Parent $app) {
        Write-Ok "Uruchomiono z $app - kopia bez zmian."
        return $app
    }
    if (-not $Files) { $Files = Get-StackPackageFiles -SourceRoot $SourceRoot }
    if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force }
    New-Directory $app
    foreach ($f in $Files) {
        $dst = Join-Path $app $f
        New-Directory (Split-Path -Parent $dst)
        Copy-Item -LiteralPath (Join-Path $SourceRoot $f) -Destination $dst -Force
    }
    Write-Utf8NoBom -Path (Join-Path $app 'RELEASE.json') -Content ([ordered]@{
        Version = $Release.Version; Commit = $Release.Commit; BuiltAt = $Release.BuiltAt } | ConvertTo-Json)
    Get-ChildItem -LiteralPath $app -Recurse -File | Unblock-File
    Write-Ok "Kopia plików instalacyjnych: $app ($($Files.Count) plików, wersja $($Release.Version))"
    return $app
}

function Get-StackDocsUrl {
    <# Adres dokumentacji dla wersji: tag wydania albo main (klon / wersja dev). #>
    param([Parameter(Mandatory)]$Release)
    if ($Release.Dev) { return "$script:PublicRepoUrl/blob/main" }
    return "$script:PublicRepoUrl/blob/v$($Release.Version)"
}

function Assert-SafeRemoveRoot {
    <#
        Przed Remove-Item katalogu instalacji: odmowa, gdy zawiera repozytorium git; potwierdzenie, gdy zawiera
        elementy spoza układu stosu/agenta (-Force pomija pytanie).
    #>
    param([Parameter(Mandatory)]$Layout, [switch]$Force)
    $root = $Layout.Root
    if (-not (Test-Path -LiteralPath $root)) { return }
    $gitDirs = @()
    foreach ($pattern in '.git', '*\.git', '*\*\.git') {
        $gitDirs += @(Get-Item -Path (Join-Path $root $pattern) -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    if ($gitDirs.Count) {
        throw ("Katalog instalacji zawiera repozytorium git - usunięcie odrzucone:`n  " + ($gitDirs -join "`n  ") +
               "`nPrzenieś repozytorium poza $root i uruchom ponownie.")
    }
    $known = 'bin', 'config', 'data', 'logs', 'services', 'secrets', 'downloads', 'agent-bundle', 'agent-bundle.zip', 'app'
    $unknown = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $known -notcontains $_.Name.ToLowerInvariant() } | ForEach-Object { $_.FullName })
    if ($unknown.Count) {
        Write-Warn "Katalog instalacji zawiera elementy spoza stosu:`n      $($unknown -join "`n      ")"
        if (-not $Force) {
            $answer = $null
            try { $answer = Read-Host "Usunąć $root razem z nimi? (tak/nie)" }
            catch { throw 'Brak konsoli do potwierdzenia - nic nie usunięto. Przenieś pliki spoza stosu albo uruchom z -Force.' }
            if ($answer -ne 'tak') { throw 'Przerwano - nic nie usunięto z katalogu instalacji (pliki spoza stosu: przenieś je albo użyj -Force).' }
        }
    }
}

function Remove-StackRoot {
    <# Usuwa katalog instalacji; bieżący katalog poza nim (blokada katalogu bieżącego przy uruchomieniu z app\). #>
    param([Parameter(Mandatory)]$Layout)
    if (Test-PathInside -Path (Get-Location).ProviderPath -Parent $Layout.Root) { Set-Location -LiteralPath $env:SystemRoot }
    [Environment]::CurrentDirectory = $env:SystemRoot
    Remove-Item -LiteralPath $Layout.Root -Recurse -Force
}

# ---------------------------------------------------------------------
# Ustawienia instalacji (bez sekretów)
# ---------------------------------------------------------------------
function Save-InstallSettings {
    param([Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][hashtable]$Settings)
    $path = Join-Path $Layout.Config 'install-settings.json'
    Write-Utf8NoBom -Path $path -Content ($Settings | ConvertTo-Json -Depth 5)
}

function Get-InstallSettings {
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path (Join-Path $Root 'config') 'install-settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

Export-ModuleMember -Function *
