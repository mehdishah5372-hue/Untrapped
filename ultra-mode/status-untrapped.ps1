# Untrapped Ultra Mode - read-only health check
# This script does not change policy or networking.
# It automatically checks GitHub for a newer copy of THIS diagnostic script before running.

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$ReportPath = Join-Path $Root 'diagnostic-latest.txt'
$OverridePath = Join-Path $Root 'override-until.txt'
$UpdateUrl = 'https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/ultra-mode/status-untrapped.ps1'

# Self-update: read-only with respect to Untrapped policy/networking.
# If GitHub has a newer copy, replace this script and restart it once.
$updateMarker = [Environment]::GetEnvironmentVariable('UNTRAPPED_STATUS_UPDATED','Process')
if (-not $updateMarker) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tempUpdate = Join-Path $env:TEMP ('untrapped-status-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Invoke-WebRequest -Uri $UpdateUrl -OutFile $tempUpdate -UseBasicParsing -ErrorAction Stop
        $remote = [IO.File]::ReadAllText($tempUpdate)
        $local = [IO.File]::ReadAllText($MyInvocation.MyCommand.Path)
        if ($remote -ne $local -and $remote.Length -gt 1000) {
            Copy-Item -LiteralPath $tempUpdate -Destination $MyInvocation.MyCommand.Path -Force -ErrorAction Stop
            Remove-Item -LiteralPath $tempUpdate -Force -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable('UNTRAPPED_STATUS_UPDATED','1','Process')
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
            exit
        }
        Remove-Item -LiteralPath $tempUpdate -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host ('[WARN UPDATE UNAVAILABLE] Could not check for a newer diagnostic script: ' + $_.Exception.Message)
    }
}

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

function TestTarget443([string]$Name, [bool]$ExpectedBlocked) {
    try {
        $tcp = Test-NetConnection -ComputerName $Name -Port 443 -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) {
            if ($ExpectedBlocked) {
                Report ('[FAIL REACHABLE] BLOCK TEST: ' + $Name + ' is REACHABLE on TCP 443; expected BLOCKED; RemoteAddress=' + [string]$tcp.RemoteAddress)
                Problem ($Name + ' is reachable while it should be blocked.')
            } else {
                Report ('[OK REACHABLE] BLOCK TEST: ' + $Name + ' is reachable on TCP 443; expected ALLOWED; RemoteAddress=' + [string]$tcp.RemoteAddress)
            }
        } else {
            if ($ExpectedBlocked) {
                Report ('[OK UNREACHABLE] BLOCK TEST: ' + $Name + ' is BLOCKED on TCP 443 as expected; RemoteAddress=' + [string]$tcp.RemoteAddress)
            } else {
                Report ('[FAIL UNREACHABLE] BLOCK TEST: ' + $Name + ' failed TCP 443 but should be ALLOWED; RemoteAddress=' + [string]$tcp.RemoteAddress)
                Problem ($Name + ' is unreachable while it should be allowed.')
            }
        }
    } catch {
        if ($ExpectedBlocked) {
            Report ('[OK UNREACHABLE] BLOCK TEST: ' + $Name + ' could not establish TCP 443 as expected for a blocked target.')
        } else {
            Report ('[WARN ERROR] BLOCK TEST: ' + $Name + ' test error: ' + $_.Exception.Message)
            Problem ($Name + ' blocking test encountered an error while it should be allowed.')
        }
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
$active = $false
$overrideActive = $false
try {
    $config = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $start = [TimeSpan]::Parse([string]$config.start)
    $end = [TimeSpan]::Parse([string]$config.end)
    Report '[OK] Configuration: config.json parsed and schedule times are valid'

    $now = (Get-Date).TimeOfDay
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
        Report '[WARN DISABLED] Schedule: config is disabled'
    }
} catch {
    Report ('[FAIL ERROR] Configuration: ' + $_.Exception.Message)
    Problem 'config.json could not be parsed or its schedule is invalid.'
}

if (Test-Path $OverridePath) {
    try {
        $until = [DateTime]::Parse((Get-Content $OverridePath -Raw -ErrorAction Stop)).ToUniversalTime()
        if ([DateTime]::UtcNow -lt $until) {
            $overrideActive = $true
            Report ('[INFO] Override: ACTIVE until ' + $until.ToString('u'))
        } else {
            Report '[INFO] Override: inactive'
        }
    } catch {
        Report '[WARN ERROR] Override: override-until.txt could not be parsed'
    }
} else {
    Report '[INFO] Override: inactive'
}

$packet = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
$control = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })

if ($packet.Count -gt 0) {
    Report '[OK RUNNING] Packet filter process: RUNNING'
} else {
    Report '[FAIL NOT RUNNING] Packet filter process: NOT RUNNING'
    Problem 'packet-filter.ps1 is not running.'
}

if ($control.Count -gt 0) {
    Report '[OK RUNNING] Control plane process: RUNNING'
} else {
    Report '[FAIL NOT RUNNING] Control plane process: NOT RUNNING'
    Problem 'ultra-mode.ps1 is not running.'
}

foreach ($name in @('youtube.com','www.youtube.com','ytimg.com','googlevideo.com','chatgpt.com','crushon.ai','windowsmcp.io','google.com')) {
    if (DnsOK $name) {
        Report ('[OK RESOLVED] DNS: ' + $name + ' resolved')
    } else {
        Report ('[WARN UNRESOLVED] DNS: ' + $name + ' did not resolve')
        if ($name -eq 'google.com') {
            Problem 'General DNS resolution failed.'
        } elseif ($name -eq 'ytimg.com') {
            Report '[INFO] ytimg.com DNS failure is non-fatal; YouTube core domains resolved.'
        } else {
            Problem ('Target DNS resolution failed: ' + $name)
        }
    }
}

