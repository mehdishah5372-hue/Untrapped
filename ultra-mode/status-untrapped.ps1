# Untrapped Ultra Mode diagnostic - safe self-update bootstrap
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$SelfPath = $MyInvocation.MyCommand.Path
$ReportPath = Join-Path $Root 'diagnostic-latest.txt'
$RepairPath = Join-Path $Root 'self-repair.ps1'
$RepoBase = 'https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/'

function Get-RemoteText([string]$RelativePath) {
    $url = $RepoBase + $RelativePath + '?cb=' + [DateTime]::UtcNow.Ticks
    return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
}

# FIRST JOB: make sure this diagnostic itself is current.
$UpdateState = 'UNKNOWN'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $Remote = Get-RemoteText 'ultra-mode/status-untrapped.ps1'
    $Local = [IO.File]::ReadAllText($SelfPath)
    if ($Remote.Length -gt 1500 -and $Remote -ne $Local) {
        # Validate the downloaded PowerShell before replacing the working copy.
        [void][scriptblock]::Create($Remote)
        $Backup = $SelfPath + '.preupdate.bak'
        [IO.File]::Copy($SelfPath, $Backup, $true)
        [IO.File]::WriteAllText($SelfPath, $Remote, (New-Object Text.UTF8Encoding($false)))
        Write-Host '[UPDATE] New diagnostic downloaded from GitHub and installed.'
        Write-Host '[UPDATE] Restarting the new diagnostic now...'
        $env:UNTRAPPED_STATUS_UPDATED = '1'
        $Child = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SelfPath) -WorkingDirectory $Root -Wait -PassThru
        exit $Child.ExitCode
    }
    if ($env:UNTRAPPED_STATUS_UPDATED) {
        $UpdateState = 'UPDATED THIS RUN'
    } else {
        $UpdateState = 'ALREADY CURRENT'
    }
} catch {
    $UpdateState = 'GITHUB UPDATE CHECK FAILED'
    Write-Host ('[UPDATE ERROR] ' + $_.Exception.Message)
}

