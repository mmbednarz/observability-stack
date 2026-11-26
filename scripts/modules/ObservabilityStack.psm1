#Requires -Version 5.1
<#
    Shared functions of the WEBCON observability stack.
    Compatibility: Windows PowerShell 5.1 and PowerShell 7+ (no ternary, ??, -Parallel).
    .ps1/.psm1 files must be saved as UTF-8 with BOM (non-ASCII characters in PS 5.1).
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "    $Message" }

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the script as administrator.'
    }
}

# ---------------------------------------------------------------------
# Directory layout
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

# Windows path as a literal in an Alloy string ("C:\\dir\\file")
function ConvertTo-AlloyPath { param([string]$Path) return ($Path -replace '\\', '\\') }

function New-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# ---------------------------------------------------------------------
# Network / ports
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
    } catch { return 'unknown process' }
}

function Test-TcpEndpoint {
    <# Fast TCP connection test (Test-NetConnection in PS 5.1 waits ~20 s when blocked) #>
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
# Download and extraction
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
    $ProgressPreference = 'SilentlyContinue'   # in PS 5.1 the progress bar slows IWR down many times over
    try {
        for ($i = 1; $i -le $Retries; $i++) {
            try {
                Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
                return
            } catch {
                if ($i -eq $Retries) { throw "Failed to download $Url : $($_.Exception.Message)" }
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
        Write-Warn "Checksum file not available ($ChecksumUrl) - skipping verification."
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
    Write-Warn "Checksum file has no entry for $FileName - skipping verification."
    return $null
}

function Install-StackComponent {
    <#
        Downloads the artifact, verifies SHA256, extracts it and places it in bin\<Name>.
        Returns the full path to the executable.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Definition,
        [Parameter(Mandatory)]$Layout,
        [switch]$Force,
        # Agent: artifact from the bundle (no download), SHA256 computed by the stack installer
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
                Write-Ok "$Name $version already installed."
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
            Write-Info "Downloading $url"
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
            throw "SHA256 mismatch for $fileName (expected $expected, got $actual)."
        }
        Write-Ok "SHA256 of $fileName verified."
    }

    $staging = Join-Path $Layout.Downloads ("extract-$Name-" + [Guid]::NewGuid().ToString('N'))
    New-Directory $staging
    try {
        if ($fileName -like '*.zip') {
            Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
        } elseif ($fileName -like '*.tar.gz' -or $fileName -like '*.tgz') {
            $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
            if (-not (Test-Path -LiteralPath $tar)) { throw 'tar.exe not found (requires Windows Server 2019+ / Windows 10 1803+).' }
            & $tar -xzf $archive -C $staging
            if ($LASTEXITCODE -ne 0) { throw "tar.exe exited with code $LASTEXITCODE" }
        } else {
            Copy-Item -LiteralPath $archive -Destination (Join-Path $staging $fileName) -Force
        }

        $exe = Get-ChildItem -LiteralPath $staging -Recurse -Filter $Definition.Exe -File | Select-Object -First 1
        if (-not $exe) { throw "$($Definition.Exe) not found in $fileName." }

        # Distribution root: for Grafana the parent of "bin", for the others the directory containing the exe
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
    Write-Ok "$Name $version installed in $target"
    return $installedExe.FullName
}

function Get-InstalledComponentVersion {
    # Version from bin\<Name>\.version (written by Install-StackComponent); empty = not installed
    param([Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$Name)
    $marker = Join-Path (Join-Path $Layout.Bin $Name) '.version'
    if (Test-Path -LiteralPath $marker) { return (Get-Content -LiteralPath $marker -Raw).Trim() }
    return ''
}

function Invoke-TempoFlush {
    <#
        Tempo 2.x before the upgrade to 3.x: writes the ingester WAL blocks to storage (POST /flush) and waits until
        every block from the WAL is in storage (meta.json). 3.x does not read the 2.x WAL - without this the last
        minutes of traces are lost. Call it after Alloy is stopped (no new traces). Returns $null or a warning text.
    #>
    param([Parameter(Mandatory)][string]$DataDir, [string]$BaseUrl = 'http://127.0.0.1:3200', [int]$TimeoutSec = 90)
    $wal = Join-Path $DataDir 'tempo\wal'
    $ids = @()
    $ids += @(Get-ChildItem -LiteralPath $wal -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[0-9a-f-]{36}\+' } |
        ForEach-Object { $_.Name -replace '\+.*$', '' })
    $ids += @(Get-ChildItem -Path (Join-Path $wal 'blocks\*') -Directory -ErrorAction SilentlyContinue | Get-ChildItem -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9a-f-]{36}$' } | ForEach-Object { $_.Name })
    if (-not $ids) { return $null }
    try { $null = Invoke-WebRequest -Uri "$BaseUrl/flush" -Method Post -UseBasicParsing -TimeoutSec 30 }
    catch { return "Tempo /flush failed: $($_.Exception.Message)" }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        # meta.compacted.json: the block is in storage and was already compacted (blocks kept in wal\blocks after the flush)
        $missing = @($ids | Where-Object { -not (Test-Path -Path (Join-Path $DataDir "tempo\blocks\*\$_\meta*.json")) })
        if (-not $missing) { return $null }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return "$($missing.Count) of $($ids.Count) Tempo WAL blocks not in storage after $TimeoutSec s - the last minutes of traces may be lost"
}

function Invoke-NativeTool {
    <#
        Runs a native tool and returns @{ ExitCode; Output }.
        With ErrorActionPreference=Stop, PS 5.1 turns every stderr line (e.g. Loki/Alloy logs) into an exception -
        hence Continue locally; the exit code decides the result.
    #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
    return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

# ---------------------------------------------------------------------
# Templates and files
# ---------------------------------------------------------------------
function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    New-Directory (Split-Path -Parent $Path)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Expand-StackTemplate {
    <#
        Replaces {{KEY}} with values from $Variables.
        Blocks "// @@BEGIN NAME" ... "// @@END NAME" (or "# @@BEGIN ...") are removed when NAME is in $RemoveBlocks.
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
    # Remove the remaining block markers (active blocks)
    $text = [regex]::Replace($text, '(?m)^[ \t]*(//|#)[ \t]*@@(BEGIN|END) [A-Z_]+[^\r\n]*\r?\n', '')
    foreach ($key in $Variables.Keys) {
        $text = $text.Replace('{{' + $key + '}}', [string]$Variables[$key])
    }
    $left = [regex]::Matches($text, '\{\{[A-Z0-9_]+\}\}') | ForEach-Object { $_.Value } | Select-Object -Unique
    if ($left) { throw "Unsubstituted variables in ${TemplatePath}: $($left -join ', ')" }
    return $text
}

function Set-SecretFile {
    <# Writes a secret to a file and restricts the ACL to SYSTEM + Administrators. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    Write-Utf8NoBom -Path $Path -Content $Content
    $null = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F'
    if ($LASTEXITCODE -ne 0) { throw "icacls failed to set the ACL for $Path" }
}

function Protect-SecretsDirectory {
    param([Parameter(Mandatory)][string]$Path)
    New-Directory $Path
    $null = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) { throw "icacls failed to set the ACL for $Path" }
}

function New-RandomPassword {
    param([int]$Length = 24)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    # Upper + lower case letters + a digit: SQL Server complexity requirement (CHECK_POLICY = ON)
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
# Windows services (WinSW 2.x)
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

    # XML built with XmlDocument - correct escaping of arguments
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
        if ($LASTEXITCODE -ne 0) { throw "WinSW install for $Id exited with code $LASTEXITCODE" }
        Write-Ok "Service $Id registered."
    } else {
        Write-Ok "Service $Id updated (WinSW configuration)."
    }
}

function Uninstall-WinSWService {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$ServicesRoot)
    $svc = Get-Service -Name $Id -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Info "Service $Id does not exist."; return }
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
    Write-Ok "Service $Id removed."
}

