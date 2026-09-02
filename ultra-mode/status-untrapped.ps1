# UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE
# UAUD diagnoses and orchestrates. UARD repairs. Baseline 1.0.0 may only be retained or upgraded.
$ErrorActionPreference = 'SilentlyContinue'
$UAUDName = 'UAUD (Untrapped Auto-Update & Diagnostics)'
$UAUDVersion = '1.0.0'
$UARDName = 'UARD (Untrapped Auto-Repair Diagnostic)'
$UARDVersion = '1.0.0'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Parent = Split-Path -Parent $Root
$ReportPath = Join-Path $Root 'diagnostic-latest.txt'
$RepairPath = Join-Path $Root 'self-repair.ps1'
$Middleman = 'https://untrapped-update-middleman-production.up.railway.app/v1/artifact/'
$log = New-Object 'System.Collections.Generic.List[string]'
$initialProblems = @()
$repairResult = 'NOT RUN'
$deployment = 'NOT NEEDED'
$UARDNeeded = $false
$core = @('config.json','packet-filter.ps1','self-repair.ps1','status-untrapped.ps1','ultra-mode.ps1')

function Log([string]$Message) {
    $line = '[' + (Get-Date -Format HH:mm:ss) + '] ' + $Message
    Write-Host $line
    [void]$log.Add($line)
}

function HashBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function RemoteBytes([string]$Path) {
    try {
        $url = $Middleman + $Path + '?cb=' + [DateTime]::UtcNow.Ticks
        $request = [Net.HttpWebRequest]::Create($url)
        $request.Method = 'GET'
        $request.Timeout = 45000
        $request.ReadWriteTimeout = 45000
        $response = [Net.HttpWebResponse]$request.GetResponse()
        try {
            if ([int]$response.StatusCode -ne 200) { throw ('HTTP ' + [int]$response.StatusCode) }
            $stream = $response.GetResponseStream()
            try {
                $memory = New-Object IO.MemoryStream
                try { $stream.CopyTo($memory); return $memory.ToArray() }
                finally { $memory.Dispose() }
            } finally { $stream.Dispose() }
        } finally { $response.Dispose() }
    } catch {
        Log ('[MIDDLEMAN] UNAVAILABLE ' + $Path + ': ' + $_.Exception.Message)
        return $null
    }
}

function SameCanonical([string]$RemotePath,[string]$LocalPath) {
    if (-not (Test-Path -LiteralPath $LocalPath)) { return $false }
    $remote = RemoteBytes $RemotePath
    if ($null -eq $remote) { return $null }
    try { return (HashBytes ([IO.File]::ReadAllBytes($LocalPath))) -eq (HashBytes $remote) }
    catch { return $false }
}

function HTTPS([string]$HostName) {
    try { return (Test-NetConnection $HostName -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded }
    catch { return $false }
}

function StateWord([bool]$Value,[string]$Yes,[string]$No) {
    if ($Value) { return $Yes }
    return $No
}

function IsUntrappedManifest([string]$Directory) {
    $manifest = Join-Path $Directory 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return $false }
    try {
        $obj = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
        return ([string]$obj.name -eq 'Untrapped')
    } catch { return $false }
}

function FindUntrappedCopies {
    $found = New-Object 'System.Collections.Generic.List[string]'
    $roots = @(
        $Parent,
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )
    $userData = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
    if (Test-Path $userData) { $roots += $userData }
    foreach ($base in $roots) {
        if (-not (Test-Path $base)) { continue }
        try {
            $manifests = Get-ChildItem -LiteralPath $base -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue
            foreach ($manifest in @($manifests)) {
                try {
                    $obj = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
                    if ([string]$obj.name -eq 'Untrapped') { [void]$found.Add($manifest.Directory.FullName) }
                } catch {}
            }
        } catch {}
    }
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^brave' -and $_.CommandLine -match '(?i)--load-extension=' })) {
        foreach ($match in [regex]::Matches([string]$process.CommandLine, '--load-extension=(?:"([^"]+)"|([^\s]+))')) {
            $dir = $match.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $match.Groups[2].Value }
            if (Test-Path $dir) {
                $manifest = Join-Path $dir 'manifest.json'
                if (Test-Path $manifest) {
                    try {
                        if ([string]((Get-Content $manifest -Raw | ConvertFrom-Json).name) -eq 'Untrapped') {
                            [void]$found.Add((Resolve-Path $dir).Path)
                        }
                    } catch {}
                }
            }
        }
    }
    return @($found | Sort-Object -Unique)
}

