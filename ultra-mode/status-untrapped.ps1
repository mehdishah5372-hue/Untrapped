# Untrapped Ultra Mode - read-only health report
# Saves the report to diagnostic-latest.txt and opens it in Notepad.
# This script never changes policy or networking.

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$OverridePath = Join-Path $Root 'override-until.txt'
$ReportPath = Join-Path $Root 'diagnostic-latest.txt'

$lines = New-Object System.Collections.Generic.List[string]
$problems = New-Object System.Collections.Generic.List[string]

function Report([string]$Text) {
    [void]$lines.Add($Text)
    Write-Host $Text
}

function Check([string]$Name, [string]$State, [string]$Detail) {
    $label = '[INFO]'
    if ($State -eq 'OK') { $label = '[OK]' }
    elseif ($State -eq 'WARN') { $label = '[WARN]' }
    elseif ($State -eq 'FAIL') { $label = '[FAIL]' }
    Report ($label + ' ' + $Name + ' - ' + $Detail)
}

function Resolve-TestDomain([string]$Domain) {
    try {
        $result = @(Resolve-DnsName -Name $Domain -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
        if ($result.Count -gt 0) { return $true }
    } catch {}
    try {
        $result = @(Resolve-DnsName -Name $Domain -Type AAAA -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
        if ($result.Count -gt 0) { return $true }
    } catch {}
    return $false
}

Report ''
Report '============================================================'
Report ' UNTRAPPED ULTRA MODE - SELF-DIAGNOSTIC HEALTH REPORT'
Report '============================================================'
Report ('Time: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Report ''

foreach ($file in @('WinDivert.dll','WinDivert64.sys','config.json','packet-filter.ps1','ultra-mode.ps1')) {
    if (Test-Path (Join-Path $Root $file)) {
        Check ('File: ' + $file) 'OK' 'present'
    } else {
        Check ('File: ' + $file) 'FAIL' 'missing'
        [void]$problems.Add('Missing required file: ' + $file)
    }
}

$config = $null
try {
    $config = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    [void][TimeSpan]::Parse([string]$config.start)
    [void][TimeSpan]::Parse([string]$config.end)
    Check 'Configuration' 'OK' 'config.json is valid and schedule times parse correctly'
} catch {
    Check 'Configuration' 'FAIL' $_.Exception.Message
    [void]$problems.Add('Configuration could not be parsed or validated.')
}

if ($null -ne $config) {
    $now = (Get-Date).TimeOfDay
    $start = [TimeSpan]::Parse([string]$config.start)
    $end = [TimeSpan]::Parse([string]$config.end)
    $scheduled = $false
    if ($start -eq $end) { $scheduled = $true }
    elseif ($start -lt $end) { $scheduled = ($now -ge $start -and $now -lt $end) }
    else { $scheduled = ($now -ge $start -or $now -lt $end) }
    Check 'Schedule' 'OK' ($config.start + ' -> ' + $config.end + '; currently ' + $(if ($scheduled) { 'ACTIVE' } else { 'INACTIVE' }))

    if (Test-Path $OverridePath) {
        try {
            $until = [DateTime]::Parse((Get-Content $OverridePath -Raw -ErrorAction Stop)).ToUniversalTime()
            if ([DateTime]::UtcNow -lt $until) {
                Check 'Override' 'INFO' ('ACTIVE until ' + $until.ToString('u'))
            } else {
                Check 'Override' 'INFO' 'inactive'
            }
        } catch {
            Check 'Override' 'WARN' 'override-until.txt could not be parsed; no policy change made'
        }
    } else {
        Check 'Override' 'INFO' 'inactive'
    }
}

$packetProcess = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
$controlProcess = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })

if ($packetProcess.Count -gt 0) {
    Check 'Packet filter process' 'OK' 'RUNNING'
} else {
    Check 'Packet filter process' 'WARN' 'NOT RUNNING'
    [void]$problems.Add('packet-filter.ps1 is not running.')
}

if ($controlProcess.Count -gt 0) {
    Check 'Control plane process' 'OK' 'RUNNING'
} else {
    Check 'Control plane process' 'WARN' 'NOT RUNNING'
    [void]$problems.Add('ultra-mode.ps1 is not running.')
}

foreach ($domain in @('youtube.com','www.youtube.com','ytimg.com','googlevideo.com','chatgpt.com','crushon.ai','windowsmcp.io','google.com')) {
    if (Resolve-TestDomain $domain) {
        Check ('DNS: ' + $domain) 'OK' 'resolved'
    } else {
        Check ('DNS: ' + $domain) 'WARN' 'could not resolve'
        [void]$problems.Add('DNS failed for ' + $domain + '.')
    }
}

try {
    $tcp = Test-NetConnection -ComputerName 'www.youtube.com' -Port 443 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) {
        Check 'TCP 443: YouTube' 'OK' ('reachable at ' + [string]$tcp.RemoteAddress)
    } else {
        Check 'TCP 443: YouTube' 'WARN' ('connection failed; RemoteAddress=' + [string]$tcp.RemoteAddress)
        [void]$problems.Add('YouTube TCP 443 connection failed.')
    }
} catch {
    Check 'TCP 443: YouTube' 'WARN' $_.Exception.Message
}

