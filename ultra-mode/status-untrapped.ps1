# Untrapped Ultra Mode - Health Diagnostic
# EDITOR NOTE: THE DIAGNOSIS CONTRACT IS IMMUTABLE.
# Do not edit/remove/reorder/change the diagnosis contract or severity semantics.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Parent = Split-Path -Parent $Root
$SelfPath = $MyInvocation.MyCommand.Path
$ReportPath = Join-Path $Root 'diagnostic-latest.txt'
$RepairPath = Join-Path $Root 'self-repair.ps1'
$RepoBase = 'https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/'
$ExtensionFiles = @('manifest.json','background.js','content.js','popup.html','popup.js','bootstrap.bundle.min.js')
$CoreTextFiles = @('config.json','packet-filter.ps1','ultra-mode.ps1','status-untrapped.ps1','self-repair.ps1')
$CoreFiles = @('WinDivert.dll','WinDivert64.sys') + $CoreTextFiles
$Lines = New-Object 'System.Collections.Generic.List[string]'
$Problems = New-Object 'System.Collections.Generic.List[string]'

function Out([string] $s) { Write-Host $s; [void] $Lines.Add($s) }
function Problem([string] $s) { if ($s -and -not ($Problems -contains $s)) { [void] $Problems.Add($s) } }
function Get-RemoteText([string] $p) {
    $u = $RepoBase + $p + '?cb=' + [DateTime]::UtcNow.Ticks
    Write-Host ('[UPDATE] Downloading canonical ' + $p + ' ...')
    return (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
}
function ValidScript([string] $t) {
    try { [void] [scriptblock]::Create($t); return $true } catch { return $false }
}
function SameRemote([string] $p, [string] $local) {
    try {
        if (-not (Test-Path -LiteralPath $local)) { return $false }
        return ([IO.File]::ReadAllText($local) -ceq (Get-RemoteText $p))
    } catch { return $false }
}
function TestHttps([string] $hostName) {
    try {
        Write-Host ('[CHECK] Testing HTTPS ' + $hostName + ':443 ...')
        $r = Test-NetConnection -ComputerName $hostName -Port 443 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        return [bool] $r.TcpTestSucceeded
    } catch { return $false }
}
function Find-BraveUntrapped {
    $found = New-Object 'System.Collections.Generic.List[string]'
    $userData = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
    if (-not (Test-Path -LiteralPath $userData)) { return @() }
    $profiles = @(Get-ChildItem -LiteralPath $userData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
    foreach ($profile in $profiles) {
        $extDir = Join-Path $profile.FullName 'Extensions'
        if (-not (Test-Path -LiteralPath $extDir)) { continue }
        foreach ($idDir in @(Get-ChildItem -LiteralPath $extDir -Directory -ErrorAction SilentlyContinue)) {
            foreach ($verDir in @(Get-ChildItem -LiteralPath $idDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                $manifest = Join-Path $verDir.FullName 'manifest.json'
                if (-not (Test-Path -LiteralPath $manifest)) { continue }
                try {
                    $m = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
                    if ([string] $m.name -eq 'Untrapped') { [void] $found.Add($verDir.FullName) }
                } catch { }
            }
        }
    }
    return @($found | Sort-Object -Unique)
}

# ==================== AUTO-UPDATE ====================
$UpdateState = 'UNKNOWN'
$UpdateDetail = ''
Out ''
Out '=== AUTO-UPDATE: BEGIN ==='
Write-Host '[UPDATE] Checking TLS/network access to canonical GitHub source.'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $remote = Get-RemoteText 'ultra-mode/status-untrapped.ps1'
    $local = [IO.File]::ReadAllText($SelfPath)
    Write-Host ('[UPDATE] Local bytes: ' + $local.Length + ' | Canonical bytes: ' + $remote.Length)
    if ($remote -ne $local) {
        Write-Host '[UPDATE] DIFFERENCE DETECTED.'
        Write-Host '[UPDATE] Validating canonical diagnostic before replacing local copy.'
        if ($remote.Length -lt 1500 -or -not (ValidScript $remote)) { throw 'Downloaded diagnostic failed validation; local copy preserved.' }
        Copy-Item -LiteralPath $SelfPath -Destination ($SelfPath + '.preupdate.bak') -Force
        [IO.File]::WriteAllText($SelfPath, $remote, (New-Object Text.UTF8Encoding($false)))
        if (([IO.File]::ReadAllText($SelfPath)) -cne $remote) { throw 'Diagnostic post-write verification failed.' }
        Write-Host '[UPDATE] Backup, write, and post-write verification succeeded.'
        $env:UNTRAPPED_STATUS_UPDATED = '1'
        $child = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SelfPath) -WorkingDirectory $Root -Wait -PassThru
        exit $child.ExitCode
    }
    if ($env:UNTRAPPED_STATUS_UPDATED) { $UpdateState = 'UPDATED THIS RUN'; $UpdateDetail = 'A newer canonical diagnostic was installed and verified, then this copy was restarted.' }
    else { $UpdateState = 'ALREADY CURRENT'; $UpdateDetail = 'Local diagnostic exactly matches canonical GitHub source; no update was needed.' }
    Write-Host ('[UPDATE] ' + $UpdateState)
    Write-Host ('[UPDATE] ' + $UpdateDetail)
} catch {
    $UpdateState = 'FAILED'
    $UpdateDetail = 'Diagnostic auto-update failed: ' + $_.Exception.Message
    Write-Host ('[UPDATE] FAILED: ' + $_.Exception.Message)
    Problem 'Diagnostic auto-update failed.'
}
Out '=== AUTO-UPDATE: END ==='

Out ''
Out '========================================'
Out '       UNTRAPPED HEALTH DASHBOARD'
Out '========================================'
Out ('Time: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))

# ==================== POLICY ====================
Out ''
Out '=== POLICY CHECKS: BEGIN ==='
$config = $null
$scheduled = $false
$override = $false
try {
    Write-Host '[POLICY] Reading config.json.'
    $config = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
    $start = [TimeSpan]::Parse([string] $config.start)
    $end = [TimeSpan]::Parse([string] $config.end)
    $now = (Get-Date).TimeOfDay
    if ($start -eq $end) { $inWindow = $true }
    elseif ($start -lt $end) { $inWindow = $now -ge $start -and $now -lt $end }
    else { $inWindow = $now -ge $start -or $now -lt $end }
    $overrideFile = Join-Path $Root 'override-until.txt'
    if (Test-Path -LiteralPath $overrideFile) {
        Write-Host '[POLICY] Checking override-until.txt.'
        try { $until = [DateTime]::Parse((Get-Content -LiteralPath $overrideFile -Raw)).ToUniversalTime(); $override = [DateTime]::UtcNow -lt $until } catch { }
    }
    $scheduled = [bool] ($config.enabled -and $inWindow -and -not $override)
    Write-Host ('[POLICY] Blocking schedule active: ' + $scheduled)
} catch {
    Problem 'Config is invalid or unreadable.'
    Write-Host '[POLICY] FAILED to read/parse configuration.'
}
$yt = TestHttps 'www.youtube.com'
$chat = TestHttps 'chatgpt.com'
$crush = TestHttps 'www.crushon.ai'
$expectedReachable = -not $scheduled
$ytOK = ($yt -eq $expectedReachable)
$chatOK = ($chat -eq $expectedReachable)
$crushOK = -not $crush
Out 'POLICY'
Out ('  YouTube : ' + $(if ($ytOK) { if ($scheduled) { 'BLOCKED OK' } else { 'ALLOWED OK' } } else { 'WRONG' }))
Out ('  ChatGPT : ' + $(if ($chatOK) { if ($scheduled) { 'BLOCKED OK' } else { 'ALLOWED OK' } } else { 'WRONG' }))
Out ('  CrushOn : ' + $(if ($crushOK) { 'BLOCKED OK' } else { 'REACHABLE WRONG' }))
if (-not $ytOK) { Problem 'YouTube does not match the configured policy.' }
if (-not $chatOK) { Problem 'ChatGPT does not match the configured policy.' }
if (-not $crushOK) { Problem 'CrushOn does not match the configured policy.' }
Out '=== POLICY CHECKS: END ==='

# ==================== CORE ====================
Out ''
Out '=== UNTRAPPED CORE CHECKS: BEGIN ==='
Write-Host '[CORE] Checking required files and running processes.'
$packet = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
$control = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })
$missing = @($CoreFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_)) })
$coreBad = @()
foreach ($f in $CoreTextFiles) {
    Write-Host ('[CORE SOURCE] Comparing ' + $f + ' with canonical GitHub source.')
    if (-not (SameRemote ('ultra-mode/' + $f) (Join-Path $Root $f))) { $coreBad += $f; Out ('  ' + $f + ' : DIFFERENT/MISSING') }
    else { Out ('  ' + $f + ' : CURRENT OK') }
}
Out 'UNTRAPPED CORE'
Out ('  Packet filter : ' + $(if ($packet.Count) { 'RUNNING OK' } else { 'STOPPED' }))
Out ('  Control plane : ' + $(if ($control.Count) { 'RUNNING OK' } else { 'STOPPED' }))
Out ('  Required files: ' + ($CoreFiles.Count - $missing.Count) + '/' + $CoreFiles.Count)
Out ('  Canonical mismatches: ' + $(if ($coreBad.Count) { $coreBad -join ', ' } else { 'NONE' }))
if (-not $packet.Count) { Problem 'Packet filter is not running.' }
if (-not $control.Count) { Problem 'Control plane is not running.' }
if ($missing.Count) { Problem ('Required Untrapped files are missing: ' + ($missing -join ', ')) }
if ($coreBad.Count) { Problem 'Untrapped core source differs from canonical GitHub.' }
Out '=== UNTRAPPED CORE CHECKS: END ==='

