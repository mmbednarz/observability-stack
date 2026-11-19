#Requires -Version 5.1
<#
.SYNOPSIS
    Usuwa agenta Alloy z hosta WEBCON / SQL. Pliki zostają, chyba że podano -RemoveFiles.

.DESCRIPTION
    Nie zmienia konfiguracji WEBCON (przywróć kopie *.bak-* appsettings / web.config) ani loginów SQL
    (polecenia DROP LOGIN są wypisywane na końcu).

.EXAMPLE
    .\Uninstall-ObservabilityAgent.ps1 -RemoveFiles
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = 'C:\Observability',
    [switch]$RemoveFiles,
    # -RemoveFiles bez pytania o elementy spoza stosu w katalogu instalacji (repozytorium git zawsze blokuje usunięcie)
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\modules\ObservabilityStack.psm1') -Force -DisableNameChecking
Assert-Administrator

$Layout = Get-StackLayout -Root $Root
# -RemoveFiles: kontrola zawartości katalogu PRZED usunięciem usług (odmowa nie zostawia stosu w połowie)
if ($RemoveFiles) { Assert-SafeRemoveRoot -Layout $Layout -Force:$Force }
if (Get-Service -Name 'obs-prometheus' -ErrorAction SilentlyContinue) {
    throw 'Na tym hoście jest stos centralny - użyj Uninstall-ObservabilityStack.ps1.'
}

Write-Step 'Usuwanie usługi'
if ($PSCmdlet.ShouldProcess('obs-alloy', 'Uninstall service')) {
    Uninstall-WinSWService -Id 'obs-alloy' -ServicesRoot $Layout.Services
}

Write-Step 'Reguły firewall'
$rule = Get-NetFirewallRule -DisplayName 'Observability - SQL (Grafana)' -ErrorAction SilentlyContinue
if ($rule -and $PSCmdlet.ShouldProcess('Observability - SQL (Grafana)', 'Remove firewall rule')) {
    $rule | Remove-NetFirewallRule
    Write-Ok 'Usunięto regułę Observability - SQL (Grafana)'
}

if ($RemoveFiles) {
    Write-Step "Usuwanie $($Layout.Root)"
    if ($PSCmdlet.ShouldProcess($Layout.Root, 'Remove directory')) {
        Remove-StackRoot -Layout $Layout
        Write-Ok 'Usunięto katalog instalacji.'
    }
} else {
    Write-Info "Pliki pozostawione w $($Layout.Root) (użyj -RemoveFiles, aby usunąć)."
}
Write-Info 'Konfiguracja WEBCON nie jest zmieniana - przywróć kopie *.bak-* appsettings / web.config, jeśli potrzeba.'
Write-Info 'Loginy SQL (host SQL) pozostają - usunięcie (DBA): DROP LOGIN [svc_obs_mssql_exporter]; DROP LOGIN [svc_obs_grafana_reader];'
Write-Info '  (przed DROP LOGIN czytelnika: DROP USER [svc_obs_grafana_reader] w bazie treści WEBCON)'
