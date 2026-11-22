#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the observability stack services. Data, configuration and binaries are kept unless -RemoveFiles is specified.

.EXAMPLE
    .\Uninstall-ObservabilityStack.ps1
.EXAMPLE
    .\Uninstall-ObservabilityStack.ps1 -RemoveFiles   # removes the entire installation directory (including data and secrets)
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = 'C:\Observability',
    [switch]$RemoveFiles,
    # -RemoveFiles without prompting about non-stack items in the installation directory (a git repository always blocks removal)
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\modules\ObservabilityStack.psm1') -Force -DisableNameChecking
Assert-Administrator

$Layout = Get-StackLayout -Root $Root
# -RemoveFiles: check the directory contents BEFORE removing services (a refusal does not leave the stack half-removed)
if ($RemoveFiles) { Assert-SafeRemoveRoot -Layout $Layout -Force:$Force }

Write-Step 'Removing services'
foreach ($id in 'obs-grafana', 'obs-alloy', 'obs-tempo', 'obs-loki', 'obs-prometheus') {
    if ($PSCmdlet.ShouldProcess($id, 'Uninstall service')) {
        Uninstall-WinSWService -Id $id -ServicesRoot $Layout.Services
    }
}

Write-Step 'Firewall rules'
foreach ($name in 'Observability - Grafana', 'Observability - OTLP', 'Observability - Agenci') {
    $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if ($rule -and $PSCmdlet.ShouldProcess($name, 'Remove firewall rule')) {
        $rule | Remove-NetFirewallRule
        Write-Ok "Removed rule $name"
    }
}

if ($RemoveFiles) {
    Write-Step "Removing $($Layout.Root)"
    if ($PSCmdlet.ShouldProcess($Layout.Root, 'Remove directory')) {
        Remove-StackRoot -Layout $Layout
        Write-Ok 'Installation directory removed.'
    }
} else {
    Write-Info "Files left in $($Layout.Root) (use -RemoveFiles to remove them)."
}
Write-Info 'WEBCON configuration is not changed - restore the *.bak-* appsettings backups if needed.'