# ==================== EXTENSION SOURCE ====================
Out ''
Out '=== EXTENSION SOURCE CHECKS: BEGIN ==='
$sourceBad = @()
foreach ($f in $ExtensionFiles) {
    $p = Join-Path $Parent $f
    Write-Host ('[EXTENSION SOURCE] Comparing ' + $f + ' with canonical GitHub source.')
    if (-not (SameRemote $f $p)) { $sourceBad += $f; Out ('  ' + $f + ' : DIFFERENT/MISSING') }
    else { Out ('  ' + $f + ' : CURRENT OK') }
}
if ($sourceBad.Count) { Problem 'Untrapped Enhanced extension source needs repair.' }
Out '=== EXTENSION SOURCE CHECKS: END ==='

# ==================== BRAVE EXTENSION ====================
Out ''
Out '=== BRAVE EXTENSION DISCOVERY: BEGIN ==='
Write-Host '[BRAVE] Searching Brave profiles for an installed Untrapped extension.'
$installed = Find-BraveUntrapped
Out 'BRAVE EXTENSION'
if (-not $installed.Count) {
    Out '  Installed Untrapped copy: NOT FOUND'
    Problem 'Installed Brave Untrapped extension could not be located.'
} else {
    foreach ($d in $installed) {
        $bad = @()
        Out ('  Found: ' + $d)
        foreach ($f in $ExtensionFiles) {
            Write-Host ('[BRAVE] Comparing installed ' + $f + ' with canonical source.')
            if (-not (SameRemote $f (Join-Path $d $f))) { $bad += $f }
        }
        if ($bad.Count) { Out ('  Installed copy: ' + $bad.Count + ' file(s) differ'); Problem 'Installed Brave Untrapped extension differs from GitHub.' }
        else { Out '  Installed copy: CURRENT OK' }
    }
}
Out '=== BRAVE EXTENSION DISCOVERY: END ==='