# ---------------------------------------------------------------------
# SQL Server
# ---------------------------------------------------------------------
function ConvertFrom-SqlServerName {
    <# "host", "host\INST", "host,1433", "host\INST,1433" -> object #>
    param([Parameter(Mandatory)][string]$Server)
    $hostPart = $Server; $port = $null; $instance = $null
    if ($hostPart -match '^(.*),(\d+)$') { $hostPart = $Matches[1]; $port = [int]$Matches[2] }
    if ($hostPart -match '^(.*)\\(.+)$') { $hostPart = $Matches[1]; $instance = $Matches[2] }
    if ($hostPart -eq '.' -or $hostPart -eq '(local)') { $hostPart = 'localhost' }
    return [pscustomobject]@{ Host = $hostPart; Instance = $instance; Port = $port }
}

function New-MssqlExporterConnectionString {
    <# Connection string in go-mssqldb (URL) format for prometheus.exporter.mssql #>
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
        Connects with the SQL login and checks the permissions required by prometheus.exporter.mssql.
        Returns an object with the fields: Success, Checks (list), Remediation (T-SQL).
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
            Add-Check 'Connection (SQL login, master database)' $true "Version: $($conn.ServerVersion)"
        } catch {
            Add-Check 'Connection (SQL login, master database)' $false $_.Exception.Message
            return [pscustomobject]@{ Success = $false; Checks = $checks; Remediation = $null }
        }

        $edition = [string](Invoke-SqlScalarQuery $conn "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128))")
        if ($edition -like '*Azure*' -or $edition -eq 'SQL Azure') {
            Add-Check 'Server type' $false "Edition '$edition' - the exporter is intended for SQL Server (on-premises / VM)."
        }

        $isSysadmin = [int](Invoke-SqlScalarQuery $conn "SELECT IS_SRVROLEMEMBER('sysadmin')")
        if ($isSysadmin -eq 1) {
            Add-Check 'No sysadmin role (least privilege)' $false 'The login is sysadmin - it works, but has excessive permissions. Use a dedicated login with GRANT as in sql/grant-sql-exporter-permissions.sql.'
        } else {
            Add-Check 'No sysadmin role (least privilege)' $true ''
        }

        foreach ($perm in @('VIEW SERVER STATE', 'VIEW ANY DEFINITION')) {
            $has = [int](Invoke-SqlScalarQuery $conn "SELECT HAS_PERMS_BY_NAME(NULL, NULL, '$perm')")
            Add-Check "Permission $perm" ($has -eq 1) ''
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
                if ($k -eq 'sys.master_files' -and [int]$v -eq 0) { $ok = $false; $detail = 'No database files visible (requires VIEW ANY DEFINITION).' }
                Add-Check "Read $k" $ok $detail
            } catch {
                Add-Check "Read $k" $false $_.Exception.Message
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
    $success = -not ($checks | Where-Object { -not $_.Ok -and $_.Check -ne 'No sysadmin role (least privilege)' })
    return [pscustomobject]@{ Success = [bool]$success; Checks = $checks; Remediation = $remediation }
}

