# Untrapped Ultra Mode — read-only self-diagnostic / health report.
# Console output is also saved to diagnostic-latest.txt and opened in Notepad.
# This script NEVER changes policy, bypasses the override, or modifies networking.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$OverridePath = Join-Path $Root 'override-until.txt'
$ReportPath = Join-Path $Root 'diagnostic-latest.txt'

$lines = [System.Collections.Generic.List[string]]::new()
function Write-Report($Text='') { $lines.Add([string]$Text); Write-Host $Text }
function Write-Check($Name, $State, $Detail) {
    $label = switch ($State) { 'OK' { '[OK]' } 'WARN' { '[WARN]' } 'FAIL' { '[FAIL]' } default { '[INFO]' } }
    Write-Report "$label $Name — $Detail"
}
function Get-DomainIPs($Domain) {
    $ips = @()
    foreach ($type in @('A','AAAA')) {
        try {
            $ips += @(Resolve-DnsName -Name $Domain -Type $type -DnsOnly -ErrorAction Stop |
                Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        } catch { }
    }
    @($ips | Sort-Object -Unique)
}

Write-Report ''
Write-Report '============================================================'
Write-Report ' UNTRAPPED ULTRA MODE — SELF-DIAGNOSTIC HEALTH REPORT'
Write-Report '============================================================'
Write-Report "Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
Write-Report ''
$problems = [System.Collections.Generic.List[string]]::new()

$required = @('WinDivert.dll','WinDivert64.sys','config.json','packet-filter.ps1','ultra-mode.ps1')
foreach ($file in $required) {
    if (Test-Path (Join-Path $Root $file)) { Write-Check "File: $file" 'OK' 'present' }
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

if ($config) {
    $now = (Get-Date).TimeOfDay
    $start = [TimeSpan]::Parse([string]$config.start)
    $end = [TimeSpan]::Parse([string]$config.end)
    $scheduled = if ($start -eq $end) { $true } elseif ($start -lt $end) { $now -ge $start -and $now -lt $end } else { $now -ge $start -or $now -lt $end }
    Write-Check 'Schedule' 'OK' "$($config.start) -> $($config.end); currently $(if($scheduled){'ACTIVE'}else{'INACTIVE'})"

    if (Test-Path $OverridePath) {
        try {
            $until = [DateTime]::Parse((Get-Content $OverridePath -Raw)).ToUniversalTime()
            Write-Check 'Override' 'INFO' "$(if([DateTime]::UtcNow -lt $until){'ACTIVE until ' + $until.ToString('u')}else{'inactive'})"
        } catch { Write-Check 'Override' 'WARN' 'override-until.txt exists but could not be parsed; no policy change made' }
    } else { Write-Check 'Override' 'INFO' 'inactive' }
}

$packetProcess = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
$controlProcess = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })
if ($packetProcess.Count) { Write-Check 'Packet filter process' 'OK' 'RUNNING' } else { Write-Check 'Packet filter process' 'WARN' 'NOT RUNNING'; [void]$problems.Add('packet-filter.ps1 is not running.') }
if ($controlProcess.Count) { Write-Check 'Control plane process' 'OK' 'RUNNING' } else { Write-Check 'Control plane process' 'WARN' 'NOT RUNNING'; [void]$problems.Add('ultra-mode.ps1 is not running.') }

foreach ($domain in @('youtube.com','www.youtube.com','ytimg.com','googlevideo.com','chatgpt.com','crushon.ai','windowsmcp.io')) {
    $ips = @(Get-DomainIPs $domain)
    if ($ips.Count) { Write-Check "DNS: $domain" 'OK' "$($ips.Count) IP result(s)" }
    else { Write-Check "DNS: $domain" 'WARN' 'could not resolve'; [void]$problems.Add("DNS failed for $domain.") }
}
$generalDns = @(Get-DomainIPs 'google.com')
if ($generalDns.Count) { Write-Check 'General DNS' 'OK' 'google.com resolves; DNS path appears functional' }
else { Write-Check 'General DNS' 'FAIL' 'google.com did not resolve'; [void]$problems.Add('General DNS resolution is failing.') }