# ==================== NETWORK ====================
Out ''
Out '=== NETWORK/SYSTEM CHECKS: BEGIN ==='
$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
Write-Host ('[NETWORK] Active adapters found: ' + $adapters.Count)
$badIP = $false
foreach ($a in $adapters) {
    Write-Host ('[NETWORK] Inspecting ' + $a.Name + ' (ifIndex ' + $a.ifIndex + ').')
    $c = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
    if (-not $c.IPv4Address -and -not $c.IPv6Address) { $badIP = $true }
}
$dnsOK = $false
try { Write-Host '[DNS] Resolving google.com.'; $dnsOK = @((Resolve-DnsName 'google.com' -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })).Count -gt 0 } catch { }
$httpsOK = TestHttps 'www.google.com'
$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
$bfeOK = $false
try { Write-Host '[WFP] Checking Base Filtering Engine (BFE).'; $bfeOK = (Get-Service -Name BFE -ErrorAction Stop).Status -eq 'Running' } catch { }
$hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostHits = @()
if (Test-Path -LiteralPath $hosts) {
    Write-Host '[HOSTS] Scanning hosts file for target entries.'
    $hostHits = @(Get-Content -LiteralPath $hosts | Where-Object { $_ -match '(?i)(youtube|youtu\.be|chatgpt|crushon)' -and $_ -notmatch '^\s*#' })
}
$proxy = 'UNKNOWN'
try {
    Write-Host '[PROXY] Reading WinHTTP proxy configuration.'
    $proxyOutput = netsh winhttp show proxy 2>$null
    if ($proxyOutput -match 'Direct access') { $proxy = 'DIRECT' } elseif ($proxyOutput -match 'Proxy Server') { $proxy = 'CONFIGURED' }
} catch { }
$tunnels = @($adapters | Where-Object { $_.InterfaceDescription -match '(?i)(proton|speedify|vpn|wireguard|tun|tap)' })
Out 'NETWORK'
Out ('  Active adapters: ' + $adapters.Count)
Out ('  Internet : ' + $(if ($httpsOK) { 'OK' } else { 'FAIL' }))
Out ('  DNS      : ' + $(if ($dnsOK) { 'OK' } else { 'FAIL' }))
Out ('  IP       : ' + $(if ($adapters.Count -and -not $badIP) { 'OK' } elseif (-not $adapters.Count) { 'NO ACTIVE ADAPTERS' } else { 'CHECK' }))
Out ('  Routes   : ' + $(if ($routes.Count) { 'OK (' + $routes.Count + ')' } else { 'FAIL' }))
Out ('  WFP/BFE  : ' + $(if ($bfeOK) { 'OK' } else { 'FAIL' }))
Out ('  Hosts    : ' + $(if (-not $hostHits.Count) { 'CLEAN OK' } else { 'TARGET ENTRIES' }))
Out ('  Proxy    : ' + $proxy)
Out ('  VPN/tunnel adapters: ' + $tunnels.Count)
if (-not $adapters.Count) { Out '[NETWORK] No active adapter; DNS/HTTPS failures are recorded as external network state.' }
if (-not $httpsOK -and $adapters.Count) { Problem 'General HTTPS failed.' }
if (-not $dnsOK -and $adapters.Count) { Problem 'General DNS resolution failed.' }
if ($badIP) { Problem 'An active network adapter has no IP address.' }
if (-not $routes.Count -and $adapters.Count) { Problem 'No IPv4 default route exists.' }
if (-not $bfeOK) { Problem 'Windows Base Filtering Engine is not running.' }
if ($hostHits.Count) { Problem 'Hosts file contains relevant target entries.' }
Out '=== NETWORK/SYSTEM CHECKS: END ==='

