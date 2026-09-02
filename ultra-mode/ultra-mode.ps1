# Untrapped Ultra Mode — scheduled control-plane enforcement
# Network blocking is handled only by packet-filter.ps1/WinDivert.
# This control plane intentionally does NOT modify the Hosts file, Brave policy,
# Windows Firewall, WFP, Winsock, DNS, or VPN configuration.
# A valid signed override remains the only supported policy bypass.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$RefreshSeconds = 30

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw 'Missing config.json' }
    Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Normalize-Domains($items) {
    @($items | Where-Object {
        $_ -and $_.ToString() -notmatch '[\s#]'
    } | ForEach-Object {
        $_.ToString().ToLowerInvariant().TrimEnd('.')
    })
}

function Test-ScheduleActive($config) {
    if (-not [bool]$config.enabled) { return $false }
    $start = [TimeSpan]::Parse([string]$config.start)
    $end = [TimeSpan]::Parse([string]$config.end)
    $now = (Get-Date).TimeOfDay
    if ($start -eq $end) { return $true }
    if ($start -lt $end) { return ($now -ge $start -and $now -lt $end) }
    return ($now -ge $start -or $now -lt $end)
}

function Test-Config($config) {
    foreach ($name in @('enabled','start','end','domains','alwaysBlockedDomains','alwaysAllowedDomains')) {
        if ($null -eq $config.$name) { throw "Missing config property: $name" }
    }
    [void][TimeSpan]::Parse([string]$config.start)
    [void][TimeSpan]::Parse([string]$config.end)
    $all = @(Normalize-Domains (@($config.domains) + @($config.alwaysBlockedDomains) + @($config.alwaysAllowedDomains)))
    if ($all.Count -eq 0) { throw 'Configuration contains no domains.' }
    foreach ($d in $all) {
        if ($d -notmatch '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$') { throw "Invalid domain entry: $d" }
    }
}

$lastState = $null
while ($true) {
    try {
        $config = Get-Config
        Test-Config $config
        $scheduledActive = Test-ScheduleActive $config
        $overridePath = Join-Path $Root 'override-until.txt'
        $overrideActive = $false
        if (Test-Path $overridePath) {
            try { $overrideActive = [DateTime]::UtcNow -lt ([DateTime]::Parse((Get-Content $overridePath -Raw)).ToUniversalTime()) } catch { $overrideActive = $false }
        }
        $state = if (-not [bool]$config.enabled) { 'DISABLED' } elseif ($overrideActive) { 'OVERRIDE ACTIVE' } elseif ($scheduledActive) { 'SCHEDULED ACTIVE' } else { 'ALWAYS-BLOCK-ONLY' }
        if ($state -ne $lastState) {
            Write-Host "Ultra Mode control plane: $state"
            Write-Host "Scheduled domains: $(@($config.domains).Count); always blocked: $(@($config.alwaysBlockedDomains).Count); always allowed: $(@($config.alwaysAllowedDomains).Count)"
            $lastState = $state
        }
    } catch {
        Write-Host "Ultra Mode control plane error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $RefreshSeconds
}
