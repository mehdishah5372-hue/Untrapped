# Untrapped Ultra Mode - Baseline Health Diagnostic
# READ-ONLY DIAGNOSTIC: this script observes Untrapped and Windows network state.
# It does not change firewall, WFP, DNS, routing, Hosts, proxy, adapters, VPN, or override state.
$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Parent = Split-Path -Parent $Root
$SelfPath = $MyInvocation.MyCommand.Path
$ReportPath = Join-Path $Root 'diagnostic-latest.txt'
$RepoBase = 'https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/'
$ExtensionFiles = @('manifest.json','background.js','content.js','popup.html','popup.js','bootstrap.bundle.min.js')
$CoreFiles = @('config.json','packet-filter.ps1','ultra-mode.ps1','status-untrapped.ps1','self-repair.ps1','WinDivert.dll','WinDivert64.sys')
$Lines = New-Object 'System.Collections.Generic.List[string]'
$Problems = New-Object 'System.Collections.Generic.List[string]'
function Trace([string]$Stage,[string]$Message) {
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] [' + $Stage + '] ' + $Message
    Write-Host $line
    [void]$Lines.Add($line)
}
function Problem([string]$Message) {
    if ($Message -and -not ($Problems -contains $Message)) { [void]$Problems.Add($Message) }
}
function RemoteText([string]$Path) {
    $url = $RepoBase + $Path + '?cb=' + [DateTime]::UtcNow.Ticks
    Trace 'GITHUB' ('GET ' + $Path)
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    return [string]$r.Content
}
function SameCanonical([string]$RemotePath,[string]$LocalPath) {
    if (-not (Test-Path -LiteralPath $LocalPath)) {
        Trace 'CORE' ('MISSING: ' + $LocalPath)
        return $false
    }
    try {
        $remote = RemoteText $RemotePath
        $local = [IO.File]::ReadAllText($LocalPath)
        return ($remote -ceq $local)
    } catch {
        Trace 'ERROR' ('Canonical comparison failed for ' + $RemotePath + ': ' + $_.Exception.Message)
        return $false
    }
}
function Https([string]$HostName) {
    try {
        $r = Test-NetConnection -ComputerName $HostName -Port 443 -WarningAction SilentlyContinue
        return [bool]$r.TcpTestSucceeded
    } catch { return $false }
}
function Find-BraveUntrapped {
    $result = @()
    $userData = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
    if (-not (Test-Path -LiteralPath $userData)) { return @() }
    $profiles = @(Get-ChildItem -LiteralPath $userData -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
    foreach ($profile in $profiles) {
        $extDir = Join-Path $profile.FullName 'Extensions'
        if (-not (Test-Path -LiteralPath $extDir)) { continue }
        foreach ($id in @(Get-ChildItem -LiteralPath $extDir -Directory)) {
            foreach ($ver in @(Get-ChildItem -LiteralPath $id.FullName -Directory)) {
                $manifest = Join-Path $ver.FullName 'manifest.json'
                if (-not (Test-Path -LiteralPath $manifest)) { continue }
                try {
                    $m = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
                    if ([string]$m.name -eq 'Untrapped') { $result += $ver.FullName }
                } catch { }
            }
        }
    }
    return @($result | Sort-Object -Unique)
}
function WriteReport {
    $Lines | Set-Content -LiteralPath $ReportPath -Encoding UTF8
    Trace 'REPORT' ('Saved: ' + $ReportPath)
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Trace 'START' '=== UNTRAPPED BASELINE DIAGNOSTIC ==='
Trace 'START' ('Time: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Trace 'POLICY' 'Reading config and override state.'
$config = $null
$scheduled = $false
$override = $false
try {
    $config = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
    $start = [TimeSpan]::Parse([string]$config.start)
    $end = [TimeSpan]::Parse([string]$config.end)
    $now = (Get-Date).TimeOfDay
    if ($start -eq $end) { $inWindow = $true } elseif ($start -lt $end) { $inWindow = ($now -ge $start -and $now -lt $end) } else { $inWindow = ($now -ge $start -or $now -lt $end) }
    $overrideFile = Join-Path $Root 'override-until.txt'
    if (Test-Path -LiteralPath $overrideFile) {
        try { $until = [DateTime]::Parse((Get-Content -LiteralPath $overrideFile -Raw)).ToUniversalTime(); $override = ([DateTime]::UtcNow -lt $until) } catch { Problem 'Override file exists but is unreadable.' }
    }
    $scheduled = [bool]($config.enabled -and $inWindow -and -not $override)
    Trace 'POLICY' ('Enabled=' + $config.enabled + ' | Window=' + $config.start + '-' + $config.end + ' | ScheduledBlock=' + $scheduled + ' | Override=' + $override)
} catch { Problem 'Config is invalid or unreadable.'; Trace 'ERROR' 'Config read/parse failed.' }
Trace 'POLICY' 'Testing actual endpoint reachability.'
$yt = Https 'www.youtube.com'
$chat = Https 'chatgpt.com'
$crush = Https 'www.crushon.ai'
$expected = -not $scheduled
if (($yt -eq $expected)) { Trace 'POLICY' ('YouTube: ' + $(if($scheduled){'BLOCKED OK'}else{'ALLOWED OK'})) } else { Trace 'POLICY' 'YouTube: WRONG'; Problem 'YouTube does not match configured policy.' }
if (($chat -eq $expected)) { Trace 'POLICY' ('ChatGPT: ' + $(if($scheduled){'BLOCKED OK'}else{'ALLOWED OK'})) } else { Trace 'POLICY' 'ChatGPT: WRONG'; Problem 'ChatGPT does not match configured policy.' }
if (-not $crush) { Trace 'POLICY' 'CrushOn: BLOCKED OK' } else { Trace 'POLICY' 'CrushOn: REACHABLE WRONG'; Problem 'CrushOn does not match configured policy.' }
Trace 'CORE' 'Checking Untrapped processes and files.'
$packet = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*packet-filter.ps1*' })
$control = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*ultra-mode.ps1*' })
$missing = @($CoreFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_)) })
$coreBad = @()
foreach ($f in @('config.json','packet-filter.ps1','ultra-mode.ps1','status-untrapped.ps1','self-repair.ps1')) { if (-not (SameCanonical ('ultra-mode/' + $f) (Join-Path $Root $f))) { $coreBad += $f } }
Trace 'CORE' ('Packet filter: ' + $(if($packet.Count){'RUNNING'}else{'STOPPED'}))
Trace 'CORE' ('Control plane: ' + $(if($control.Count){'RUNNING'}else{'STOPPED'}))
Trace 'CORE' ('Required files: ' + ($CoreFiles.Count - $missing.Count) + '/' + $CoreFiles.Count)
Trace 'CORE' ('Canonical core mismatches: ' + $(if($coreBad.Count){$coreBad -join ', '}else{'NONE'}))
if (-not $packet.Count) { Problem 'Packet filter is not running.' }
if (-not $control.Count) { Problem 'Control plane is not running.' }
if ($missing.Count) { Problem ('Required Untrapped files are missing: ' + ($missing -join ', ')) }
if ($coreBad.Count) { Problem 'Untrapped core source differs from canonical GitHub.' }
Trace 'EXTENSION' 'Checking Enhanced extension source files.'
$sourceBad = @()
foreach ($f in $ExtensionFiles) { if (-not (SameCanonical $f (Join-Path $Parent $f))) { $sourceBad += $f } }
Trace 'EXTENSION' ('Source mismatches: ' + $(if($sourceBad.Count){$sourceBad -join ', '}else{'NONE'}))
if ($sourceBad.Count) { Problem 'Untrapped Enhanced extension source differs from canonical GitHub.' }
Trace 'BRAVE' 'Searching standard Brave extension storage.'
$installed = Find-BraveUntrapped
Trace 'BRAVE' ('Installed Untrapped copies found: ' + $installed.Count)
if (-not $installed.Count) { Problem 'Installed Brave Untrapped extension could not be located in standard extension storage.' }
else { foreach ($d in $installed) { $bad = @(); foreach ($f in $ExtensionFiles) { if (-not (SameCanonical $f (Join-Path $d $f))) { $bad += $f } }; if ($bad.Count) { Trace 'BRAVE' ($d + ' mismatches: ' + ($bad -join ', ')); Problem 'Installed Brave Untrapped extension differs from canonical GitHub.' } else { Trace 'BRAVE' ($d + ' CURRENT OK') } } }
Trace 'NETWORK' 'Checking Windows network state without changing it.'
$adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0')
$dnsOK = $false
try { $dnsOK = @((Resolve-DnsName 'google.com' -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })).Count -gt 0 } catch { }
$google = Https 'www.google.com'
$bfeOK = $false
try { $bfeOK = (Get-Service BFE).Status -eq 'Running' } catch { }
$hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostHits = @()
if (Test-Path -LiteralPath $hosts) { $hostHits = @(Get-Content $hosts | Where-Object { $_ -match '(?i)(youtube|youtu\.be|chatgpt|crushon)' -and $_ -notmatch '^\s*#' }) }
$proxy = 'UNKNOWN'
try { $p = netsh winhttp show proxy 2>$null; if ($p -match 'Direct access') { $proxy = 'DIRECT' } elseif ($p -match 'Proxy Server') { $proxy = 'CONFIGURED' } } catch { }
Trace 'NETWORK' ('Active adapters: ' + $adapters.Count + ' | Default routes: ' + $routes.Count)
Trace 'NETWORK' ('DNS google.com: ' + $(if($dnsOK){'OK'}else{'FAILED'}) + ' | Google HTTPS: ' + $(if($google){'OK'}else{'FAILED'}))
Trace 'NETWORK' ('Hosts target entries: ' + $hostHits.Count + ' | WinHTTP proxy: ' + $proxy + ' | BFE: ' + $(if($bfeOK){'RUNNING'}else{'NOT RUNNING/UNKNOWN'}))
if ($adapters.Count -gt 0 -and -not $dnsOK) { Problem 'External DNS resolution is failing.' }
if ($adapters.Count -gt 0 -and -not $google) { Problem 'External HTTPS connectivity to Google is failing.' }
if ($hostHits.Count) { Problem 'Relevant Hosts entries were found.' }
if (-not $bfeOK) { Problem 'Base Filtering Engine prerequisite is not running.' }
Trace 'SUMMARY' '=== DIAGNOSIS ==='
if ($Problems.Count -eq 0) { Trace 'SUMMARY' 'HEALTHY: no detected problems.' } else { Trace 'SUMMARY' ('PROBLEMS: ' + $Problems.Count); foreach ($p in $Problems) { Trace 'SUMMARY' ('! ' + $p) } }
Trace 'SUMMARY' 'This baseline diagnostic is observation-first. It does not auto-repair or restart itself.'
WriteReport
Trace 'END' '=== DIAGNOSTIC COMPLETE ==='
