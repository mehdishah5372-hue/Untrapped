# Untrapped Ultra Mode — WinDivert packet-level destination blocker
# Uses WinDivert's kernel packet filter with DROP.
# Scheduled domains are blocked during the configured schedule; alwaysBlockedDomains
# are blocked 24/7. alwaysAllowedDomains are resolved and removed from the DROP IP set.
# This script intentionally does not modify Hosts, Brave, Firewall, WFP, Winsock,
# DNS, or VPN configuration. A signed override is the only policy bypass.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$RefreshSeconds = 30
$Priority = 1000
$LayerNetwork = 0
$FlagDrop = 0x0002
$InvalidHandle = [IntPtr](-1)

foreach ($required in @('WinDivert.dll','WinDivert64.sys','config.json')) {
    if (-not (Test-Path (Join-Path $Root $required))) { throw "$required not found in $Root." }
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator privileges are required. No filter was opened.'
}
Set-Location $Root

if (-not ('UntrappedWinDivert.Native' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace UntrappedWinDivert {
 public static class Native {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetDllDirectory(string lpPathName);
  [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr WinDivertOpen(string filter, int layer, short priority, ulong flags);
  [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl, SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool WinDivertClose(IntPtr handle);
 }
}
"@
}
[UntrappedWinDivert.Native]::SetDllDirectory($Root) | Out-Null

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Missing config.json at $ConfigPath" }
    Get-Content $ConfigPath -Raw | ConvertFrom-Json
}
function Normalize-Domains($domains) {
    @($domains | Where-Object { $_ -and $_.ToString() -notmatch '[\s#]' } | ForEach-Object { $_.ToString().ToLowerInvariant().TrimEnd('.') })
}
function Test-Config($config) {
    foreach ($name in @('enabled','start','end','domains','alwaysBlockedDomains','alwaysAllowedDomains')) { if ($null -eq $config.$name) { throw "Missing config property: $name" } }
    [void][TimeSpan]::Parse([string]$config.start); [void][TimeSpan]::Parse([string]$config.end)
    $all = @(Normalize-Domains (@($config.domains)+@($config.alwaysBlockedDomains)+@($config.alwaysAllowedDomains)))
    if ($all.Count -eq 0) { throw 'Configuration contains no domains.' }
    foreach ($d in $all) { $base = if ($d.StartsWith('*.')) {$d.Substring(2)} else {$d}; if ($base -notmatch '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$') { throw "Invalid domain entry: $d" } }
}
function Test-UltraActive($config) {
    if (-not [bool]$config.enabled) { return $false }
    $start=[TimeSpan]::Parse([string]$config.start); $end=[TimeSpan]::Parse([string]$config.end); $now=(Get-Date).TimeOfDay
    if ($start -eq $end) { return $true }; if ($start -lt $end) { return ($now -ge $start -and $now -lt $end) }; return ($now -ge $start -or $now -lt $end)
}
function Test-OverrideActive {
    $path=Join-Path $Root 'override-until.txt'
    if (-not (Test-Path $path)) { return $false }
    try { return ([DateTime]::UtcNow -lt ([DateTime]::Parse((Get-Content $path -Raw)).ToUniversalTime())) } catch { return $false }
}
function Get-DomainIPs($domains) {
    $set=[System.Collections.Generic.HashSet[string]]::new()
    foreach ($domain in @(Normalize-Domains $domains | Where-Object { $_ -notmatch '^\*\.' })) {
        $resolved=$false
        foreach ($type in @('A','AAAA')) {
            try { Resolve-DnsName -Name $domain -Type $type -DnsOnly -ErrorAction Stop | ForEach-Object { if ($_.IPAddress) { [void]$set.Add($_.IPAddress); $resolved=$true } } } catch { }
        }
        if (-not $resolved) { Write-Host "Warning: could not resolve $domain" }
    }
    @($set)
}
function New-WinDivertFilter($ips) {
    $clauses=foreach ($ip in $ips) { try { $parsed=[System.Net.IPAddress]::Parse($ip); if($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork){"ip.DstAddr == $ip"}else{"ipv6.DstAddr == $ip"} } catch { } }
    if (-not $clauses -or @($clauses).Count -eq 0) { return $null }
    "outbound and !loopback and (tcp.DstPort == 443 or udp.DstPort == 443) and (" + (($clauses | ForEach-Object { "($_)" }) -join ' or ') + ")"
}

$handle=$InvalidHandle; $lastFilter=$null
try {
    Write-Host 'Untrapped Ultra Mode WinDivert filter starting.'
    while ($true) {
        $config=Get-Config; Test-Config $config
        $override=Test-OverrideActive
        $active=Test-UltraActive $config
        $scheduled=if($active -and -not $override){@(Normalize-Domains $config.domains)}else{@()}
        $always=@(Normalize-Domains $config.alwaysBlockedDomains)
        $allowed=@(Normalize-Domains $config.alwaysAllowedDomains)
        $blockedIps=@(Get-DomainIPs (@($scheduled)+@($always)))
        $allowedIps=@(Get-DomainIPs $allowed)
        $allowedSet=[System.Collections.Generic.HashSet[string]]::new([string[]]$allowedIps)
        $ips=@($blockedIps | Where-Object { -not $allowedSet.Contains([string]$_) })
        $filter=New-WinDivertFilter $ips

        if (-not $filter) {
            if ($handle -ne $InvalidHandle) { [UntrappedWinDivert.Native]::WinDivertClose($handle)|Out-Null; $handle=$InvalidHandle; $lastFilter=$null; Write-Host 'WinDivert block INACTIVE.' }
            if($active -and -not $override -and $blockedIps.Count -eq 0 -and $always.Count -gt 0){ Write-Host 'No block filter opened: all configured block targets failed DNS resolution.' }
            Start-Sleep -Seconds $RefreshSeconds; continue
        }
        if ($filter -ne $lastFilter) {
            if($handle -ne $InvalidHandle){[UntrappedWinDivert.Native]::WinDivertClose($handle)|Out-Null;$handle=$InvalidHandle}
            Write-Host "Opening WinDivert DROP filter for $($ips.Count) destination IPs ($($allowedIps.Count) allowed IPs exempted)."
            $handle=[UntrappedWinDivert.Native]::WinDivertOpen($filter,$LayerNetwork,$Priority,[UInt64]$FlagDrop)
            if($handle -eq $InvalidHandle -or $handle -eq [IntPtr]::Zero){$errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "WinDivertOpen failed with Windows error $errorCode."}
            $lastFilter=$filter
            Write-Host "WinDivert packet block ACTIVE. Policy state: $(if($override){'OVERRIDE'}elseif($active){'SCHEDULED ACTIVE'}else{'ALWAYS-BLOCK-ONLY'})."
        }
        Start-Sleep -Seconds $RefreshSeconds
    }
} finally { if($handle -ne $InvalidHandle -and $handle -ne [IntPtr]::Zero){[UntrappedWinDivert.Native]::WinDivertClose($handle)|Out-Null} }