function Test-WebconSqlReaderPermissions {
    <#
        Connects to the content database with the login of the "WEBCON SQL" Grafana data source and checks SELECT on the tables
        from sql\grant-webcon-reader-permissions.sql. Returns an object with the fields: Success, Checks (list).
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
            Add-Check "Connection (SQL login, database $Database)" $true ''
        } catch {
            Add-Check "Connection (SQL login, database $Database)" $false $_.Exception.Message
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
        # Excessive permissions - any dashboard editor can write queries in Grafana
        $wide = [int](Invoke-SqlScalarQuery $conn "SELECT IS_SRVROLEMEMBER('sysadmin') + ISNULL(IS_ROLEMEMBER('db_owner'), 0) + ISNULL(IS_ROLEMEMBER('db_datareader'), 0)")
        if ($wide -gt 0) {
            Add-Check 'Read-only access to selected tables (least privilege)' $false 'The login has sysadmin / db_owner / db_datareader - Grafana editors will see form data. Use a login from sql\grant-webcon-reader-permissions.sql.'
        } else {
            Add-Check 'Read-only access to selected tables (least privilege)' $true ''
        }
    } finally {
        $conn.Dispose()
    }
    $success = -not ($checks | Where-Object { -not $_.Ok -and $_.Check -ne 'Read-only access to selected tables (least privilege)' })
    return [pscustomobject]@{ Success = [bool]$success; Checks = $checks }
}

function ConvertFrom-MssqlConnectionUrl {
    <# Inverse of New-MssqlExporterConnectionString: sqlserver://login:password@host[:port][/instance]?... -> Server, Login, Password #>
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

# Columns used in config-templates/alloy/webcon-db-queries.yaml (= GRANT in sql/grant-webcon-db-metrics.sql)
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
        Checks (as the exporter login) access to the content database and SELECT on the columns from webcon-db-queries.yaml.
        Returns an object with the fields: Success, Checks (list).
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
            Add-Check "Access to database $Database" $true ''
        } catch {
            Add-Check "Access to database $Database" $false $_.Exception.Message
            return [pscustomobject]@{ Success = $false; Checks = $checks }
        }
        foreach ($t in $script:WebconDbMetricsColumns.Keys) {
            $missing = @()
            foreach ($c in $script:WebconDbMetricsColumns[$t]) {
                $has = Invoke-SqlScalarQuery $conn "SELECT HAS_PERMS_BY_NAME(N'dbo.$t', N'OBJECT', N'SELECT', N'$c', N'COLUMN')"
                if ([string]$has -ne '1') { $missing += $c }
            }
            if ($missing) { Add-Check "SELECT dbo.$t" $false "missing: $($missing -join ', ')" } else { Add-Check "SELECT dbo.$t (columns)" $true '' }
        }
    } finally {
        $conn.Dispose()
    }
    $success = -not ($checks | Where-Object { -not $_.Ok })
    return [pscustomobject]@{ Success = [bool]$success; Checks = $checks }
}

function Get-WebconPortalBinding {
    <#
        http/https bindings of the WEBCON Portal IIS site: the site whose "/" application points to a directory with
        a web.config that starts WebCon.WorkFlow.Bootstrapper (ASP.NET Core Module). Skips stopped sites.
        Returns a list of objects: Protocol, Port, Host ('' = binding without a host name), Site.
        Design: docs/projekt/projekt-sonda-portalu-adres.md
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
        foreach ($b in @($site.site.bindings.binding)) {
            if ($b.protocol -ne 'http' -and $b.protocol -ne 'https') { continue }
            # address:port:host; an IPv6 address in brackets contains colons
            if ($b.bindingInformation -notmatch '^(.*):(\d+):([^:]*)$') { continue }
            $h = $Matches[3]
            if ($h -eq '*') { $h = '' }
            $result.Add([pscustomobject]@{ Protocol = [string]$b.protocol; Port = [int]$Matches[2]; Host = $h; Site = $site.'SITE.NAME' })
        }
    }
    # ToArray(): ",@(List)" throws "Argument types do not match" in pwsh 7
    return ,($result.ToArray())
}

function ConvertTo-PortalUrl {
    <#
        Normalizes the Portal address (-PortalUrl) to <scheme>://<host>[:port] (the path is dropped).
        Throws on an invalid address (the host is inserted into YAML / config.alloy - DNS name characters only).
    #>
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -notmatch '^(?i)(https?)://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:(\d{1,5}))?(/.*)?$') {
        throw "-PortalUrl: invalid address '$Url' (expected http(s)://host.name[:port], e.g. https://bps.example.com)."
    }
    $scheme = $Matches[1].ToLowerInvariant()
    $hostName = $Matches[2]
    $portPart = ''
    if ($Matches[5]) {
        $port = [int]$Matches[5]
        if ($port -lt 1 -or $port -gt 65535) { throw "-PortalUrl: invalid port in '$Url'." }
        if (-not (($scheme -eq 'https' -and $port -eq 443) -or ($scheme -eq 'http' -and $port -eq 80))) { $portPart = ":$port" }
    }
    return "$scheme`://$hostName$portPart"
}

