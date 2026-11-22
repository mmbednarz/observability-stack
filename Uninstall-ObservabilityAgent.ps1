#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the Alloy agent from a WEBCON / SQL host. Files are kept unless -RemoveFiles is specified.

.DESCRIPTION
    Does not change the WEBCON configuration (restore the *.bak-* copies of appsettings / web.config) or SQL logins
    (DROP LOGIN commands are printed at the end).

.EXAMPLE
    .\Uninstall-ObservabilityAgent.ps1 -RemoveFiles
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = 'C:\Observability',
    [switch]$RemoveFiles,
    # -RemoveFiles without prompting about non-stack items in the installation folder (a git repository always blocks removal)
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\modules\ObservabilityStack.psm1') -Force -DisableNameChecking
Assert-Administrator

$Layout = Get-StackLayout -Root $Root
# -RemoveFiles: check the folder contents BEFORE removing services (a refusal does not leave the stack half-removed)
if ($RemoveFiles) { Assert-SafeRemoveRoot -Layout $Layout -Force:$Force }
if (Get-Service -Name 'obs-prometheus' -ErrorAction SilentlyContinue) {
    throw 'The central stack is installed on this host - use Uninstall-ObservabilityStack.ps1.'
}

Write-Step 'Removing the service'
if ($PSCmdlet.ShouldProcess('obs-alloy', 'Uninstall service')) {
    Uninstall-WinSWService -Id 'obs-alloy' -ServicesRoot $Layout.Services
}

Write-Step 'Firewall rules'
$rule = Get-NetFirewallRule -DisplayName 'Observability - SQL (Grafana)' -ErrorAction SilentlyContinue
if ($rule -and $PSCmdlet.ShouldProcess('Observability - SQL (Grafana)', 'Remove firewall rule')) {
    $rule | Remove-NetFirewallRule
    Write-Ok 'Removed rule Observability - SQL (Grafana)'
}

if ($RemoveFiles) {
    Write-Step "Removing $($Layout.Root)"
    if ($PSCmdlet.ShouldProcess($Layout.Root, 'Remove directory')) {
        Remove-StackRoot -Layout $Layout
        Write-Ok 'Removed the installation folder.'
    }
} else {
    Write-Info "Files left in $($Layout.Root) (use -RemoveFiles to remove them)."
}
Write-Info 'The WEBCON configuration is not changed - restore the *.bak-* copies of appsettings / web.config if needed.'
Write-Info 'SQL logins (SQL host) are kept - to remove them (DBA): DROP LOGIN [svc_obs_mssql_exporter]; DROP LOGIN [svc_obs_grafana_reader];'
Write-Info '  (before DROP LOGIN of the reader: DROP USER [svc_obs_grafana_reader] in the WEBCON content database)'