try {
    $tcp = Test-NetConnection 'www.youtube.com' -Port 443 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) { Write-Check 'TCP 443: YouTube' 'OK' "reachable at $($tcp.RemoteAddress)" }
    else { Write-Check 'TCP 443: YouTube' 'WARN' "connection failed; RemoteAddress=$($tcp.RemoteAddress)"; [void]$problems.Add('YouTube TCP 443 connection failed.') }
} catch { Write-Check 'TCP 443: YouTube' 'WARN' $_.Exception.Message }

$Hosts = 'C:\Windows\System32\drivers\etc\hosts'
if (Test-Path $Hosts) {
    $hits = @(Get-Content $Hosts -ErrorAction SilentlyContinue | Where-Object { $_ -match '(youtube|youtu\.be|ytimg|googlevideo|chatgpt|crushon)' })
    if ($hits.Count -eq 0) { Write-Check 'Hosts file' 'OK' 'no Untrapped target entries found' }
    else { Write-Check 'Hosts file' 'WARN' "$($hits.Count) relevant entry/entries found; Untrapped does not manage Hosts"; $hits | ForEach-Object { Write-Report "       $_" }; [void]$problems.Add('Relevant Hosts entries exist outside Untrapped.') }
}

Write-Report ''
Write-Report 'WinHTTP proxy:'
$proxyOutput = @(netsh winhttp show proxy 2>&1)
foreach ($line in $proxyOutput) { Write-Report "  $line" }

$up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
Write-Check 'Network adapters' 'INFO' "$($up.Count) adapter(s) currently UP"
$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
if ($routes.Count) { Write-Check 'Default route' 'OK' "$($routes.Count) default route(s) present" } else { Write-Check 'Default route' 'FAIL' 'no IPv4 default route found'; [void]$problems.Add('No IPv4 default route was found.') }

Write-Report ''
Write-Report '============================================================'
Write-Report ' DIAGNOSIS'
Write-Report '============================================================'
if ($problems.Count -eq 0) {
    Write-Report '[HEALTHY] No obvious configuration, process, DNS, or routing fault detected.'
    Write-Report 'If blocking still behaves incorrectly, inspect the packet-filter console for WinDivertOpen errors.'
} else {
    $unique = @($problems | Sort-Object -Unique)
    foreach ($p in $unique) { Write-Report "[CAUSE] $p" }
    Write-Report ''
    Write-Report 'Interpretation:'
    if ($unique -match 'DNS') { Write-Report '  -> DNS failure: target resolution is incomplete; do not alter Hosts or Firewall.' }
    if ($unique -match 'packet-filter') { Write-Report '  -> Packet layer is not running, so WinDivert is not enforcing the block.' }
    if ($unique -match 'ultra-mode') { Write-Report '  -> Scheduler/control plane is not running; scheduled state will not be monitored.' }
    if ($unique -match 'Hosts') { Write-Report '  -> Hosts contains external entries; inspect those separately.' }
    if ($unique -match 'route') { Write-Report '  -> Routing is unhealthy; check the active network/VPN connection.' }
    Write-Report ''
    Write-Report 'NO POLICY CHANGES WERE MADE.'
}

Write-Report ''
Write-Report '============================================================'
Write-Report ' END SELF-DIAGNOSTIC — READ ONLY'
Write-Report '============================================================'

try {
    $lines | Set-Content -Path $ReportPath -Encoding UTF8
    Start-Process notepad.exe -ArgumentList "`"$ReportPath`""
    Write-Host ''
    Write-Host "[OK] Diagnostic report saved and opened in Notepad: $ReportPath"
} catch {
    Write-Host "[WARN] Could not open diagnostic report in Notepad: $($_.Exception.Message)"
}
