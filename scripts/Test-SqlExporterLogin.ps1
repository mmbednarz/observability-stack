#Requires -Version 5.1
<#
.SYNOPSIS
    Weryfikuje dedykowany login SQL dla prometheus.exporter.mssql (bez instalacji stosu).

.DESCRIPTION
    Sprawdza: połączenie, brak roli sysadmin, VIEW SERVER STATE, VIEW ANY DEFINITION
    oraz faktyczny odczyt DMV używanych przez exporter. Przy brakach wypisuje T-SQL dla DBA.
    Ta sama weryfikacja jest wykonywana automatycznie przez Install-ObservabilityStack.ps1.

.EXAMPLE
    .\scripts\Test-SqlExporterLogin.ps1 -SqlServer 'SQLDEV01\BPS' -SqlLogin 'svc_obs_mssql_exporter'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SqlServer,
    [Parameter(Mandatory)][string]$SqlLogin,
    [Security.SecureString]$SqlPassword,
    [bool]$SqlEncrypt = $true,
    [bool]$SqlTrustServerCertificate = $true
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'modules\ObservabilityStack.psm1') -Force -DisableNameChecking

if (-not $SqlPassword) { $SqlPassword = Read-Host "Hasło dla $SqlLogin" -AsSecureString }

Write-Step "Weryfikacja loginu $SqlLogin na $SqlServer"
$result = Test-SqlExporterPermissions -Server $SqlServer -Login $SqlLogin -Password $SqlPassword -Encrypt $SqlEncrypt -TrustServerCertificate $SqlTrustServerCertificate
foreach ($c in $result.Checks) {
    $line = $c.Check
    if ($c.Detail) { $line = "$line - $($c.Detail)" }
    if ($c.Ok) { Write-Ok $line } else { Write-Warn $line }
}
if ($result.Remediation) {
    Write-Host ''
    Write-Host 'Do wykonania przez DBA:' -ForegroundColor Yellow
    Write-Host $result.Remediation
}
if ($result.Success) { Write-Ok 'Login gotowy do użycia przez exporter.'; exit 0 }
exit 1