# ==================== GITHUB ====================
Out ''
Out '=== GITHUB AVAILABILITY CHECK: BEGIN ==='
try { Write-Host '[GITHUB] Requesting github.com.'; [void] (Invoke-WebRequest -Uri 'https://github.com' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop); Out '  GitHub: ACCESSIBLE OK' }
catch { Out '  GitHub: UNREACHABLE'; if ($adapters.Count) { Problem 'GitHub could not be reached.' } else { Out '  GitHub failure is attributed to the external network state because no active adapter exists.' } }
Out '=== GITHUB AVAILABILITY CHECK: END ==='

# ==================== AUTO-REPAIR ====================
$repairable = ($sourceBad.Count -gt 0 -or $coreBad.Count -gt 0 -or $missing.Count -gt 0 -or -not $packet.Count -or -not $control.Count)
$needsRepair = $repairable
$PreRepairProblems = @($Problems)
$RepairState = 'NOT NEEDED'
$RepairExit = 'N/A'
Out ''
Out '=== AUTO-REPAIR: BEGIN ==='
if ($needsRepair -and (Test-Path -LiteralPath $RepairPath)) {
    Out '[AUTO-REPAIR] REQUIRED'
    Out '[AUTO-REPAIR] Trigger reasons:'
    foreach ($p in $PreRepairProblems) { Out ('  -> ' + $p) }
    Out '[AUTO-REPAIR] Launching elevated canonical repair engine.'
    try {
        $r = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$RepairPath) -WorkingDirectory $Root -Verb RunAs -Wait -PassThru -ErrorAction Stop
        $RepairExit = [string] $r.ExitCode
        if ($r.ExitCode -eq 0) { $RepairState = 'COMPLETED' } else { $RepairState = 'FAILED'; Problem 'Self-repair reported failure.' }
        Out ('[AUTO-REPAIR] Process exit code: ' + $RepairExit)
    } catch { $RepairState = 'FAILED TO START'; Problem 'Self-repair could not be started.'; Out ('[AUTO-REPAIR] START FAILED: ' + $_.Exception.Message) }
} elseif ($needsRepair) {
    $RepairState = 'UNAVAILABLE'
    Problem 'Self-repair engine is missing.'
    Out '[AUTO-REPAIR] REQUIRED but repair engine is unavailable.'
} else { Out '[AUTO-REPAIR] No Untrapped-owned repair is required.' }
Out ('[AUTO-REPAIR] State: ' + $RepairState)
Out ('[AUTO-REPAIR] Exit code: ' + $RepairExit)
Out '=== AUTO-REPAIR: END ==='

