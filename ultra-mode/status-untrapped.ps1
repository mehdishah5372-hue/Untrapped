# Untrapped Ultra Mode - health / self-healing diagnostic
# Reports Untrapped state plus surrounding Windows networking health.
# It does NOT modify Hosts, Firewall, WFP, DNS, routing, adapters, or VPN.

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$ReportPath = Join-Path $Root 'diagnostic-latest.txt'
$OverridePath = Join-Path $Root 'override-until.txt'
$PacketPath = Join-Path $Root 'packet-filter.ps1'
$UpdateUrl = 'https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/ultra-mode/status-untrapped.ps1'

# Self-update
$updateMarker = [Environment]::GetEnvironmentVariable('UNTRAPPED_STATUS_UPDATED','Process')
$updateStatus = 'NOT CHECKED'; $updateDetail = 'No update check has completed yet.'
if ($updateMarker) {
    $updateStatus = 'UPDATED SUCCESSFULLY'; $updateDetail = 'Diagnostic restarted after successfully replacing itself with the newer GitHub copy.'
} else {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tmp = Join-Path $env:TEMP ('untrapped-status-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Invoke-WebRequest -Uri $UpdateUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        $remote = [IO.File]::ReadAllText($tmp); $local = [IO.File]::ReadAllText($MyInvocation.MyCommand.Path)
        if ($remote -ne $local -and $remote.Length -gt 1000) {
            Copy-Item $tmp $MyInvocation.MyCommand.Path -Force -ErrorAction Stop
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable('UNTRAPPED_STATUS_UPDATED','1','Process')
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
            exit
        } elseif ($remote -eq $local) { $updateStatus='ALREADY UP TO DATE'; $updateDetail='Local diagnostic matches the official GitHub copy.' }
        else { $updateStatus='UPDATE NOT APPLIED'; $updateDetail='Downloaded copy failed the update safety check.' }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch { $updateStatus='UPDATE FAILED'; $updateDetail='GitHub update failed: ' + $_.Exception.Message }
}

$lines = New-Object System.Collections.Generic.List[string]
$problems = New-Object System.Collections.Generic.List[string]
function Report([string]$Text) { Write-Host $Text; [void]$lines.Add($Text) }
function Problem([string]$Text) { [void]$problems.Add($Text) }
function DnsOK([string]$Name) {
    try { if (@(Resolve-DnsName $Name -Type A -DnsOnly -ErrorAction Stop | Where-Object IPAddress).Count -gt 0) { return $true } } catch {}
    try { if (@(Resolve-DnsName $Name -Type AAAA -DnsOnly -ErrorAction Stop | Where-Object IPAddress).Count -gt 0) { return $true } } catch {}
    return $false
}
function CheckFile([string]$Name) {
    if (Test-Path (Join-Path $Root $Name)) { Report '[OK] File: ' + $Name + ' present' }
    else { Report '[FAIL] File: ' + $Name + ' missing'; Problem ('Missing required file: ' + $Name) }
}
function TestTarget443([string]$Name,[bool]$ExpectedBlocked) {
    try {
        $tcp=Test-NetConnection $Name -Port 443 -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) {
            if ($ExpectedBlocked) { Report ('[FAIL REACHABLE] BLOCK TEST: ' + $Name + ' reachable; expected BLOCKED; RemoteAddress=' + [string]$tcp.RemoteAddress); Problem ($Name + ' is reachable while it should be blocked.'); return $false }
            Report ('[OK REACHABLE] BLOCK TEST: ' + $Name + ' reachable; expected ALLOWED; RemoteAddress=' + [string]$tcp.RemoteAddress); return $true
        }
        if ($ExpectedBlocked) { Report ('[OK UNREACHABLE] BLOCK TEST: ' + $Name + ' blocked on TCP 443 as expected; RemoteAddress=' + [string]$tcp.RemoteAddress); return $true }
        Report ('[FAIL UNREACHABLE] BLOCK TEST: ' + $Name + ' failed TCP 443 but should be ALLOWED; RemoteAddress=' + [string]$tcp.RemoteAddress); Problem ($Name + ' is unreachable while it should be allowed.'); return $false
    } catch {
        if ($ExpectedBlocked) { Report ('[OK UNREACHABLE] BLOCK TEST: ' + $Name + ' could not establish TCP 443 as expected.'); return $true }
        Report ('[WARN ERROR] BLOCK TEST: ' + $Name + ': ' + $_.Exception.Message); Problem ($Name + ' blocking test errored while it should be allowed.'); return $false
    }
}
function Test-GitHubAccess {
    try {
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $r=Invoke-WebRequest 'https://github.com' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { Report ('[OK REACHABLE] GitHub accessible; HTTP ' + [string]$r.StatusCode) }
        else { Report ('[FAIL] GitHub returned HTTP ' + [string]$r.StatusCode); Problem 'GitHub returned an unexpected HTTP status.' }
    } catch { Report ('[FAIL] GitHub NOT accessible: ' + $_.Exception.Message); Problem 'GitHub could not be accessed.' }
}
function Get-ExpectedBlock([bool]$ScheduledActive,[bool]$OverrideActive) { return ([bool]$config.enabled -and $ScheduledActive -and -not $OverrideActive) }
function Repair-UntrappedFilter {
    if (-not (Test-Path $PacketPath)) { Report '[FAIL REPAIR] packet-filter.ps1 missing.'; Problem 'Cannot repair packet filter because packet-filter.ps1 is missing.'; return }
    try {
        @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object CommandLine -like '*packet-filter.ps1*') | ForEach-Object { try { Stop-Process $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
        Start-Sleep -Milliseconds 500
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PacketPath) -WorkingDirectory $Root -Verb RunAs -WindowStyle Hidden -ErrorAction Stop
        Report '[OK REPAIR STARTED] Packet filter restarted to rebuild WinDivert policy from config.json.'
    } catch { Report ('[FAIL REPAIR] Could not restart packet-filter.ps1: ' + $_.Exception.Message); Problem 'Policy mismatch detected but packet filter restart failed.' }
}