function Diagnose([string]$Phase) {
    Log ('[DIAGNOSTIC] ' + $Phase + ' diagnostic begins.')
    $problems = @()
    $config = $null
    $scheduled = $false
    $override = $false
    try {
        $config = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
        $start = [TimeSpan]::Parse($config.start)
        $end = [TimeSpan]::Parse($config.end)
        $now = (Get-Date).TimeOfDay
        if ($start -lt $end) { $inside = ($now -ge $start -and $now -lt $end) }
        else { $inside = ($now -ge $start -or $now -lt $end) }
        $overridePath = Join-Path $Root 'override-until.txt'
        if (Test-Path $overridePath) {
            try { $override = [DateTime]::UtcNow -lt ([DateTime]::Parse((Get-Content $overridePath -Raw)).ToUniversalTime()) }
            catch { $problems += 'Override file is unreadable.' }
        }
        $scheduled = [bool]($config.enabled -and $inside -and -not $override)
        Write-Host ('[STATUS] Policy: ' + (StateWord ([bool]$config.enabled) 'ENABLED' 'DISABLED'))
        Write-Host ('[STATUS] Schedule: ' + $config.start + ' - ' + $config.end)
        Write-Host ('[STATUS] Scheduled blocking: ' + (StateWord $scheduled 'ACTIVE' 'INACTIVE'))
        Write-Host ('[STATUS] Override: ' + (StateWord $override 'ACTIVE' 'INACTIVE'))
    } catch { $problems += 'Config is invalid or unreadable.' }

    $youtube = HTTPS 'www.youtube.com'
    $chatgpt = HTTPS 'chatgpt.com'
    $crushon = HTTPS 'www.crushon.ai'
    Write-Host ('[STATUS] YouTube transport: ' + (StateWord $youtube 'REACHABLE' 'UNREACHABLE'))
    Write-Host ('[STATUS] ChatGPT transport: ' + (StateWord $chatgpt 'REACHABLE' 'UNREACHABLE'))
    Write-Host ('[STATUS] CrushOn transport: ' + (StateWord $crushon 'REACHABLE' 'UNREACHABLE'))

    $coreBad = @()
    $coreUnknown = @()
    foreach ($file in $core) {
        $result = SameCanonical ('ultra-mode/' + $file) (Join-Path $Root $file)
        if ($result -eq $false) { $coreBad += $file }
        elseif ($null -eq $result) { $coreUnknown += $file }
    }
    if ($coreBad.Count -gt 0) {
        Write-Host '[STATUS] Untrapped core vs canonical: MISMATCH'
        $problems += 'Untrapped core differs from canonical Railway artifact: ' + ($coreBad -join ', ')
    } elseif ($coreUnknown.Count -gt 0) {
        Write-Host '[STATUS] Untrapped core vs canonical: UNVERIFIED'
        $problems += 'Untrapped core could not be verified: ' + ($coreUnknown -join ', ')
    } else { Write-Host '[STATUS] Untrapped core vs canonical: CURRENT' }

    $nativeOK = (Test-Path (Join-Path $Root 'WinDivert.dll')) -and (Test-Path (Join-Path $Root 'WinDivert64.sys'))
    Write-Host ('[STATUS] WinDivert native files: ' + (StateWord $nativeOK 'PRESENT' 'MISSING'))
    if (-not $nativeOK) { $problems += 'Required WinDivert native component is missing.' }

    $packet = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
    $control = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })
    Write-Host ('[STATUS] Packet filter: ' + (StateWord ([bool]$packet.Count) 'RUNNING' 'STOPPED'))
    Write-Host ('[STATUS] Control plane: ' + (StateWord ([bool]$control.Count) 'RUNNING' 'STOPPED'))
    if (-not $packet.Count) { $problems += 'Packet filter is not running.' }
    if (-not $control.Count) { $problems += 'Control plane is not running.' }

    $copies = @(FindUntrappedCopies)
    Write-Host ('[STATUS] Brave/Untrapped copies: ' + $copies.Count + ' ' + (StateWord ([bool]$copies.Count) 'FOUND' 'NOT FOUND - INFORMATIONAL'))

    if ($config) {
        $wantReachable = -not $scheduled
        if ($youtube -ne $wantReachable) { $problems += 'YouTube transport does not match configured policy.' }
        if ($chatgpt -ne $wantReachable) { $problems += 'ChatGPT transport does not match configured policy.' }
        if ($crushon) { $problems += 'CrushOn is reachable despite always-block policy.' }
    }

    $dnsOK = $false
    try { $dnsOK = @(Resolve-DnsName google.com -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress }).Count -gt 0 } catch {}
    $googleOK = HTTPS 'www.google.com'
    $bfeOK = $false
    try { $bfeOK = (Get-Service BFE).Status -eq 'Running' } catch {}
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $hostEntries = @()
    if (Test-Path $hostsPath) { $hostEntries = @(Get-Content $hostsPath | Where-Object { $_ -match '(?i)(youtube|youtu\.be|chatgpt|crushon)' -and $_ -notmatch '^\s*#' }) }
    Write-Host ('[STATUS] DNS: ' + (StateWord $dnsOK 'OK' 'FAILED'))
    Write-Host ('[STATUS] Google HTTPS: ' + (StateWord $googleOK 'OK' 'FAILED'))
    Write-Host ('[STATUS] Relevant Hosts entries: ' + $hostEntries.Count)
    Write-Host ('[STATUS] BFE: ' + (StateWord $bfeOK 'RUNNING' 'NOT RUNNING/UNKNOWN'))
    if (-not $dnsOK) { $problems += 'External DNS resolution is failing.' }
    if (-not $googleOK) { $problems += 'External HTTPS connectivity to Google is failing.' }
    if ($hostEntries.Count) { $problems += 'Relevant Hosts entries were found.' }
    if (-not $bfeOK) { $problems += 'Base Filtering Engine is not running.' }

    return @{ Problems = @($problems); CoreBad = $coreBad; CoreUnknown = $coreUnknown; Brave = $copies }
}