$Lines = New-Object 'System.Collections.Generic.List[string]'
$Problems = New-Object 'System.Collections.Generic.List[string]'
function Out([string]$Text) {
    Write-Host $Text
    [void]$Lines.Add($Text)
}
function Problem([string]$Text) {
    if (-not ($Problems -contains $Text)) {
        [void]$Problems.Add($Text)
    }
}
function TestHttps([string]$HostName) {
    try {
        return [bool](Test-NetConnection $HostName -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded
    } catch {
        return $false
    }
}
function TestRemoteFile([string]$RelativePath, [string]$LocalPath) {
    try {
        if (-not (Test-Path $LocalPath)) { return $false }
        $remote = Get-RemoteText $RelativePath
        $local = [IO.File]::ReadAllText($LocalPath)
        return $local -eq $remote
    } catch {
        return $false
    }
}

Out ''
Out '========================================'
Out '       UNTRAPPED HEALTH DASHBOARD'
Out '========================================'
Out ('Time: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Out ('Diagnostic update: ' + $UpdateState)

# Policy
$config = $null
$scheduled = $false
$override = $false
try {
    $config = Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
    $start = [TimeSpan]::Parse([string]$config.start)
    $end = [TimeSpan]::Parse([string]$config.end)
    $nowTime = (Get-Date).TimeOfDay
    if ($start -eq $end) {
        $inWindow = $true
    } elseif ($start -lt $end) {
        $inWindow = $nowTime -ge $start -and $nowTime -lt $end
    } else {
        $inWindow = $nowTime -ge $start -or $nowTime -lt $end
    }
    if (Test-Path (Join-Path $Root 'override-until.txt')) {
        try {
            $until = [DateTime]::Parse((Get-Content (Join-Path $Root 'override-until.txt') -Raw)).ToUniversalTime()
            $override = [DateTime]::UtcNow -lt $until
        } catch {}
    }
    $scheduled = [bool]($config.enabled -and $inWindow -and -not $override)
} catch {
    Problem 'Config is invalid or unreadable.'
}

Out ''
Out 'POLICY'
$yt = TestHttps 'www.youtube.com'
$chatgpt = TestHttps 'chatgpt.com'
$crush = TestHttps 'www.crushon.ai'
$ytExpectedReachable = -not $scheduled
$ytOK = ($yt -eq $ytExpectedReachable)
$chatOK = ($chatgpt -eq $ytExpectedReachable)
$crushOK = -not $crush
Out ('  YouTube  : ' + $(if ($ytOK) { if ($scheduled) { 'BLOCKED OK' } else { 'ALLOWED OK' } } else { 'WRONG' }))
Out ('  ChatGPT  : ' + $(if ($chatOK) { if ($scheduled) { 'BLOCKED OK' } else { 'ALLOWED OK' } } else { 'WRONG' }))
Out ('  CrushOn  : ' + $(if ($crushOK) { 'BLOCKED OK' } else { 'REACHABLE WRONG' }))
if (-not $ytOK) { Problem 'YouTube does not match the configured policy.' }
if (-not $chatOK) { Problem 'ChatGPT does not match the configured policy.' }
if (-not $crushOK) { Problem 'CrushOn does not match the configured policy.' }

# Core
$packet = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
$control = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })
$required = @('WinDivert.dll','WinDivert64.sys','config.json','packet-filter.ps1','ultra-mode.ps1','status-untrapped.ps1','self-repair.ps1')
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $Root $_)) })
Out ''
Out 'UNTRAPPED CORE'
Out ('  Packet filter : ' + $(if ($packet.Count) { 'RUNNING OK' } else { 'STOPPED' }))
Out ('  Control plane : ' + $(if ($control.Count) { 'RUNNING OK' } else { 'STOPPED' }))
Out ('  Required files: ' + ($required.Count - $missing.Count) + '/' + $required.Count)
if (-not $packet.Count) { Problem 'Packet filter is not running.' }
if (-not $control.Count) { Problem 'Control plane is not running.' }
if ($missing.Count) { Problem 'Required Untrapped files are missing: ' + ($missing -join ', ') }

# Extension source
$ExtensionFiles = @('manifest.json','background.js','content.js','popup.html','popup.js','bootstrap.bundle.min.js')
$sourceBad = @()
Out ''
Out 'EXTENSION SOURCE'
foreach ($file in $ExtensionFiles) {
    $path = Join-Path (Split-Path -Parent $Root) $file
    if (TestRemoteFile ('/' + $file).TrimStart('/') $path) {
        Out ('  ' + $file + ' : CURRENT OK')
    } else {
        Out ('  ' + $file + ' : DIFFERENT/MISSING')
        $sourceBad += $file
    }
}
if ($sourceBad.Count) { Problem 'Untrapped Enhanced extension source needs repair.' }