# ==================== POST-REPAIR VERIFICATION ====================
$PostRepair = 'NOT RUN'
Out ''
Out '=== POST-REPAIR VERIFICATION: BEGIN ==='
if ($needsRepair -and $RepairState -eq 'COMPLETED') {
    Write-Host '[VERIFY] Rechecking repaired Untrapped-owned state.'
    Start-Sleep -Seconds 2
    $coreAfterMissing = @($CoreFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_)) })
    $coreAfterBad = @($CoreTextFiles | Where-Object { -not (SameRemote ('ultra-mode/' + $_) (Join-Path $Root $_)) })
    $sourceAfterBad = @($ExtensionFiles | Where-Object { -not (SameRemote $_ (Join-Path $Parent $_)) })
    $packetAfter = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
    $controlAfter = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })
    $installedAfter = Find-BraveUntrapped
    $installedAfterBad = 0
    foreach ($d in $installedAfter) { foreach ($f in $ExtensionFiles) { if (-not (SameRemote $f (Join-Path $d $f))) { $installedAfterBad++ } } }
    Out ('[VERIFY] Missing core files after repair: ' + $coreAfterMissing.Count)
    Out ('[VERIFY] Core canonical mismatches after repair: ' + $coreAfterBad.Count)
    Out ('[VERIFY] Extension-source mismatches after repair: ' + $sourceAfterBad.Count)
    Out ('[VERIFY] Installed Brave copies after repair: ' + $installedAfter.Count)
    Out ('[VERIFY] Installed Brave mismatched files after repair: ' + $installedAfterBad)
    Out ('[VERIFY] Packet filter processes after repair: ' + $packetAfter.Count)
    Out ('[VERIFY] Control plane processes after repair: ' + $controlAfter.Count)
    if (-not $coreAfterMissing.Count -and -not $coreAfterBad.Count -and -not $sourceAfterBad.Count -and $installedAfterBad -eq 0 -and $packetAfter.Count -and $controlAfter.Count) { $PostRepair = 'REPAIR SUCCESS - VERIFIED' }
    else { $PostRepair = 'REPAIR INCOMPLETE - RECHECK NEEDED' }
} else { Out '[VERIFY] No completed Untrapped repair; verification not required.' }
Out ('[VERIFY] Result: ' + $PostRepair)
Out '=== POST-REPAIR VERIFICATION: END ==='