function Get-PortalUrlSuggestion {
    <# Portal address from IIS bindings with a host name (https first, then http); '' when there is none. #>
    param([object[]]$Binding = @())
    $named = @($Binding | Where-Object { $_ -and $_.Host })
    $b = @(@($named | Where-Object { $_.Protocol -eq 'https' }) + @($named | Where-Object { $_.Protocol -eq 'http' })) | Select-Object -First 1
    if (-not $b) { return '' }
    return ConvertTo-PortalUrl "$($b.Protocol)://$($b.Host):$($b.Port)"
}

function Resolve-PortalProbeTarget {
    <#
        Portal /health probe target: local connection (127.0.0.1) to the port from the Portal address, Host: localhost
        header, SNI and certificate verification for the host name from the Portal address, instance = Portal address.
        Empty -PortalUrl = address from IIS bindings with a host name (Get-PortalUrlSuggestion); only bindings without
        a host name = no target. When the site has no <scheme>:<port> binding from the address (e.g. TLS terminated on
        a load balancer) - the first http binding of the site, without certificate verification.
        Returns: Target (Url, Address, ServerName, Site; $null = no probe), Messages (Level ok/info/warn, Text).
        Design: docs/projekt/projekt-sonda-portalu-adres.md
    #>
    param([string]$PortalUrl, [object[]]$Binding = @())
    $msgs = New-Object System.Collections.Generic.List[object]
    $Binding = @($Binding | Where-Object { $_ })
    $source = '-PortalUrl'
    if ($PortalUrl) {
        $url = ConvertTo-PortalUrl $PortalUrl
    } else {
        if (-not $Binding.Count) {
            $msgs.Add([pscustomobject]@{ Level = 'info'; Text = 'WEBCON Portal not detected in IIS (site with WebCon.WorkFlow.Bootstrapper) - no Portal probe.' })
            return [pscustomobject]@{ Target = $null; Messages = $msgs.ToArray() }
        }
        $url = Get-PortalUrlSuggestion -Binding $Binding
        if (-not $url) {
            $msgs.Add([pscustomobject]@{ Level = 'warn'; Text = 'The IIS bindings of the Portal site have no host name - Portal address unknown. No Portal probe; specify -PortalUrl (e.g. https://bps.example.com).' })
            return [pscustomobject]@{ Target = $null; Messages = $msgs.ToArray() }
        }
        $source = 'IIS binding'
    }
    $uri = [Uri]$url
    $scheme = $uri.Scheme
    $port = $uri.Port
    $site = ''
    $match = @($Binding | Where-Object { $_.Protocol -eq $scheme -and $_.Port -eq $port }) | Select-Object -First 1
    if ($match) {
        $site = $match.Site
    } elseif ($Binding.Count) {
        $http = @($Binding | Where-Object { $_.Protocol -eq 'http' }) | Select-Object -First 1
        if ($http) {
            $msgs.Add([pscustomobject]@{ Level = 'warn'; Text = "The Portal site has no $scheme binding on port $port - local probe over http on port $($http.Port), without certificate verification." })
            $scheme = 'http'; $port = $http.Port; $site = $http.Site
        } else {
            $msgs.Add([pscustomobject]@{ Level = 'warn'; Text = "The Portal site has no $scheme binding on port $port - the probe may get no response." })
        }
    } else {
        $msgs.Add([pscustomobject]@{ Level = 'warn'; Text = "WEBCON Portal not detected in IIS - probe on $scheme`://127.0.0.1:$port." })
    }
    $serverName = ''
    if ($scheme -eq 'https') { $serverName = $uri.Host }
    $target = [pscustomobject]@{ Url = $url; Address = "$scheme`://127.0.0.1:$port/health"; ServerName = $serverName; Site = $site }
    $siteText = ''
    if ($site) { $siteText = ", IIS site '$site'" }
    $msgs.Add([pscustomobject]@{ Level = 'ok'; Text = "Portal: $url ($source; probe $($target.Address)$siteText)" })
    return [pscustomobject]@{ Target = $target; Messages = $msgs.ToArray() }
}

