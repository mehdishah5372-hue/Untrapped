# Untrapped Ultra Mode — scheduled control-plane enforcement
# WinDivert packet-level blocking is handled by packet-filter.ps1.
# This script manages the Hosts file + Brave policy and keeps them synchronized
# with the same schedule. alwaysBlockedDomains remain blocked 24/7.
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
$RefreshSeconds = 30

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw 'Missing config.json' }
    Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Normalize-Domains($items) {
    @($items | Where-Object {
        $_ -and $_ -notmatch '[\s#]'
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

function Remove-HostBlock($lines) {
    $out = [Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in @($lines)) {
        if ($line.Trim() -eq $StartMarker) { $inside = $true; continue }
        if ($line.Trim() -eq $EndMarker) { $inside = $false; continue }
        if (-not $inside) { [void]$out.Add($line) }
    }
    $out.ToArray()
}

function Apply-Hosts($domains) {
    $lines = if (Test-Path $HostsPath) { @(Get-Content $HostsPath) } else { @() }
    $clean = @(Remove-HostBlock $lines)
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
        $clean = @(Remove-HostBlock @(Get-Content $HostsPath))
        Set-Content $HostsPath -Value $clean -Encoding ascii
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

function Apply-State($config) {
    $scheduledActive = Test-ScheduleActive $config
    $scheduledDomains = Normalize-Domains $config.domains
    $alwaysDomains = Normalize-Domains $config.alwaysBlockedDomains

    $domainsToBlock = @($alwaysDomains)
    if ($scheduledActive) { $domainsToBlock += $scheduledDomains }
    $domainsToBlock = @($domainsToBlock | Sort-Object -Unique)

    if (-not [bool]$config.enabled) {
        Remove-Hosts
        Remove-BravePolicy
        Remove-ObsoleteFirewallRules
        return 'INACTIVE'
    }

    Apply-Hosts $domainsToBlock
    Set-BravePolicy $domainsToBlock
    Remove-ObsoleteFirewallRules

    if ($scheduledActive) { return 'SCHEDULED ACTIVE' }
    return 'ALWAYS-BLOCK-ONLY'
}

$lastState = $null

while ($true) {
    try {
        $config = Get-Config
        $state = Apply-State $config
        if ($state -ne $lastState) {
            Write-Host "Ultra Mode control plane: $state"
            $lastState = $state
        }
    }
    catch {
        Write-Host "Ultra Mode control plane error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $RefreshSeconds
}
