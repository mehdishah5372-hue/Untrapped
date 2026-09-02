# Untrapped Ultra Mode - read-only health check
# This script does not change policy or networking.

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$ReportPath = Join-Path $Root 'diagnostic-latest.txt'
$OverridePath = Join-Path $Root 'override-until.txt'

$lines = New-Object System.Collections.Generic.List[string]
$problems = New-Object System.Collections.Generic.List[string]

function Report([string]$Text) {
    Write-Host $Text
    [void]$lines.Add($Text)
}

function Problem([string]$Text) {
    [void]$problems.Add($Text)
}

function DnsOK([string]$Name) {
    try {
        $a = @(Resolve-DnsName -Name $Name -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
        if ($a.Count -gt 0) { return $true }
    } catch {}
    try {
        $aaaa = @(Resolve-DnsName -Name $Name -Type AAAA -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
        if ($aaaa.Count -gt 0) { return $true }
    } catch {}
    return $false
}

function CheckFile([string]$Name) {
    $path = Join-Path $Root $Name
    if (Test-Path $path) {
        Report ('[OK] File: ' + $Name + ' present')
    } else {
        Report ('[FAIL] File: ' + $Name + ' missing')
        Problem ('Missing required file: ' + $Name)
    }
}

Report ''
Report '============================================================'
Report ' UNTRAPPED ULTRA MODE - READ-ONLY DIAGNOSTIC'
Report '============================================================'
Report ('Time: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Report ''

foreach ($name in @('WinDivert.dll','WinDivert64.sys','config.json','packet-filter.ps1','ultra-mode.ps1')) {
    CheckFile $name
}

$config = $null
try {
    $config = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $start = [TimeSpan]::Parse([string]$config.start)
    $end = [TimeSpan]::Parse([string]$config.end)
    Report '[OK] Configuration: config.json parsed and schedule times are valid'

    $now = (Get-Date).TimeOfDay
    $active = $false
    if ($start -eq $end) {
        $active = $true
    } elseif ($start -lt $end) {
        $active = ($now -ge $start -and $now -lt $end)
    } else {
        $active = ($now -ge $start -or $now -lt $end)
    }
    if ([bool]$config.enabled) {
        Report ('[INFO] Schedule: ' + [string]$config.start + ' -> ' + [string]$config.end + '; currently ' + $(if ($active) { 'ACTIVE' } else { 'INACTIVE' }))
    } else {
        Report '[WARN] Schedule: config is disabled'
    }
} catch {
    Report ('[FAIL] Configuration: ' + $_.Exception.Message)
    Problem 'config.json could not be parsed or its schedule is invalid.'
}

if (Test-Path $OverridePath) {
    try {
        $until = [DateTime]::Parse((Get-Content $OverridePath -Raw -ErrorAction Stop)).ToUniversalTime()
        if ([DateTime]::UtcNow -lt $until) {
            Report ('[INFO] Override: ACTIVE until ' + $until.ToString('u'))
        } else {
            Report '[INFO] Override: inactive'
        }
    } catch {
        Report '[WARN] Override: override-until.txt could not be parsed'
    }
} else {
    Report '[INFO] Override: inactive'
}

$packet = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
$control = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })

if ($packet.Count -gt 0) {
    Report '[OK] Packet filter process: RUNNING'
} else {
    Report '[WARN] Packet filter process: NOT RUNNING'
    Problem 'packet-filter.ps1 is not running.'
}

if ($control.Count -gt 0) {
    Report '[OK] Control plane process: RUNNING'
} else {
    Report '[WARN] Control plane process: NOT RUNNING'
    Problem 'ultra-mode.ps1 is not running.'
}

foreach ($name in @('youtube.com','www.youtube.com','ytimg.com','googlevideo.com','chatgpt.com','crushon.ai','windowsmcp.io','google.com')) {
    if (DnsOK $name) {
        Report ('[OK] DNS: ' + $name + ' resolved')
    } else {
        Report ('[WARN] DNS: ' + $name + ' did not resolve')
        if ($name -eq 'google.com') {
            Problem 'General DNS resolution failed.'
        } else {
            Problem ('Target DNS resolution failed: ' + $name)
        }
    }
}

try {
    $tcp = Test-NetConnection -ComputerName 'www.youtube.com' -Port 443 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) {
        Report ('[OK] TCP 443: www.youtube.com reachable; RemoteAddress=' + [string]$tcp.RemoteAddress)
    } else {
        Report ('[WARN] TCP 443: www.youtube.com failed; RemoteAddress=' + [string]$tcp.RemoteAddress)
        Problem 'YouTube TCP 443 connection failed.'
    }
} catch {
    Report ('[WARN] TCP 443 test error: ' + $_.Exception.Message)
}

$hostsPath = 'C:\Windows\System32\drivers\etc\hosts'
if (Test-Path $hostsPath) {
    $hits = @(Get-Content $hostsPath -ErrorAction SilentlyContinue | Where-Object { $_ -match '(youtube|youtu\.be|ytimg|googlevideo|chatgpt|crushon)' })
    if ($hits.Count -eq 0) {
        Report '[OK] Hosts: no Untrapped target entries found'
    } else {
        Report ('[WARN] Hosts: ' + $hits.Count + ' relevant entry/entries found')
        foreach ($hit in $hits) { Report ('       ' + $hit) }
        Problem 'Relevant Hosts entries exist outside Untrapped.'
    }
}

try {
    $proxy = @(netsh winhttp show proxy 2>&1)
    Report ''
    Report 'WinHTTP proxy:'
    foreach ($item in $proxy) { Report ('  ' + [string]$item) }
} catch {}

try {
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    Report ('[INFO] Network adapters UP: ' + $adapters.Count)
} catch {
    Report '[WARN] Could not query network adapters'
}

try {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop)
    if ($routes.Count -gt 0) {
        Report ('[OK] IPv4 default route(s): ' + $routes.Count)
    } else {
        Report '[FAIL] IPv4 default route: none found'
        Problem 'No IPv4 default route was found.'
    }
} catch {
    Report ('[WARN] Default-route check failed: ' + $_.Exception.Message)
}

Report ''
Report '============================================================'
Report ' DIAGNOSIS'
Report '============================================================'

$uniqueProblems = @($problems | Sort-Object -Unique)
if ($uniqueProblems.Count -eq 0) {
    Report '[HEALTHY] No obvious configuration, process, DNS, or routing fault detected.'
} else {
    foreach ($item in $uniqueProblems) {
        Report ('[CAUSE] ' + $item)
    }
}

Report ''
Report 'NO POLICY CHANGES WERE MADE.'
Report '============================================================'

try {
    $lines | Set-Content -Path $ReportPath -Encoding UTF8 -ErrorAction Stop
    Report ('[OK] Diagnostic report saved to: ' + $ReportPath)
    Start-Process -FilePath 'notepad.exe' -ArgumentList $ReportPath -ErrorAction Stop
} catch {
    Report ('[WARN] Could not save or open diagnostic report: ' + $_.Exception.Message)
}