function New-BlackboxConfig {
    <#
        Fragments of the BLACKBOX block in config.alloy: modules (YAML, indented under "modules:") and target blocks.
        Portal (Resolve-PortalProbeTarget): local address, Host: localhost header, tls_config.server_name = host name
        from the Portal address, portal_url label -> instance (discovery.relabel); -ProbeUrl: http_2xx module.
    #>
    param([object]$PortalTarget, [string[]]$ProbeUrl = @())
    $modules = New-Object System.Collections.Generic.List[string]
    $targets = New-Object System.Collections.Generic.List[string]
    if ($PortalTarget) {
        $tls = ''
        if ($PortalTarget.ServerName) {
            $tls = "`n      tls_config:`n        server_name: '$($PortalTarget.ServerName)'"
        }
        $modules.Add(@"
  webcon_health:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      valid_status_codes: [200]
      no_follow_redirects: true
      headers:
        Host: localhost$tls
      fail_if_body_not_matches_regexp:
        - '"status":"Healthy"'
"@)
        $targets.Add(@"
  target {
    name    = "portal"
    address = "$($PortalTarget.Address)"
    module  = "webcon_health"
    labels  = { "probe" = "portal", "portal_url" = "$($PortalTarget.Url)" }
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

# windows_exporter collectors as an Alloy list; "iis" only when IIS is installed (otherwise success=0 on every scrape)
function Get-HostIPv4Address {
    # IPv4 addresses of a host (DNS) or of this machine (no -ComputerName), without loopback / APIPA.
    # WEBCON calls its own components (Solr :8983, Service) by IP as well - those calls are excluded from the external API panels and alert W9.
    param([string]$ComputerName)
    try {
        if ($ComputerName) { $ips = [Net.Dns]::GetHostAddresses($ComputerName) }
        else { $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { [Net.IPAddress]::Parse($_.IPAddress) } }
    } catch { return @() }
    $ips | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.IPAddressToString } | Where-Object { $_ -notmatch '^(127\.|169\.254\.)' } | Sort-Object -Unique
}

function Get-WindowsCollectorList {
    $c = @('cpu', 'logical_disk', 'memory', 'net', 'os', 'system', 'process', 'tcp')
    if (Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue) { $c += 'iis' }
    return (($c | ForEach-Object { '"' + $_ + '"' }) -join ', ')
}

# ---------------------------------------------------------------------
# SQL Server - local instance (agent on the SQL host)
# ---------------------------------------------------------------------
function Get-SqlInstanceInfo {
    <#
        SQL Server instance on this host: service, TCP settings from the registry, ports it actually listens on,
        and the Data Source for a local connection (shared memory - works also with TCP disabled).
    #>
    param([Parameter(Mandatory)][string]$InstanceName)
    $svcName = 'MSSQLSERVER'
    $dataSource = '.'
    if ($InstanceName -ne 'MSSQLSERVER') { $svcName = 'MSSQL$' + $InstanceName; $dataSource = ".\$InstanceName" }
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($svcName.Replace("'", "''"))'"
    if (-not $svc) { throw "SQL Server service $svcName (instance $InstanceName) not found on this host." }

    $names = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
    $id = $names.$InstanceName
    if (-not $id) { throw "Instance $InstanceName not found in the SQL Server registry." }
    $tcpKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\MSSQLServer\SuperSocketNetLib\Tcp"
    $tcp = Get-ItemProperty -Path $tcpKey
    $ipAll = Get-ItemProperty -Path "$tcpKey\IPAll"

    $ports = @()
    if ($svc.ProcessId) {
        # without loopback addresses: DAC listens there
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
    <# Enables TCP and sets a static port (IPAll) for the instance, restarts the instance and starts dependent services again (e.g. Agent). #>
    param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)][int]$Port)
    Set-ItemProperty -Path $Info.TcpKey -Name Enabled -Value 1
    Set-ItemProperty -Path "$($Info.TcpKey)\IPAll" -Name TcpPort -Value ([string]$Port)
    Set-ItemProperty -Path "$($Info.TcpKey)\IPAll" -Name TcpDynamicPorts -Value ''
    $dependents = @(Get-Service -Name $Info.ServiceName -DependentServices | Where-Object Status -eq 'Running' | Select-Object -ExpandProperty Name)
    Restart-Service -Name $Info.ServiceName -Force
    foreach ($d in $dependents) { Start-Service -Name $d -ErrorAction SilentlyContinue }
}

function Invoke-SqlBatches {
    <# Runs a T-SQL script with GO separators; messages (PRINT / RAISERROR < 11) are written as information. #>
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
    <# Creates a SQL login or sets its password (password from the agent bundle = single source of truth for the stack and the SQL host). #>
    param([Parameter(Mandatory)][string]$ConnectionString, [Parameter(Mandatory)][string]$Login, [Parameter(Mandatory)][string]$Password)
    $l = $Login.Replace("'", "''")
    $q = '[' + $Login.Replace(']', ']]') + ']'
    $p = $Password.Replace("'", "''")
    $sql = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$l') " +
           "CREATE LOGIN $q WITH PASSWORD = N'$p', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = [master]; " +
           "ELSE IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$l' AND PWDCOMPARE(N'$p', password_hash) = 1) " +
           "ALTER LOGIN $q WITH PASSWORD = N'$p';"   # re-run: no password change (password history with CHECK_POLICY)
    Invoke-SqlBatches -ConnectionString $ConnectionString -Sql $sql
}

# ---------------------------------------------------------------------
# Agent bundle (remote mode)
# ---------------------------------------------------------------------
function Write-Utf8Bom {
    <# .ps1 scripts with non-ASCII characters: UTF-8 with BOM (PS 5.1) #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    New-Directory (Split-Path -Parent $Path)
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function New-AgentBundle {
    <#
        Creates <Root>\agent-bundle (+ .zip): agent installer, module, Alloy templates, SQL scripts, Alloy/WinSW binaries
        from the downloads directory, settings (agent-settings.json), SQL login passwords and 01-/02- scripts for the hosts.
        Returns the bundle directory path.
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
    # The bundle contains SQL passwords - same ACL as the secrets directory
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

    # Binaries from the stack downloads (downloaded and verified by Install-StackComponent)
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

    # Host scripts: SQL before WEBCON (a possible SQL restart and the WEBCON restart in one window)
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
    $readme.Add('Agent bundle - WEBCON observability stack')
    $readme.Add("Generated: $($Settings.GeneratedAt) on $env:COMPUTERNAME; stack: $($Settings.CentralAddress); version $($Release.Version)")
    $readme.Add($script:Disclaimer)
    $readme.Add('')
    $readme.Add('CONTAINS SQL LOGIN PASSWORDS (secrets\sql-logins.json) - delete the bundle from the hosts after installation.')
    $readme.Add('')
    $readme.Add('Order (PowerShell as administrator, in the extracted bundle directory):')
    foreach ($h in $hosts) {
        $script = ('{0:00}-{1}.ps1' -f $i, $h.Name)
        $roleText = $h.Role
        $content = @(
            '#Requires -Version 5.1'
            "# Generated by Install-ObservabilityStack.ps1 ($($Settings.GeneratedAt)) - host: $($h.Host), role: $roleText"
            '# Additional parameters are passed to Install-ObservabilityAgent.ps1, e.g. -EnableSqlTcp, -Force, -SkipWebconConfig'
            "& (Join-Path `$PSScriptRoot 'Install-ObservabilityAgent.ps1') -Role $roleText @args"
        ) -join "`r`n"
        Write-Utf8Bom -Path (Join-Path $bundle $script) -Content ($content + "`r`n")
        $line = "  $i. host $($h.Host): .\$script"
        if ($h.Role -like '*Sql*') { $line += '   (instance TCP disabled: add -EnableSqlTcp = SQL instance restart)' }
        $readme.Add($line)
        $i++
    }
    $readme.Add("  $i. stack VM ($env:COMPUTERNAME): .\Test-ObservabilityStack.ps1")
    $readme.Add('')
    $readme.Add("Required connectivity: host -> $($Settings.CentralAddress) TCP $($Settings.OtlpPort), $($Settings.ReceivePort)")
    $readme.Add("  (stack firewall allows: $($Settings.AgentAddress -join ', '))")
    if ($SqlHost -and $Settings.ReaderLogin) {
        $readme.Add("Grafana -> $SqlHost TCP $($Settings.SqlPort) ('WEBCON SQL' data source; the SQL host script adds a firewall rule for $($Settings.CentralIPv4 -join ', '))")
    }
    $readme.Add('')
    $readme.Add('After installation the bundle can be deleted - to uninstall the agent: C:\Observability\app\Uninstall-ObservabilityAgent.ps1 [-RemoveFiles]')
    Write-Utf8NoBom -Path (Join-Path $bundle 'README.txt') -Content (($readme -join "`r`n") + "`r`n")

    $zip = "$bundle.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip -CompressionLevel Fastest }
    finally { $ProgressPreference = $old }
    $null = & icacls.exe $zip /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F'
    Write-Ok "Bundle: $bundle ($zip, $([math]::Round((Get-Item -LiteralPath $zip).Length / 1MB)) MB)"
    foreach ($h in $hosts) { Write-Ok "Host $($h.Host): role $($h.Role)" }
    return $bundle
}

# ---------------------------------------------------------------------
# Releases, version, app\ copy (docs/projekt/projekt-dystrybucja-i-wersje.md)
# ---------------------------------------------------------------------
$script:PublicRepoUrl = 'https://github.com/mmbednarz/observability-stack'
# Documentation site (GitHub Pages of the public repository, one copy per release - mkdocs.yml, mike)
$script:DocsSiteUrl = 'https://mmbednarz.github.io/observability-stack'
$script:Disclaimer = 'Unofficial project, without support or warranty (MIT license) - not a WEBCON product. Details: README.md.'

# Contents of the release package and of the C:\Observability\app copy. Directory = entry ending with "\" (recursive).
# A new repository file outside these entries will not be included in the package - build\New-ReleasePackage.ps1 checks this.
$script:PackageEntries = @(
    'Install-ObservabilityStack.ps1', 'Install-ObservabilityAgent.ps1',
    'Uninstall-ObservabilityStack.ps1', 'Uninstall-ObservabilityAgent.ps1', 'Test-ObservabilityStack.ps1',
    'versions.psd1', 'VERSION', 'CHANGELOG.md', 'README.md', 'LICENSE', '.gitattributes',
    'config-templates\', 'dashboards\', 'scripts\', 'sql\', 'webcon\',
    'docs\README.md', 'docs\installation\', 'docs\user-guide\', 'docs\img\'
)
# Local files excluded from the package and from app\ (backups, logs)
$script:PackageExcludeRegex = '(\.bak-[^\\]*|\.log|\.tmp)$'

function Write-StackDisclaimer { Write-Host $script:Disclaimer -ForegroundColor DarkGray }

function Get-StackPackageFiles {
    <# Relative paths (with "\") of the package files in the source directory (repository, package or app\). #>
    param([Parameter(Mandatory)][string]$SourceRoot)
    $SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($e in $script:PackageEntries) {
        $p = Join-Path $SourceRoot $e.TrimEnd('\')
        if ($e.EndsWith('\')) {
            if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw "Package directory missing: $e (in $SourceRoot)" }
            foreach ($f in Get-ChildItem -LiteralPath $p -Recurse -File -Force) {
                $rel = $f.FullName.Substring($SourceRoot.Length + 1)
                if ($rel -notmatch $script:PackageExcludeRegex) { $files.Add($rel) }
            }
        } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            $files.Add($e)
        } else {
            throw "Package file missing: $e (in $SourceRoot)"
        }
    }
    return ,([string[]]($files.ToArray() | Sort-Object))
}

function Get-StackRelease {
    <#
        Version of the installation files: RELEASE.json (release package, app\) or VERSION + git commit (clone).
        Clone: Version = "X.Y.Z+dev.<commit>" (build metadata - same position as X.Y.Z when comparing versions).
    #>
    param([Parameter(Mandatory)][string]$SourceRoot)
    $releaseFile = Join-Path $SourceRoot 'RELEASE.json'
    if (Test-Path -LiteralPath $releaseFile) {
        $r = Get-Content -LiteralPath $releaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ Version = [string]$r.Version; Commit = [string]$r.Commit; BuiltAt = [string]$r.BuiltAt; Dev = ([string]$r.Version -like '*+dev*') }
    }
    $versionFile = Join-Path $SourceRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile)) { throw "Neither VERSION nor RELEASE.json found in $SourceRoot." }
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
    <# X.Y.Z part of the version (without "+..." metadata) as [version]; none = 0.0.0. #>
    param([string]$Version)
    if (-not $Version) { return [version]'0.0.0' }
    $core = ($Version -split '[+-]')[0]
    try { return [version]$core } catch { throw "Invalid version number: '$Version'." }
}

