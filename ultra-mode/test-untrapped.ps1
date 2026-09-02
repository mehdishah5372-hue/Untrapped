# Untrapped Ultra Mode — read-only preflight/dry-run report.
# This script never opens WinDivert and never changes networking or policy.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$required = @('config.json','packet-filter.ps1','ultra-mode.ps1','WinDivert.dll','WinDivert64.sys')
Write-Host '=== Untrapped Ultra Mode Preflight ==='
foreach ($name in $required) {
    $ok = Test-Path (Join-Path $Root $name)
    Write-Host "$name : $(if($ok){'OK'}else{'MISSING'})"
    if (-not $ok) { throw "Required file missing: $name" }
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($null -eq $config.enabled) { throw 'Missing enabled' }
foreach ($field in @('start','end')) { [void][TimeSpan]::Parse([string]$config.$field) }
foreach ($group in @('domains','alwaysBlockedDomains','alwaysAllowedDomains')) {
    if ($null -eq $config.$group) { throw "Missing $group" }
    foreach ($d in @($config.$group)) {
        if ($d -and $d.ToString() -notmatch '^[*a-z0-9](?:[a-z0-9.*-]*[a-z0-9])?$') { throw "Invalid domain: $d" }
    }
}
Write-Host "Schedule: $($config.start) -> $($config.end)"
Write-Host "Scheduled domains: $(@($config.domains).Count)"
Write-Host "Always blocked: $(@($config.alwaysBlockedDomains).Count)"
Write-Host "Always allowed: $(@($config.alwaysAllowedDomains).Count)"
Write-Host 'Dry run complete. NO packets were intercepted or dropped.'
Write-Host 'NO Hosts, Brave, Firewall, WFP, Winsock, DNS, or VPN settings were changed.'
