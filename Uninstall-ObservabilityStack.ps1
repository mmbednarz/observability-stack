#Requires -Version 5.1
<#
.SYNOPSIS
    Usuwa usługi stosu obserwowalności. Dane, konfiguracja i binarki zostają, chyba że podano -RemoveFiles.

.EXAMPLE
    .\Uninstall-ObservabilityStack.ps1
.EXAMPLE
    .\Uninstall-ObservabilityStack.ps1 -RemoveFiles   # usuwa cały katalog instalacji (także dane i sekrety)
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

Write-Step 'Usuwanie usług'
foreach ($id in 'obs-grafana', 'obs-alloy', 'obs-tempo', 'obs-loki', 'obs-prometheus') {
    if ($PSCmdlet.ShouldProcess($id, 'Uninstall service')) {
        Uninstall-WinSWService -Id $id -ServicesRoot $Layout.Services
    }
}

Write-Step 'Reguły firewall'
foreach ($name in 'Observability - Grafana', 'Observability - OTLP', 'Observability - Agenci') {
    $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if ($rule -and $PSCmdlet.ShouldProcess($name, 'Remove firewall rule')) {
        $rule | Remove-NetFirewallRule
        Write-Ok "Usunięto regułę $name"
    }
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
Write-Info 'Konfiguracja WEBCON nie jest zmieniana - przywróć kopie *.bak-* appsettings, jeśli potrzeba.'