Report ''; Report '============================================================'; Report ' UNTRAPPED ULTRA MODE - HEALTH / SELF-HEALING DIAGNOSTIC'; Report '============================================================'
$nowLocal=Get-Date
Report ('Time: ' + $nowLocal.ToString('yyyy-MM-dd HH:mm:ss zzz')); Report ('Time zone: ' + [TimeZoneInfo]::Local.DisplayName + ' (' + [TimeZoneInfo]::Local.Id + ')'); Report ('UTC time: ' + $nowLocal.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss ''UTC'''))
Report ''; Report 'CLOCK / TIME CHECK'; Report '-----------------'; Report '[OK] System clock: ' + $nowLocal.ToString('yyyy-MM-dd HH:mm:ss zzz'); Report '[OK] Local UTC offset: ' + [TimeZoneInfo]::Local.GetUtcOffset($nowLocal).ToString()
Report ''; Report 'GITHUB ACCESS CHECK'; Report '------------------'; Test-GitHubAccess
Report ''; Report 'SELF-UPDATE STATUS'; Report '-----------------'; Report ('[' + $(if($updateStatus -eq 'UPDATE FAILED'){'FAIL'}elseif($updateStatus -eq 'ALREADY UP TO DATE'){'OK'}elseif($updateStatus -eq 'UPDATED SUCCESSFULLY'){'OK'}else{'WARN'}) + ' ' + $updateStatus + '] ' + $updateDetail)
Report ''
foreach ($n in @('WinDivert.dll','WinDivert64.sys','config.json','packet-filter.ps1','ultra-mode.ps1','status-untrapped.ps1','self-repair.ps1')) { CheckFile $n }

$config=$null; $active=$false; $overrideActive=$false
try {
    $config=Get-Content $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $start=[TimeSpan]::Parse([string]$config.start); $end=[TimeSpan]::Parse([string]$config.end); $now=(Get-Date).TimeOfDay
    if($start -eq $end){$active=$true}elseif($start -lt $end){$active=($now -ge $start -and $now -lt $end)}else{$active=($now -ge $start -or $now -lt $end)}
    Report '[OK] Configuration: config.json parsed and schedule times are valid'; Report ('[INFO] Schedule: ' + $config.start + ' -> ' + $config.end + '; currently ' + $(if($active){'ACTIVE'}else{'INACTIVE'}))
} catch { Report ('[FAIL ERROR] Configuration: ' + $_.Exception.Message); Problem 'config.json could not be parsed or schedule is invalid.' }
if(Test-Path $OverridePath){try{$until=[DateTime]::Parse((Get-Content $OverridePath -Raw -ErrorAction Stop)).ToUniversalTime();if([DateTime]::UtcNow -lt $until){$overrideActive=$true;Report ('[INFO] Override: ACTIVE until ' + $until.ToString('u'))}else{Report '[INFO] Override: inactive'}}catch{Report '[WARN ERROR] Override file could not be parsed'}}else{Report '[INFO] Override: inactive'}

$packet=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object CommandLine -like '*packet-filter.ps1*');$control=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object CommandLine -like '*ultra-mode.ps1*')
if($packet.Count){Report '[OK RUNNING] Packet filter process: RUNNING'}else{Report '[FAIL NOT RUNNING] Packet filter process: NOT RUNNING';Problem 'packet-filter.ps1 is not running.'}
if($control.Count){Report '[OK RUNNING] Control plane process: RUNNING'}else{Report '[FAIL NOT RUNNING] Control plane process: NOT RUNNING';Problem 'ultra-mode.ps1 is not running.'}

Report ''; Report 'DNS HEALTH'; Report '----------'
try {
    $dnsServers=@(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {$_.ServerAddresses} | ForEach-Object {$_.ServerAddresses})
    if($dnsServers.Count){Report ('[OK CONFIGURED] DNS servers: ' + ($dnsServers -join ', '))}else{Report '[FAIL] No IPv4 DNS servers configured';Problem 'No IPv4 DNS servers are configured.'}
} catch {Report ('[WARN ERROR] Could not query DNS server configuration: ' + $_.Exception.Message)}
foreach($name in @('youtube.com','www.youtube.com','ytimg.com','googlevideo.com','chatgpt.com','crushon.ai','windowsmcp.io','google.com')){if(DnsOK $name){Report ('[OK RESOLVED] DNS: '+$name)}else{Report ('[WARN UNRESOLVED] DNS: '+$name);if($name -eq 'google.com'){Problem 'General DNS resolution failed.'}}}

Report ''; Report 'WINDOWS FIREWALL HEALTH'; Report '-----------------------'
try {
    $profiles=@(Get-NetFirewallProfile -ErrorAction Stop)
    foreach($p in $profiles){if($p.Enabled){Report ('[OK ENABLED] Firewall profile: '+$p.Name+'; DefaultInbound='+$p.DefaultInboundAction+'; DefaultOutbound='+$p.DefaultOutboundAction)}else{Report ('[WARN DISABLED] Firewall profile: '+$p.Name);Problem ('Windows Firewall profile '+$p.Name+' is disabled.')}}
    $rules=@(Get-NetFirewallRule -ErrorAction Stop);Report ('[OK QUERY] Firewall rules visible: '+$rules.Count)
} catch {Report ('[WARN ERROR] Windows Firewall query failed: '+$_.Exception.Message);Problem 'Could not fully query Windows Firewall.'}

Report ''; Report 'WFP / BASE FILTERING ENGINE HEALTH'; Report '----------------------------------'
try {
    $bfe=Get-Service BFE -ErrorAction Stop
    if($bfe.Status -eq 'Running'){Report '[OK RUNNING] WFP Base Filtering Engine (BFE): RUNNING'}else{Report ('[FAIL NOT RUNNING] WFP Base Filtering Engine (BFE): '+$bfe.Status);Problem 'Windows Base Filtering Engine is not running.'}
    $mps=Get-Service MpsSvc -ErrorAction SilentlyContinue
    if($mps){Report ('[INFO] Windows Defender Firewall service (MpsSvc): '+$mps.Status)}
} catch {Report ('[WARN ERROR] WFP/BFE query failed: '+$_.Exception.Message);Problem 'Could not query the Windows Filtering Platform base service.'}

Report ''; Report 'ROUTING HEALTH'; Report '--------------'
try {
    $routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop)
    if($routes.Count){Report ('[OK FOUND] IPv4 default routes: '+$routes.Count);foreach($r in $routes){Report ('  ifIndex='+$r.ifIndex+' NextHop='+$r.NextHop+' Metric='+$r.RouteMetric)}}else{Report '[FAIL NOT FOUND] No IPv4 default route';Problem 'No IPv4 default route was found.'}
    $v6=@(Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue);Report ('[INFO] IPv6 default routes: '+$v6.Count)
} catch {Report ('[WARN ERROR] Routing query failed: '+$_.Exception.Message);Problem 'Could not query routing table.'}

Report ''; Report 'VPN / NETWORK ADAPTER HEALTH'; Report '----------------------------'
try {
    $adapters=@(Get-NetAdapter -ErrorAction Stop)
    $up=@($adapters|Where-Object Status -eq 'Up')
    Report ('[INFO] Network adapters UP: '+$up.Count)
    foreach($a in $up){Report ('[OK UP] '+$a.Name+' | Status='+$a.Status+' | InterfaceIndex='+$a.ifIndex+' | LinkSpeed='+$a.LinkSpeed)}
    $vpn=@($adapters|Where-Object {$_.Name -match '(?i)proton|vpn|wireguard|tun|tap'})
    if($vpn.Count){foreach($v in $vpn){Report ('[INFO VPN] VPN-like adapter: '+$v.Name+' | Status='+$v.Status+' | InterfaceIndex='+$v.ifIndex)}}else{Report '[INFO] No VPN-like adapter name detected.'}
    $proton=@($adapters|Where-Object {$_.Name -match '(?i)proton'})
    if($proton.Count -and @($proton|Where-Object Status -eq 'Up').Count){Report '[OK VPN] ProtonVPN-related adapter appears UP.'}elseif($proton.Count){Report '[WARN VPN] ProtonVPN-related adapter exists but is not UP.'}else{Report '[INFO VPN] ProtonVPN adapter not detected.'}
} catch {Report ('[WARN ERROR] Adapter/VPN query failed: '+$_.Exception.Message);Problem 'Could not fully query network adapters/VPN state.'}
try {
    $vpnRoutes=@(Get-NetRoute -ErrorAction SilentlyContinue|Where-Object {$_.NextHop -eq '0.0.0.0' -and $_.DestinationPrefix -eq '0.0.0.0/0'})
    if($vpnRoutes.Count){Report ('[INFO VPN] Default-route interfaces: '+(($vpnRoutes|ForEach-Object {$_.ifIndex}) -join ', '))}
} catch {}

Report ''; Report 'HOSTS / PROXY HEALTH'; Report '--------------------'
$hostsPath='C:\Windows\System32\drivers\etc\hosts'
if(Test-Path $hostsPath){$hits=@(Get-Content $hostsPath -ErrorAction SilentlyContinue|Where-Object {$_ -match '(youtube|youtu\.be|ytimg|googlevideo|chatgpt|crushon)' -and $_ -notmatch '^\s*#'});if($hits.Count -eq 0){Report '[OK CLEAN] Hosts: no Untrapped target entries found'}else{Report ('[WARN ENTRIES FOUND] Hosts: '+$hits.Count+' relevant entry/entries found');$hits|ForEach-Object{Report ('  '+$_)};Problem 'Relevant Hosts entries exist outside Untrapped.'}}else{Report '[WARN] Hosts file not found.'}
try{$proxy=@(netsh winhttp show proxy 2>&1);Report 'WinHTTP proxy:';$proxy|ForEach-Object{Report ('  '+[string]$_)}}catch{}

Report ''; Report 'POLICY / ACTUAL STATE CHECK'; Report '--------------------------'
$scheduledBlock=Get-ExpectedBlock $active $overrideActive
Report ('[INFO] Policy says YouTube + ChatGPT SHOULD be '+$(if($scheduledBlock){'BLOCKED'}else{'ALLOWED'})+' right now.')
if($overrideActive){Report '[INFO] Override is active; scheduled YouTube/ChatGPT blocking is intentionally bypassed.'}
$ytActual=TestTarget443 'www.youtube.com' $scheduledBlock;$chatActual=TestTarget443 'chatgpt.com' $scheduledBlock
$needsRepair=(($scheduledBlock -and (-not $ytActual -or -not $chatActual))-or((-not $scheduledBlock)-and(($ytActual -eq $false)-or($chatActual -eq $false))))
if($needsRepair){Report '';Report '[REPAIR NEEDED] YouTube/ChatGPT actual reachability disagrees with configured policy.';Repair-UntrappedFilter;Start-Sleep -Seconds 2;$after=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object CommandLine -like '*packet-filter.ps1*');if($after.Count){Report '[OK REPAIR VERIFIED] Packet filter process is running after repair attempt.'}else{Report '[FAIL REPAIR VERIFIED] Packet filter process is still not running after repair attempt.'}}else{Report '[OK POLICY MATCH] YouTube and ChatGPT actual state matches schedule/override.'}
$alwaysBlocked=($config -and $config.alwaysBlockedDomains -and @($config.alwaysBlockedDomains).Count -gt 0);TestTarget443 'www.crushon.ai' $alwaysBlocked

Report '';Report '============================================================';Report ' DIAGNOSIS';Report '============================================================'
$unique=@($problems|Sort-Object -Unique)
if($unique.Count -eq 0){Report '[HEALTHY] No obvious Untrapped, firewall, WFP, DNS, routing, VPN, Hosts, or blocking fault was detected.'}else{foreach($p in $unique){Report ('[CAUSE] '+$p)}}
Report ''
Report 'IMPORTANT: This diagnostic is observational except for Untrapped self-healing.'
Report 'It may restart Untrapped packet-filter.ps1 when policy and actual blocking disagree.'
Report 'It does NOT modify Windows Firewall, WFP, DNS, routing, VPN, adapters, proxy, Hosts, or the override.'
Report ''
$lines|Set-Content -Path $ReportPath -Encoding UTF8
try { Start-Process notepad.exe -ArgumentList $ReportPath -ErrorAction SilentlyContinue } catch {}
