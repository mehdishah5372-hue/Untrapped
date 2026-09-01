# Untrapped Ultra Mode — control-plane enforcement
# Packet-level destination blocking is handled by packet-filter.ps1 + WinDivert.
# This script manages hosts/Brave policy and removes the obsolete firewall layers.
# Requires an elevated PowerShell session.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$PolicyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$StartMarker = '# >>> UNTRAPPED ULTRA MODE >>>'
$EndMarker = '# <<< UNTRAPPED ULTRA MODE <<<'
$FqdnPrefix = 'Untrapped Ultra Mode FQDN - '
$IpPrefix = 'Untrapped Ultra Mode IP - '

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw 'Missing config.json' }
    Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Get-Domains($c) {
    @($c.domains | Where-Object {
        $_ -and $_ -notmatch '[\s#]'
    } | ForEach-Object {
        $_.ToString().ToLowerInvariant().TrimEnd('.')
    })
}

function Remove-HostBlock($lines) {
    $out = [Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in $lines) {
        if ($line.Trim() -eq $StartMarker) { $inside = $true; continue }
        if ($line.Trim() -eq $EndMarker) { $inside = $false; continue }
        if (-not $inside) { [void]$out.Add($line) }
    }
    $out.ToArray()
}

function Apply-Hosts($domains) {
    $lines = if (Test-Path $HostsPath) { Get-Content $HostsPath } else { @() }
    $clean = Remove-HostBlock $lines
    $block = [Collections.Generic.List[string]]::new()
    [void]$block.Add($StartMarker)
    [void]$block.Add('# Managed by Untrapped Ultra Mode.')
    foreach ($d in $domains | Where-Object { $_ -notmatch '^\*\.' }) {
        [void]$block.Add("0.0.0.0`t$d")
        [void]$block.Add("::1`t$d")
    }
    [void]$block.Add($EndMarker)
    Set-Content $HostsPath -Value @($clean + '' + $block.ToArray()) -Encoding ascii
    ipconfig /flushdns | Out-Null
}

function Remove-Hosts {
    if (Test-Path $HostsPath) {
        Set-Content $HostsPath -Value (Remove-HostBlock (Get-Content $HostsPath)) -Encoding ascii
        ipconfig /flushdns | Out-Null
    }
}

function Set-BravePolicy($domains) {
    New-Item $PolicyPath -Force | Out-Null
    $k = Join-Path $PolicyPath 'URLBlocklist'
    New-Item $k -Force | Out-Null
    $i = 1
    foreach ($d in $domains) {
        $base = if ($d.StartsWith('*.')) { $d.Substring(2) } else { $d }
        New-ItemProperty $k -Name ([string]$i) -PropertyType String -Value "[*.]$base" -Force | Out-Null
        $i++
    }
    New-ItemProperty $PolicyPath -Name DnsOverHttpsMode -PropertyType String -Value 'off' -Force | Out-Null
    New-ItemProperty $PolicyPath -Name QuicAllowed -PropertyType DWord -Value 0 -Force | Out-Null
}

function Remove-BravePolicy {
    $k = Join-Path $PolicyPath 'URLBlocklist'
    if (Test-Path $k) { Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $PolicyPath) {
        Remove-ItemProperty $PolicyPath -Name DnsOverHttpsMode -ErrorAction SilentlyContinue
        Remove-ItemProperty $PolicyPath -Name QuicAllowed -ErrorAction SilentlyContinue
    }
}

function Remove-ObsoleteFirewallRules {
    Get-NetFirewallRule -DisplayName "$FqdnPrefix*" -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName "$IpPrefix*" -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

$config = Get-Config
$domains = Get-Domains $config

if (-not [bool]$config.enabled) {
    Remove-ObsoleteFirewallRules
    Remove-Hosts
    Remove-BravePolicy
    Write-Host 'Ultra Mode INACTIVE.'
    exit 0
}

# WinDivert is the enforcement layer. Keep the hosts and Brave layers as
# additional protection, and deliberately avoid unsupported dynamic-FQDN APIs.
Apply-Hosts $domains
Set-BravePolicy $domains
Remove-ObsoleteFirewallRules
Write-Host 'Ultra Mode control plane ACTIVE: hosts + Brave policy + WinDivert packet filter.'