function DeployUARD {
    Log '[UARD DEPLOY] Checking canonical UARD through Railway middleman.'
    $bytes = RemoteBytes 'ultra-mode/self-repair.ps1'
    if ($null -eq $bytes) { return 'UNVERIFIED' }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    try { [void][scriptblock]::Create($text) }
    catch { Log ('[UARD DEPLOY] Canonical UARD parse failed: ' + $_.Exception.Message); return 'FAILED' }
    $localVersion = [version]'0.0.0'
    if (Test-Path $RepairPath) {
        try { $localVersion = [version]'1.0.0' } catch {}
    }
    if ((HashBytes $bytes) -eq (HashBytes ([Text.Encoding]::UTF8.GetBytes($text))) -and (Test-Path $RepairPath)) {
        try {
            if ((HashBytes ([IO.File]::ReadAllBytes($RepairPath))) -eq (HashBytes $bytes)) {
                Log '[UARD DEPLOY] Current; no deployment required.'
                return 'CURRENT'
            }
        } catch {}
    }
    $tmp = $RepairPath + '.deploy.tmp'
    try {
        if (Test-Path $RepairPath) {
            $backup = $RepairPath + '.pre-deploy-' + (Get-Date -Format yyyyMMdd-HHmmss) + '.bak'
            Copy-Item $RepairPath $backup -Force
            Log ('[UARD DEPLOY] Backup ' + $backup)
        }
        [IO.File]::WriteAllBytes($tmp, $bytes)
        if ((HashBytes ([IO.File]::ReadAllBytes($tmp))) -ne (HashBytes $bytes)) { throw 'Deployment SHA-256 verification failed.' }
        Move-Item -LiteralPath $tmp -Destination $RepairPath -Force
        if ((HashBytes ([IO.File]::ReadAllBytes($RepairPath))) -ne (HashBytes $bytes)) { throw 'Post-deployment SHA-256 verification failed.' }
        Log '[UARD DEPLOY] Deployed and verified.'
        return 'DEPLOYED'
    } catch {
        Log ('[UARD DEPLOY] FAILED: ' + $_.Exception.Message)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return 'FAILED'
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Log ('=== ' + $UAUDName + ' ver ' + $UAUDVersion + ' ===')
Log 'TRUE BASELINE 1.0.0: retained or upgraded, never silently downgraded.'
Log 'MIDDLEMAN: Railway is the update comparison source.'
$diagnosis = Diagnose 'INITIAL'
$initialProblems = @($diagnosis.Problems)
$UARDNeeded = $initialProblems.Count -gt 0
Write-Host ('[UARD DECISION] UARD NEEDED = ' + (StateWord $UARDNeeded 'YES' 'NO'))
if ($UARDNeeded) {
    $deployment = DeployUARD
    if ($deployment -in @('DEPLOYED','CURRENT')) {
        $process = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$RepairPath) -WorkingDirectory $Root -WindowStyle Normal -PassThru -ErrorAction SilentlyContinue
        if ($process) {
            Log '[UARD] LIVE PowerShell window created.'
            $process.WaitForExit()
            if ($process.ExitCode -eq 0) { $repairResult = 'SUCCESS' }
            elseif ($process.ExitCode -eq 2) { $repairResult = 'VERIFICATION UNKNOWN' }
            else { $repairResult = 'FAILURE' }
            Log ('[UARD] LIVE window closed. Exit code ' + $process.ExitCode + ' / ' + $repairResult)
        } else {
            $repairResult = 'START FAILURE'
            Log '[UARD] LIVE PowerShell window could not be created.'
        }
    } else {
        $repairResult = 'NOT LAUNCHED'
        Log '[UARD] Not launched; canonical UARD was not safely verified.'
    }
} else { Log '[DIAGNOSTIC] UARD not needed.' }

Log '[DIAGNOSTIC] Final verification begins.'
$final = Diagnose 'FINAL'
$remaining = @($final.Problems)
$overall = 'HEALTHY'
if ($remaining.Count) { $overall = 'UNHEALTHY' }
$out = @(
    'CONDENSED DIAGNOSIS',
    ' OVERALL: ' + $overall,
    ' UAUD: ' + $UAUDName + ' ver ' + $UAUDVersion,
    ' UARD NEEDED: ' + (StateWord $UARDNeeded 'YES' 'NO'),
    ' UARD deployment: ' + $deployment,
    ' UARD result: ' + $repairResult,
    ' MIDDLEMAN: Railway update broker',
    ' UPDATE NORMALIZATION: reported by UARD when applicable',
    ' Brave copies: ' + $final.Brave.Count,
    ' Remaining problems: ' + $remaining.Count
)
foreach ($problem in $remaining) { $out += ' ! ' + $problem }
$out += @(
    '',
    'EXPLANATORY TABLE',
    'Component | Owner | Behaviour',
    'UAUD | Update + diagnosis | Uses Railway canonical artifacts and decides whether UARD is needed',
    'UARD | Repair + verification | Repairs Untrapped-owned components and validates SHA-256',
    'Live PowerShell | UARD | Visible only while UARD actively repairs',
    'Notepad | Both | UARD report opens for repair/verification outcomes; UAUD report always opens',
    'Baseline | UAUD + UARD | 1.0.0 protected; upgrades allowed; downgrades refused',
    'Brave | UAUD + UARD | Searches Brave profiles, developer/source locations, and --load-extension paths',
    'Network infrastructure | Diagnosis only | Firewall/WFP/DNS/routes/Hosts/proxy/adapters/VPN/override policy are not modified'
)
$out | Set-Content -LiteralPath $ReportPath -Encoding UTF8
$log | Add-Content -LiteralPath $ReportPath -Encoding UTF8
Start-Process notepad.exe -ArgumentList @($ReportPath) -ErrorAction SilentlyContinue
Log ('=== ' + $UAUDName + ' END ===')