# Installed Brave extension
$installed = @()
$userData = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
if (Test-Path $userData) {
    $profiles = @(Get-ChildItem $userData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
    foreach ($profile in $profiles) {
        $extDir = Join-Path $profile.FullName 'Extensions'
        if (-not (Test-Path $extDir)) { continue }
        foreach ($idDir in @(Get-ChildItem $extDir -Directory -ErrorAction SilentlyContinue)) {
            foreach ($verDir in @(Get-ChildItem $idDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                $manifest = Join-Path $verDir.FullName 'manifest.json'
                if (Test-Path $manifest) {
                    try {
                        $m = Get-Content $manifest -Raw | ConvertFrom-Json
                        if ([string]$m.name -match '(?i)^Untrapped') { $installed += $verDir.FullName }
                    } catch {}
                }
            }
        }
    }
}
$installed = @($installed | Select-Object -Unique)
Out ''
Out 'BRAVE EXTENSION'
if ($installed.Count -eq 0) {
    Out '  Installed Untrapped copy: NOT FOUND'
    Problem 'Installed Brave Untrapped extension could not be located.'
} else {
    foreach ($dir in $installed) {
        $bad = @()
        Out ('  Found: ' + $dir)
        foreach ($file in $ExtensionFiles) {
            $path = Join-Path $dir $file
            if (-not (TestRemoteFile $file $path)) { $bad += $file }
        }
        if ($bad.Count) {
            Out ('  Installed copy: ' + $bad.Count + ' file(s) differ')
            Problem 'Installed Brave Untrapped extension differs from GitHub.'
        } else {
            Out '  Installed copy: CURRENT OK'
        }
    }
}

# Network health
Out ''
Out 'NETWORK'
$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
$badIP = $false
foreach ($adapter in $adapters) {
    $ip = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
    if (-not $ip.IPv4Address -and -not $ip.IPv6Address) { $badIP = $true }
}
$dnsOK = $false
try { $dnsOK = @(Resolve-DnsName 'google.com' -DnsOnly -ErrorAction Stop | Where-Object IPAddress).Count -gt 0 } catch {}
$httpsOK = TestHttps 'www.google.com'
$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
$bfeOK = $false
try { $bfeOK = (Get-Service BFE -ErrorAction Stop).Status -eq 'Running' } catch {}
Out ('  Internet : ' + $(if ($httpsOK) { 'OK' } else { 'FAIL' }))
Out ('  DNS      : ' + $(if ($dnsOK) { 'OK' } else { 'FAIL' }))
Out ('  IP       : ' + $(if (-not $badIP -and $adapters.Count) { 'OK' } else { 'CHECK' }))
Out ('  Routes   : ' + $(if ($routes.Count) { 'OK' } else { 'FAIL' }))
Out ('  WFP/BFE  : ' + $(if ($bfeOK) { 'OK' } else { 'FAIL' }))
if (-not $httpsOK) { Problem 'General HTTPS failed.' }
if (-not $dnsOK) { Problem 'General DNS resolution failed.' }
if ($badIP) { Problem 'An active network adapter has no IP address.' }
if (-not $routes.Count) { Problem 'No IPv4 default route exists.' }
if (-not $bfeOK) { Problem 'Windows Base Filtering Engine is not running.' }

# GitHub reachability
Out ''
Out 'GITHUB'
try {
    [void](Invoke-WebRequest 'https://github.com' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop)
    Out '  GitHub: ACCESSIBLE OK'
} catch {
    Out '  GitHub: UNREACHABLE'
    Problem 'GitHub could not be reached.'
}

# Repair only Untrapped-owned components.
$needsRepair = ($Problems.Count -gt 0 -or $sourceBad.Count -gt 0)
if ($needsRepair -and (Test-Path $RepairPath)) {
    Out ''
    Out '[REPAIR] Starting Untrapped self-repair...'
    try {
        $repair = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$RepairPath) -WorkingDirectory $Root -Verb RunAs -Wait -PassThru -ErrorAction Stop
        Out ('[REPAIR] Exit code: ' + $repair.ExitCode)
    } catch {
        Out ('[REPAIR] FAILED TO START: ' + $_.Exception.Message)
    }
}

if ($sourceBad.Count -eq 0 -and $installed.Count -gt 0 -and $UpdateState -eq 'ALREADY CURRENT') {
    Out ''
    Out '[UPDATE] Untrapped and Untrapped Enhanced are already current. No updates needed.'
}

Out ''
Out '========================================'
if ($Problems.Count) {
    Out ('STATUS: ATTENTION NEEDED (' + $Problems.Count + ')')
    foreach ($problem in $Problems) { Out ('  ! ' + $problem) }
} else {
    Out 'STATUS: ALL CLEAR OK'
}
Out '========================================'
Out ('Auto-update result: ' + $UpdateState)
Out 'Extension auto-check: ENABLED'
Out 'Extension repair: ENABLED'
Out 'Automatic changes are limited to Untrapped-owned components.'
$Lines | Set-Content $ReportPath -Encoding UTF8
if ($needsRepair -or $UpdateState -eq 'UPDATED' -or $UpdateState -eq 'UPDATED THIS RUN') {
    try { Start-Process notepad.exe -ArgumentList $ReportPath -ErrorAction SilentlyContinue } catch {}
}
if ($Problems.Count) { exit 1 } else { exit 0 }