function Test-PathInside {
    <# Whether $Path is the $Parent directory or lies inside it (case-insensitive). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    $q = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    return $p.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-InstallLocation {
    <# Installation files must not be inside the installation directory (except app\) nor contain it. #>
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)]$Layout)
    $app = Join-Path $Layout.Root 'app'
    if ((Test-PathInside -Path $SourceRoot -Parent $Layout.Root) -and -not (Test-PathInside -Path $SourceRoot -Parent $app)) {
        throw ("The installation files ($SourceRoot) are inside the installation directory $($Layout.Root) - removing the stack with -RemoveFiles " +
               "would delete them together with the data. Move them (e.g. to C:\Install) and run again.")
    }
    if (Test-PathInside -Path $Layout.Root -Parent $SourceRoot) {
        throw "The installation directory $($Layout.Root) is inside the installation files directory ($SourceRoot) - choose a different -Root."
    }
}

function Copy-StackApp {
    <#
        Recreates <Root>\app from the installation files (smoke test, uninstall, parameter changes without the package).
        $Files = relative paths; none = full package list. Running from app\ = skipped (same version).
    #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)]$Release,
        [string[]]$Files
    )
    $app = Join-Path $Layout.Root 'app'
    if (Test-PathInside -Path $SourceRoot -Parent $app) {
        Write-Ok "Running from $app - copy left unchanged."
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
    Write-Ok "Installation files copy: $app ($($Files.Count) files, version $($Release.Version))"
    return $app
}

