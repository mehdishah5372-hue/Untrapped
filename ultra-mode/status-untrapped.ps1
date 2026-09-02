# Untrapped Ultra Mode — read-only status report.
# This script NEVER changes policy, bypasses the override, or modifies networking.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$OverridePath = Join-Path $Root 'override-until.txt'
$PacketProcess = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*packet-filter.ps1*" }
$ControlProcess = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*ultra-mode.ps1*" }

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$now = Get-Date
$start = [TimeSpan]::Parse([string]$config.start)
$end = [TimeSpan]::Parse([string]$config.end)
$time = $now.TimeOfDay
$scheduled = if ($start -eq $end) { $true } elseif ($start -lt $end) { $time -ge $start -and $time -lt $end } else { $time -ge $start -or $time -lt $end }
$overrideActive = $false
$overrideUntil = $null
if (Test-Path $OverridePath) {
    try {
        $overrideUntil = [DateTime]::Parse((Get-Content $OverridePath -Raw)).ToUniversalTime()
        $overrideActive = [DateTime]::UtcNow -lt $overrideUntil
    } catch { }
}

Write-Host '=== Untrapped Ultra Mode Status ==='
Write-Host "Time: $($now.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
Write-Host "Enabled: $([bool]$config.enabled)"
Write-Host "Schedule: $($config.start) -> $($config.end)"
Write-Host "Scheduled state: $(if($scheduled){'ACTIVE'}else{'INACTIVE'})"
Write-Host "Override: $(if($overrideActive){'ACTIVE until ' + $overrideUntil.ToString('u')}else{'INACTIVE'})"
Write-Host "Control plane process: $(if(@($ControlProcess).Count){'RUNNING'}else{'NOT RUNNING'})"
Write-Host "Packet filter process: $(if(@($PacketProcess).Count){'RUNNING'}else{'NOT RUNNING'})"
Write-Host "Scheduled domains: $(@($config.domains).Count)"
Write-Host "Always blocked: $(@($config.alwaysBlockedDomains).Count)"
Write-Host "Always allowed: $(@($config.alwaysAllowedDomains).Count)"
Write-Host 'Policy changes: NONE (read-only status command)'