$Hosts = 'C:\Windows\System32\drivers\etc\hosts'
if (Test-Path $Hosts) {
    $hits = @(Get-Content $Hosts -ErrorAction SilentlyContinue | Where-Object { $_ -match '(youtube|youtu\.be|ytimg|googlevideo|chatgpt|crushon)' })
    if ($hits.Count -eq 0) {
        Check 'Hosts file' 'OK' 'no Untrapped target entries found'
    } else {
        Check 'Hosts file' 'WARN' ($hits.Count.ToString() + ' relevant entry/entries found; Untrapped does not manage Hosts')
        foreach ($hit in $hits) { Report ('       ' + $hit) }
        [void]$problems.Add('Relevant Hosts entries exist outside Untrapped.')
    }
}

Report ''
Report 'WinHTTP proxy:'
try {
    $proxy = @(netsh winhttp show proxy 2>&1)
    foreach ($line in $proxy) { Report ('  ' + [string]$line) }
} catch {}

try {
    $up = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    Check 'Network adapters' 'INFO' ($up.Count.ToString() + ' adapter(s) currently UP')
} catch {
    Check 'Network adapters' 'WARN' $_.Exception.Message
}

try {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop)
    if ($routes.Count -gt 0) {
        Check 'Default route' 'OK' ($routes.Count.ToString() + ' default route(s) present')
    } else {
        Check 'Default route' 'FAIL' 'no IPv4 default route found'
        [void]$problems.Add('No IPv4 default route was found.')
    }
} catch {
    Check 'Default route' 'WARN' $_.Exception.Message
}

Report ''
Report '============================================================'
Report ' DIAGNOSIS'
Report '============================================================'

if ($problems.Count -eq 0) {
    Report '[HEALTHY] No obvious configuration, process, DNS, or routing fault detected.'
} else {
    foreach ($problem in @($problems | Sort-Object -Unique)) {
        Report ('[CAUSE] ' + $problem)
    }
    Report ''
    Report 'NO POLICY CHANGES WERE MADE.'
}

Report ''
Report '============================================================'
Report ' END SELF-DIAGNOSTIC - READ ONLY'
Report '============================================================'

try {
    $lines | Set-Content -Path $ReportPath -Encoding UTF8 -ErrorAction Stop
    if (Test-Path $ReportPath) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList @($ReportPath) -ErrorAction Stop
        Write-Host ''
        Write-Host ('[OK] Diagnostic report saved: ' + $ReportPath)
    }
} catch {
    Write-Host ('[WARN] Could not save/open diagnostic report: ' + $_.Exception.Message)
}
