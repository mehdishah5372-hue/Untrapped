# Untrapped Ultra Mode — WinDivert packet-level destination blocker
# Uses WinDivert's kernel packet filter with DROP, so blocked HTTPS traffic is
# discarded before it can be carried through a user-space VPN tunnel.
# Run from an elevated PowerShell session or as the SYSTEM scheduled task.
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$DllPath = Join-Path $Root 'WinDivert.dll'
$RefreshSeconds = 30
$Priority = 1000
$LayerNetwork = 0
$FlagDrop = 0x0002
$InvalidHandle = [IntPtr](-1)

if (-not (Test-Path $DllPath)) {
    throw "WinDivert.dll not found at $DllPath. Run INSTALL-PACKET-FILTER.ps1 first."
}
if (-not (Test-Path (Join-Path $Root 'WinDivert64.sys'))) {
    throw "WinDivert64.sys not found in $Root. Run INSTALL-PACKET-FILTER.ps1 first."
}

Set-Location $Root

if (-not ('UntrappedWinDivert.Native' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace UntrappedWinDivert {
    public static class Native {
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool SetDllDirectory(string lpPathName);

        [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl,
            CharSet=CharSet.Ansi, SetLastError=true)]
        public static extern IntPtr WinDivertOpen(
            string filter, int layer, short priority, ulong flags);

        [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl,
            SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WinDivertClose(IntPtr handle);
    }
}
"@
}

[UntrappedWinDivert.Native]::SetDllDirectory($Root) | Out-Null

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Missing config.json at $ConfigPath" }
    Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Get-DomainIPs($domains) {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    $domains = @($domains | Where-Object {
        $_ -and $_.ToString() -notmatch '[\s#]' -and $_.ToString() -notmatch '^\*\.'
    })

    foreach ($domain in $domains) {
        foreach ($type in @('A','AAAA')) {
            try {
                Resolve-DnsName -Name $domain -Type $type -DnsOnly -ErrorAction Stop |
                    ForEach-Object {
                        if ($_.IPAddress) { [void]$set.Add($_.IPAddress) }
                    }
            } catch { }
        }
    }
    @($set)
}

function Test-UltraActive($config) {
    if (-not [bool]$config.enabled) { return $false }
    $start = [TimeSpan]::Parse($config.start)
    $end = [TimeSpan]::Parse($config.end)
    $now = (Get-Date).TimeOfDay
    if ($start -eq $end) { return $true }
    if ($start -lt $end) { return ($now -ge $start -and $now -lt $end) }
    ($now -ge $start -or $now -lt $end)
}

function New-WinDivertFilter($ips) {
    $clauses = foreach ($ip in $ips) {
        try {
            $parsed = [System.Net.IPAddress]::Parse($ip)
            if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                "ip.DstAddr == $ip"
            } else {
                "ipv6.DstAddr == $ip"
            }
        } catch { }
    }

    if (-not $clauses -or @($clauses).Count -eq 0) { return $null }

    # HTTPS is the transport we need to stop. This covers TCP/TLS and UDP/QUIC
    # while leaving unrelated traffic to the same IP alone.
    "outbound and !loopback and (tcp.DstPort == 443 or udp.DstPort == 443) and (" +
        (($clauses | ForEach-Object { "($_)" }) -join ' or ') + ")"
}

$handle = $InvalidHandle
$lastFilter = $null

try {
    Write-Host 'Untrapped Ultra Mode WinDivert service starting.'
    while ($true) {
        $config = Get-Config
        $active = Test-UltraActive $config

        # Normal domains follow the configured schedule. Domains in
        # alwaysBlockedDomains are blocked regardless of the current time.
        $scheduledDomains = if ($active) { @($config.domains) } else { @() }
        $alwaysBlockedDomains = @($config.alwaysBlockedDomains)
        $domainsToBlock = @($scheduledDomains + $alwaysBlockedDomains)
        $ips = @(Get-DomainIPs $domainsToBlock)
        $filter = New-WinDivertFilter $ips

        if (-not $filter) {
            if ($handle -ne $InvalidHandle) {
                [UntrappedWinDivert.Native]::WinDivertClose($handle) | Out-Null
                $handle = $InvalidHandle
                $lastFilter = $null
                Write-Host 'WinDivert block INACTIVE.'
            }
            Start-Sleep -Seconds $RefreshSeconds
            continue
        }

        if ($filter -ne $lastFilter) {
            if ($handle -ne $InvalidHandle) {
                [UntrappedWinDivert.Native]::WinDivertClose($handle) | Out-Null
                $handle = $InvalidHandle
            }

            Write-Host "Opening WinDivert DROP filter for $($ips.Count) destination IPs."
            $handle = [UntrappedWinDivert.Native]::WinDivertOpen($filter, $LayerNetwork, $Priority, [UInt64]$FlagDrop)
            if ($handle -eq $InvalidHandle -or $handle -eq [IntPtr]::Zero) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "WinDivertOpen failed with Windows error $errorCode."
            }

            $lastFilter = $filter
            if ($alwaysBlockedDomains.Count -gt 0) {
                Write-Host 'WinDivert packet block ACTIVE (scheduled domains + always-blocked domains).'
            } else {
                Write-Host 'WinDivert packet block ACTIVE.'
            }
        }

        Start-Sleep -Seconds $RefreshSeconds
    }
}
finally {
    if ($handle -ne $InvalidHandle -and $handle -ne [IntPtr]::Zero) {
        [UntrappedWinDivert.Native]::WinDivertClose($handle) | Out-Null
    }
}
