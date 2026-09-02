# Untrapped Ultra Mode — read-only self-diagnostic / health report.
# This script NEVER changes policy, bypasses the override, or modifies networking.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$OverridePath = Join-Path $Root 'override-until.txt'

function Write-Check($Name, $State, $Detail) {
    $label = switch ($State) { 'OK' { '[OK]' } 'WARN' { '[WARN]' } 'FAIL' { '[FAIL]' } default { '[INFO]' } }
    Write-Host "$label $Name — $Detail"
}

function Get-DomainIPs($Domain) {
    $ips = @()
    foreach ($type in @('A','AAAA')) {
        try {
            $ips += @(Resolve-DnsName -Name $Domain -Type $type -DnsOnly -ErrorAction Stop |
                Where-Object { $_.IPAddress } |
                ForEach-Object { $_.IPAddress })
        } catch { }
    }
    @($ips | Sort-Object -Unique)
}

Write-Host ''
Write-Host '============================================================'
Write-Host ' UNTRAPPED ULTRA MODE — SELF-DIAGNOSTIC HEALTH REPORT'
Write-Host '============================================================'
Write-Host "Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
Write-Host ''

$problems = [System.Collections.Generic.List[string]]::new()

# Files / config
$required = @('WinDivert.dll','WinDivert64.sys','config.json','packet-filter.ps1','ultra-mode.ps1')
foreach ($file in $required) {
    $path = Join-Path $Root $file
    if (Test-Path $path) { Write-Check "File: $file" 'OK' 'present' }
    else { Write-Check "File: $file" 'FAIL' 'missing'; [void]$problems.Add("Missing required file: $file") }
}

$config = $null
try {
    $config = Get-Content $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    [void][TimeSpan]::Parse([string]$config.start)
    [void][TimeSpan]::Parse([string]$config.end)
    Write-Check 'Configuration' 'OK' 'config.json is valid JSON and schedule times parse correctly'
} catch {
    Write-Check 'Configuration' 'FAIL' $_.Exception.Message
    [void]$problems.Add('Configuration could not be parsed or validated.')
}

# Schedule / override
if ($config) {
    $now = (Get-Date).TimeOfDay
    $start = [TimeSpan]::Parse([string]$config.start)
    $end = [TimeSpan]::Parse([string]$config.end)
    $scheduled = if ($start -eq $end) { $true } elseif ($start -lt $end) { $now -ge $start -and $now -lt $end } else { $now -ge $start -or $now -lt $end }
    Write-Check 'Schedule' 'OK' "$($config.start) -> $($config.end); currently $(if($scheduled){'ACTIVE'}else{'INACTIVE'})"

    $overrideActive = $false
    if (Test-Path $OverridePath) {
        try {
            $until = [DateTime]::Parse((Get-Content $OverridePath -Raw)).ToUniversalTime()
            $overrideActive = [DateTime]::UtcNow -lt $until
            Write-Check 'Override' 'INFO' "$(if($overrideActive){'ACTIVE until ' + $until.ToString('u')}else{'inactive'})"
        } catch {
            Write-Check 'Override' 'WARN' 'override-until.txt exists but could not be parsed; no policy change made'
        }
    } else { Write-Check 'Override' 'INFO' 'inactive' }
}

# Processes
$packetProcess = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
$controlProcess = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })
if ($packetProcess.Count) { Write-Check 'Packet filter process' 'OK' 'RUNNING' } else { Write-Check 'Packet filter process' 'WARN' 'NOT RUNNING'; [void]$problems.Add('packet-filter.ps1 is not running.') }
if ($controlProcess.Count) { Write-Check 'Control plane process' 'OK' 'RUNNING' } else { Write-Check 'Control plane process' 'WARN' 'NOT RUNNING'; [void]$problems.Add('ultra-mode.ps1 is not running.') }

# DNS health — distinguish a bad target from a broken general DNS path.
$targets = @('youtube.com','www.youtube.com','ytimg.com','googlevideo.com','chatgpt.com','crushon.ai','windowsmcp.io')
foreach ($domain in $targets) {
    $ips = @(Get-DomainIPs $domain)
    if ($ips.Count) { Write-Check "DNS: $domain" 'OK' "$($ips.Count) IP result(s)" }
    else { Write-Check "DNS: $domain" 'WARN' 'could not resolve'; [void]$problems.Add("DNS failed for $domain.") }
}