Report ''
Report 'BLOCK TESTS'
Report '------------'

$scheduledBlock = ([bool]$config.enabled -and $active -and -not $overrideActive)
$alwaysBlocked = $false
if ($config -and $config.alwaysBlockedDomains -and @($config.alwaysBlockedDomains).Count -gt 0) {
    $alwaysBlocked = $true
}

TestTarget443 'www.youtube.com' $scheduledBlock
TestTarget443 'chatgpt.com' $scheduledBlock
TestTarget443 'www.crushon.ai' $alwaysBlocked

$hostsPath = 'C:\Windows\System32\drivers\etc\hosts'
if (Test-Path $hostsPath) {
    $hits = @(Get-Content $hostsPath -ErrorAction SilentlyContinue | Where-Object { $_ -match '(youtube|youtu\.be|ytimg|googlevideo|chatgpt|crushon)' })
    if ($hits.Count -eq 0) {
        Report '[OK CLEAN] Hosts: no Untrapped target entries found'
    } else {
        Report ('[WARN ENTRIES FOUND] Hosts: ' + $hits.Count + ' relevant entry/entries found')
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
    Report '[WARN ERROR] Could not query network adapters'
}

try {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop)
    if ($routes.Count -gt 0) {
        Report ('[OK FOUND] IPv4 default route(s): ' + $routes.Count)
    } else {
        Report '[FAIL NOT FOUND] IPv4 default route: none found'
        Problem 'No IPv4 default route was found.'
    }
} catch {
    Report ('[WARN ERROR] Default-route check failed: ' + $_.Exception.Message)
}

Report ''
Report '============================================================'
Report ' DIAGNOSIS'
Report '============================================================'

$uniqueProblems = @($problems | Sort-Object -Unique)
if ($uniqueProblems.Count -eq 0) {
    Report '[HEALTHY] No obvious configuration, process, DNS, routing, or blocking fault detected.'
} else {
    foreach ($item in $uniqueProblems) {
        Report ('[CAUSE] ' + $item)
    }
}

Report ''
Report '============================================================'
Report ' STATUS KEY / WHAT THE LABELS MEAN'
Report '============================================================'
Report '[OK]                 Check passed / expected condition found.'
Report '[OK REACHABLE]       Target is reachable and it SHOULD be allowed.'
Report '[OK UNREACHABLE]     Target is unreachable and it SHOULD be blocked.'
Report '[OK RESOLVED]        DNS lookup succeeded.'
Report '[OK RUNNING]         Required Untrapped process is running.'
Report '[OK FOUND]           Required network item was found.'
Report '[OK CLEAN]           No unexpected relevant Hosts entry was found.'
Report '[FAIL]               Check failed; something expected is missing or wrong.'
Report '[FAIL REACHABLE]     Target is reachable but it SHOULD be blocked.'
Report '[FAIL UNREACHABLE]   Target is unreachable but it SHOULD be allowed.'
Report '[FAIL NOT RUNNING]   Required Untrapped process is not running.'
Report '[FAIL NOT FOUND]     Required network item was not found.'
Report '[FAIL ERROR]         A required check could not complete because of an error.'
Report '[WARN]               Something unusual was detected, but it is not automatically fatal.'
Report '[WARN UNRESOLVED]    DNS lookup failed; this may or may not affect Untrapped.'
Report '[WARN DISABLED]      A feature/configuration is disabled.'
Report '[WARN ENTRIES FOUND] Unexpected relevant entries were found.'
Report '[WARN ERROR]        A diagnostic check itself encountered an error.'
Report '[WARN UPDATE UNAVAILABLE] GitHub update check failed; local diagnostic continues.'
Report '[INFO]               Informational status only; not a fault by itself.'
Report '[HEALTHY]            No known fault was detected by this diagnostic.'
Report '[CAUSE]              A specific problem was detected and listed as a likely cause.'
Report ''
Report 'BLOCK-TEST RULE:'
Report '  REACHABLE + expected ALLOWED   = [OK REACHABLE]'
Report '  UNREACHABLE + expected ALLOWED = [FAIL UNREACHABLE]'
Report '  REACHABLE + expected BLOCKED   = [FAIL REACHABLE]'
Report '  UNREACHABLE + expected BLOCKED = [OK UNREACHABLE]'
Report ''
Report 'AUTO-UPDATE RULE:'
Report '  Every UD run checks the official Untrapped GitHub copy.'
Report '  If a newer copy is found, it replaces the local diagnostic and restarts it once.'
Report '  If GitHub cannot be reached, the existing local diagnostic continues.'
Report '  Auto-update does NOT change policy, override state, firewall, WFP, DNS, routing, or VPN configuration.'
Report '============================================================'
Report 'NO POLICY CHANGES WERE MADE.'
Report '============================================================'

try {
    $lines | Set-Content -Path $ReportPath -Encoding UTF8 -ErrorAction Stop
    Report ('[OK] Diagnostic report saved to: ' + $ReportPath)
    Start-Process -FilePath 'notepad.exe' -ArgumentList $ReportPath -ErrorAction Stop
} catch {
    Report ('[WARN ERROR] Could not save or open diagnostic report: ' + $_.Exception.Message)
}