function Get-StackDocsUrl {
    <# Documentation site URL for the version: copy of the release or latest (clone / dev version). #>
    param([Parameter(Mandatory)]$Release)
    if ($Release.Dev) { return "$script:DocsSiteUrl/latest" }
    return "$script:DocsSiteUrl/$($Release.Version)"
}

function Assert-SafeRemoveRoot {
    <#
        Before Remove-Item of the installation directory: refuses when it contains a git repository; asks for confirmation when it contains
        items outside the stack/agent layout (-Force skips the prompt).
    #>
    param([Parameter(Mandatory)]$Layout, [switch]$Force)
    $root = $Layout.Root
    if (-not (Test-Path -LiteralPath $root)) { return }
    $gitDirs = @()
    foreach ($pattern in '.git', '*\.git', '*\*\.git') {
        $gitDirs += @(Get-Item -Path (Join-Path $root $pattern) -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    if ($gitDirs.Count) {
        throw ("The installation directory contains a git repository - removal refused:`n  " + ($gitDirs -join "`n  ") +
               "`nMove the repository outside $root and run again.")
    }
    $known = 'bin', 'config', 'data', 'logs', 'services', 'secrets', 'downloads', 'agent-bundle', 'agent-bundle.zip', 'app'
    $unknown = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $known -notcontains $_.Name.ToLowerInvariant() } | ForEach-Object { $_.FullName })
    if ($unknown.Count) {
        Write-Warn "The installation directory contains items that do not belong to the stack:`n      $($unknown -join "`n      ")"
        if (-not $Force) {
            $answer = $null
            try { $answer = Read-Host "Delete $root together with them? (yes/no)" }
            catch { throw 'No console available for confirmation - nothing was deleted. Move the files that do not belong to the stack or run with -Force.' }
            if ($answer -ne 'yes') { throw 'Aborted - nothing was deleted from the installation directory (files that do not belong to the stack: move them or use -Force).' }
        }
    }
}

function Remove-StackRoot {
    <# Removes the installation directory; moves the current directory outside it first (the current directory is locked when running from app\). #>
    param([Parameter(Mandatory)]$Layout)
    if (Test-PathInside -Path (Get-Location).ProviderPath -Parent $Layout.Root) { Set-Location -LiteralPath $env:SystemRoot }
    [Environment]::CurrentDirectory = $env:SystemRoot
    Remove-Item -LiteralPath $Layout.Root -Recurse -Force
}

# ---------------------------------------------------------------------
# Grafana: legacy folders
# ---------------------------------------------------------------------
function Remove-GrafanaEmptyFolder {
    <#
    .SYNOPSIS
    Removes Grafana folders with the given titles if they are empty (no dashboards, no alert rules).
    Used after renaming provisioned alert folders: provisioning moves the rules (same uid) to the new folder,
    but the old folder stays. Without forceDeleteRules Grafana refuses to delete a folder that still has rules.
    Design: docs/projekt/projekt-wersja-angielska.md
    #>
    param(
        [Parameter(Mandatory)][string]$PasswordFile,
        [Parameter(Mandatory)][string[]]$Title,
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [int]$Attempts = 3
    )
    try { $adminPwd = [IO.File]::ReadAllText($PasswordFile, [Text.Encoding]::UTF8) } catch { Write-Warn "Grafana folders not checked - cannot read $PasswordFile"; return }
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$adminPwd")) }
    # Invoke-RestMethod in PS 5.1 decodes the response as ISO-8859-1 (Grafana sends no charset) - non-ASCII folder
    # titles would never match; read the raw bytes as UTF-8
    try {
        $resp = Invoke-WebRequest -Uri "$BaseUrl/api/folders?limit=1000" -Headers $headers -TimeoutSec 20 -UseBasicParsing
        $folders = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    }
    catch { Write-Warn "Grafana folders not checked: $($_.Exception.Message)"; return }
    foreach ($f in $folders) {
        if ($Title -notcontains $f.title) { continue }
        $dash = Invoke-RestMethod -Uri "$BaseUrl/api/search?type=dash-db&folderUIDs=$($f.uid)" -Headers $headers -TimeoutSec 20
        if (@($dash | Where-Object { $_ }).Count -gt 0) { Write-Warn "Grafana folder '$($f.title)' kept - it contains dashboards."; continue }
        $removed = $false
        for ($i = 1; $i -le $Attempts -and -not $removed; $i++) {
            try {
                $null = Invoke-RestMethod -Method Delete -Uri "$BaseUrl/api/folders/$($f.uid)?forceDeleteRules=false" -Headers $headers -TimeoutSec 20
                $removed = $true
            } catch {
                # right after start, provisioning may not have moved the alert rules yet
                if ($i -lt $Attempts) { Start-Sleep -Seconds 10 } else { Write-Warn "Grafana folder '$($f.title)' not removed (it still contains alert rules?): $($_.Exception.Message). It will be retried on the next installer run." }
            }
        }
        if ($removed) { Write-Ok "Removed the empty legacy Grafana folder '$($f.title)'" }
    }
}

# ---------------------------------------------------------------------
# Installation settings (without secrets)
# ---------------------------------------------------------------------
function Save-InstallSettings {
    param([Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][hashtable]$Settings)
    $path = Join-Path $Layout.Config 'install-settings.json'
    Write-Utf8NoBom -Path $path -Content ($Settings | ConvertTo-Json -Depth 5)
}

# Values of installer parameters that installations <= 0.11.0 did not save in install-settings.json,
# read from the generated configuration (docs/projekt/projekt-zapamietywanie-parametrow.md, Z6).
# Returns only the values that could be read.
function Get-LegacyInstallSettings {
    param([Parameter(Mandatory)]$Layout, [bool]$RemoteMode)
    $result = @{}
    $read = {
        param([string]$Path, [string]$Pattern)
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $m = [regex]::Match([IO.File]::ReadAllText($Path), $Pattern, 'Multiline')
        if ($m.Success) { return $m.Groups[1].Value }
        return $null
    }
    $v = & $read (Join-Path $Layout.Config 'grafana\grafana.ini') '^\s*http_addr\s*=\s*(\S+)'
    if ($v) { $result.GrafanaListenAll = ($v -eq '0.0.0.0') }
    if ($RemoteMode) {
        # remote mode: OTLP always listens on 0.0.0.0 - only the firewall rule shows -OtlpListenAll
        $rule = Get-NetFirewallRule -DisplayName 'Observability - OTLP' -ErrorAction SilentlyContinue
        $result.OtlpListenAll = [bool]$rule
    } else {
        $v = & $read (Join-Path $Layout.Config 'alloy\config.alloy') 'endpoint\s*=\s*"([0-9.]+):4318"'
        if ($v) { $result.OtlpListenAll = ($v -eq '0.0.0.0') }
    }
    $v = & $read (Join-Path $Layout.Services 'obs-prometheus\obs-prometheus.xml') '--storage\.tsdb\.retention\.time=(\d+)d'
    if ($v) { $result.RetentionMetricsDays = [int]$v }
    $v = & $read (Join-Path $Layout.Config 'loki\loki.yaml') '^\s*retention_period:\s*(\d+)h'
    if ($v -and ([int]$v % 24) -eq 0) { $result.RetentionLogsDays = [int]$v / 24 }
    $v = & $read (Join-Path $Layout.Config 'alloy\config.alloy') '^\s*limit\s*=\s*"([^"]+)"'
    if ($v) { $result.AlloyMemoryLimit = $v }
    return $result
}

function Get-InstallSettings {
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path (Join-Path $Root 'config') 'install-settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

Export-ModuleMember -Function *