try {
    $generalDns = @(Get-DomainIPs 'google.com')
    if ($generalDns.Count) { Write-Check 'General DNS' 'OK' 'google.com resolves; DNS path appears functional' }
    else { Write-Check 'General DNS' 'FAIL' 'google.com did not resolve'; [void]$problems.Add('General DNS resolution is failing.') }
} catch {
    Write-Check 'General DNS' 'FAIL' 'DNS test errored'; [void]$problems.Add('General DNS test failed.')
}

# Basic HTTPS reachability. This does not change networking.
try {
    $tcp = Test-NetConnection 'www.youtube.com' -Port 443 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) { Write-Check 'TCP 443: YouTube' 'OK' "reachable at $($tcp.RemoteAddress)" }
    else { Write-Check 'TCP 443: YouTube' 'WARN' "connection failed; RemoteAddress=$($tcp.RemoteAddress)"; [void]$problems.Add('YouTube TCP 443 connection failed.') }
} catch { Write-Check 'TCP 443: YouTube' 'WARN' $_.Exception.Message }

# Hosts / proxy — informational only; never edits them.
$Hosts = 'C:\Windows\System32\drivers\etc\hosts'
if (Test-Path $Hosts) {
    $hits = @(Get-Content $Hosts -ErrorAction SilentlyContinue | Where-Object { $_ -match '(youtube|youtu\.be|ytimg|googlevideo|chatgpt|crushon)' })
    if ($hits.Count -eq 0) { Write-Check 'Hosts file' 'OK' 'no Untrapped target entries found' }
    else { Write-Check 'Hosts file' 'WARN' "$($hits.Count) relevant entry/entries found; Untrapped does not manage Hosts"; $hits | ForEach-Object { Write-Host "       $_" }; [void]$problems.Add('Relevant Hosts entries exist outside Untrapped.') }
}
Write-Host ''
Write-Host 'WinHTTP proxy:'
netsh winhttp show proxy

# Adapter / route visibility — especially useful with ProtonVPN.
$up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
Write-Check 'Network adapters' 'INFO' "$($up.Count) adapter(s) currently UP"
$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
if ($routes.Count) { Write-Check 'Default route' 'OK' "$($routes.Count) default route(s) present" } else { Write-Check 'Default route' 'FAIL' 'no IPv4 default route found'; [void]$problems.Add('No IPv4 default route was found.') }

Write-Host ''
Write-Host '============================================================'
Write-Host ' DIAGNOSIS'
Write-Host '============================================================'

if ($problems.Count -eq 0) {
    Write-Host '[HEALTHY] No obvious configuration, process, DNS, or routing fault detected.'
    Write-Host 'If blocking still behaves incorrectly, inspect the packet-filter console for WinDivertOpen errors.'
} else {
    $unique = @($problems | Sort-Object -Unique)
    foreach ($p in $unique) { Write-Host "[CAUSE] $p" }
    Write-Host ''
    Write-Host 'Interpretation:'
    if ($unique -match 'DNS') { Write-Host '  -> DNS failure: target resolution is incomplete; this is not a reason to alter Hosts or Firewall.' }
    if ($unique -match 'packet-filter') { Write-Host '  -> Packet layer is not running, so WinDivert is not currently enforcing the block.' }
    if ($unique -match 'ultra-mode') { Write-Host '  -> Scheduler/control plane is not running; scheduled state will not be monitored.' }
    if ($unique -match 'Hosts') { Write-Host '  -> Hosts contains external entries; remove/inspect those separately rather than letting Untrapped manage them.' }
    if ($unique -match 'route') { Write-Host '  -> Routing is unhealthy; check the active network/VPN connection rather than changing Untrapped.' }
    Write-Host ''
    Write-Host 'NO POLICY CHANGES WERE MADE.'
}

Write-Host ''
Write-Host '============================================================'
Write-Host ' END SELF-DIAGNOSTIC — READ ONLY'
Write-Host '============================================================'