# ==================== DIAGNOSIS CONTRACT: DO NOT EDIT ====================
# Stable diagnosis semantics. DO NOT EDIT THIS SECTION.
if ($RepairState -eq 'FAILED' -or $RepairState -eq 'FAILED TO START' -or $RepairState -eq 'UNAVAILABLE' -or $PostRepair -eq 'REPAIR INCOMPLETE - RECHECK NEEDED') { $Diagnosis = 'REPAIR INCOMPLETE' }
elseif ($Problems.Count -eq 0) { if ($PostRepair -eq 'REPAIR SUCCESS - VERIFIED') { $Diagnosis = 'REPAIR SUCCESS - VERIFIED' } elseif ($UpdateState -eq 'UPDATED THIS RUN') { $Diagnosis = 'HEALTHY - DIAGNOSTIC UPDATED' } else { $Diagnosis = 'ALL CLEAR' } }
else {
    $untrappedFault = $false
    foreach ($p in $Problems) { if ($p -match '(?i)Untrapped|Packet filter|Control plane|extension|Self-repair|core source|Required Untrapped') { $untrappedFault = $true } }
    if ($untrappedFault) { $Diagnosis = 'ATTENTION NEEDED - UNTRAPPED' } else { $Diagnosis = 'ATTENTION NEEDED - EXTERNAL PREREQUISITE' }
}
# ================== END DIAGNOSIS CONTRACT ==================

# ==================== REPORT ====================
Out ''
Out '========================================'
Out 'CONDENSED DIAGNOSIS'
Out ('  OVERALL: ' + $Diagnosis)
Out ('  Auto-update : ' + $UpdateState)
Out ('  Auto-repair : ' + $RepairState)
Out ('  Repair verify: ' + $PostRepair)
Out ('  Issues      : ' + $Problems.Count)
if ($Problems.Count) { foreach ($p in $Problems) { Out ('  ! ' + $p) } } else { Out '  Result      : No unresolved faults remain.' }
Out '========================================'
Out ''
Out 'DETAILED DIAGNOSTIC'
Out ('  Update detail: ' + $UpdateDetail)
Out ('  Repair triggered: ' + $needsRepair)
Out ('  Pre-repair issue count: ' + $PreRepairProblems.Count)
Out ('  Extension source mismatches before repair: ' + $(if ($sourceBad.Count) { $sourceBad -join ', ' } else { 'NONE' }))
Out ('  Brave copies found before repair: ' + $installed.Count)
Out ('  Active adapters: ' + $adapters.Count)
Out ('  Default routes: ' + $routes.Count)
Out ('  Relevant Hosts entries: ' + $hostHits.Count)
Out ('  VPN/tunnel adapters: ' + $tunnels.Count)
Out ('  WinHTTP proxy: ' + $proxy)
Out ('  BFE running: ' + $bfeOK)
Out ('  Override active: ' + $override)
Out ('  Scheduled blocking window: ' + $scheduled)
Out ('  Canonical source: ' + $RepoBase)
Out '  Repair scope: Untrapped-owned files/processes only; Windows network stack is not altered.'
Out '  ACTION TRACE: Every check, comparison, repair trigger, repair result, and verification result is printed above.'
Out '  Next run: self-update first, then policy/core/extension/Brave/network checks, repair if needed, and full post-repair verification.'
Out ''
Out 'STATUS'
Out ('  ' + $Diagnosis)
Out ('  Auto-update: ' + $UpdateState)
Out ('  Auto-repair: ' + $RepairState)
Out '  Extension auto-check: ENABLED'
Out '  Extension repair: ENABLED'
Out '  Automatic changes are limited to Untrapped-owned components.'

$Lines | Set-Content -LiteralPath $ReportPath -Encoding UTF8
if ($needsRepair -or $UpdateState -eq 'UPDATED' -or $UpdateState -eq 'UPDATED THIS RUN') { try { Start-Process notepad.exe -ArgumentList $ReportPath -ErrorAction SilentlyContinue } catch { } }
if ($Diagnosis -eq 'REPAIR INCOMPLETE' -or $Diagnosis -like 'ATTENTION NEEDED*') { exit 1 } else { exit 0 }
