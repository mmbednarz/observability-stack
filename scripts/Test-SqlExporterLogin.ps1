#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies the dedicated SQL login for prometheus.exporter.mssql (without installing the stack).

.DESCRIPTION
    Checks: connection, no sysadmin role, VIEW SERVER STATE, VIEW ANY DEFINITION
    and actual reads of the DMVs used by the exporter. If anything is missing, prints T-SQL for the DBA.
    Install-ObservabilityStack.ps1 runs the same verification automatically.

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

if (-not $SqlPassword) { $SqlPassword = Read-Host "Password for $SqlLogin" -AsSecureString }

Write-Step "Verifying login $SqlLogin on $SqlServer"
$result = Test-SqlExporterPermissions -Server $SqlServer -Login $SqlLogin -Password $SqlPassword -Encrypt $SqlEncrypt -TrustServerCertificate $SqlTrustServerCertificate
foreach ($c in $result.Checks) {
    $line = $c.Check
    if ($c.Detail) { $line = "$line - $($c.Detail)" }
    if ($c.Ok) { Write-Ok $line } else { Write-Warn $line }
}
if ($result.Remediation) {
    Write-Host ''
    Write-Host 'To be run by the DBA:' -ForegroundColor Yellow
    Write-Host $result.Remediation
}
if ($result.Success) { Write-Ok 'The login is ready for use by the exporter.'; exit 0 }
exit 1
