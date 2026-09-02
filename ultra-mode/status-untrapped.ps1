# Untrapped Ultra Mode - Health Diagnostic
#
# EDITOR NOTE: THE DIAGNOSIS CONTRACT IS IMMUTABLE.
# Future editors: DO NOT EDIT, REMOVE, REORDER, OR CHANGE the DIAGNOSIS CONTRACT
# section below or its severity/exit semantics. Improve collection/repair mechanics
# outside that section only.
$ErrorActionPreference='Continue'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$SelfPath=$MyInvocation.MyCommand.Path
$ReportPath=Join-Path $Root 'diagnostic-latest.txt'
$RepairPath=Join-Path $Root 'self-repair.ps1'
$RepoBase='https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/'
$ExtensionFiles=@('manifest.json','background.js','content.js','popup.html','popup.js','bootstrap.bundle.min.js')
$CoreFiles=@('WinDivert.dll','WinDivert64.sys','config.json','packet-filter.ps1','ultra-mode.ps1','status-untrapped.ps1','self-repair.ps1')
function Get-RemoteText([string]$p){$u=$RepoBase+$p+'?cb='+[DateTime]::UtcNow.Ticks;Write-Host ('[UPDATE] Downloading canonical '+$p+' ...');return (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content}
function SameRemote([string]$p,[string]$local){try{if(!(Test-Path $local)){return $false};return ([IO.File]::ReadAllText($local)-ceq(Get-RemoteText $p))}catch{return $false}}
function ValidScript([string]$t){try{[void][scriptblock]::Create($t);return $true}catch{return $false}}
function Out([string]$s){Write-Host $s;[void]$Lines.Add($s)}
function Problem([string]$s){if(!($Problems -contains $s)){[void]$Problems.Add($s)}}
function TestHttps([string]$h){try{Write-Host ('[CHECK] Testing HTTPS '+$h+' ...');return [bool](Test-NetConnection $h -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded}catch{return $false}}

# ==================== AUTO-UPDATE ====================
$UpdateState='UNKNOWN';$UpdateDetail='';Write-Host '';Write-Host '=== AUTO-UPDATE: BEGIN ===';Write-Host '[UPDATE] Checking TLS/network access to canonical GitHub source.'
try{
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $remote=Get-RemoteText 'ultra-mode/status-untrapped.ps1';$local=[IO.File]::ReadAllText($SelfPath)
 Write-Host ('[UPDATE] Local bytes: '+$local.Length+' | Canonical bytes: '+$remote.Length)
 if($remote -ne $local){
  Write-Host '[UPDATE] DIFFERENCE DETECTED. Validating downloaded diagnostic before touching local file.'
  if($remote.Length -lt 1500 -or !(ValidScript $remote)){throw 'Downloaded diagnostic failed validation; local copy was preserved.'}
  Write-Host '[UPDATE] Validation passed. Backing up current diagnostic.'
  [IO.File]::Copy($SelfPath,$SelfPath+'.preupdate.bak',$true)
  Write-Host '[UPDATE] Writing canonical diagnostic to local disk.'
  [IO.File]::WriteAllText($SelfPath,$remote,(New-Object Text.UTF8Encoding($false)))
  $verify=[IO.File]::ReadAllText($SelfPath);if($verify -cne $remote){throw 'Diagnostic post-write verification failed.'}
  Write-Host '[UPDATE] Post-write verification passed.'
  $UpdateState='UPDATED';$UpdateDetail='Downloaded, validated, backed up, installed, and post-write verified a newer diagnostic from canonical GitHub source.'
  $env:UNTRAPPED_STATUS_UPDATED='1';Write-Host '[UPDATE] Restarting the diagnostic so the newly installed code performs the health scan.'
  $child=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SelfPath) -WorkingDirectory $Root -Wait -PassThru
  exit $child.ExitCode
 }
 $UpdateState=if($env:UNTRAPPED_STATUS_UPDATED){'UPDATED THIS RUN'}else{'ALREADY CURRENT'}
 $UpdateDetail=if($UpdateState -eq 'ALREADY CURRENT'){'Local diagnostic exactly matches canonical GitHub source; no diagnostic update was needed.'}{'New diagnostic is now running after a verified update.'}
 Write-Host ('[UPDATE] '+$UpdateState);Write-Host ('[UPDATE] '+$UpdateDetail)
}catch{$UpdateState='FAILED';$UpdateDetail='Diagnostic auto-update failed: '+$_.Exception.Message;Write-Host ('[UPDATE] FAILED: '+$_.Exception.Message);Problem 'Diagnostic auto-update failed.'}

$Lines=New-Object 'System.Collections.Generic.List[string]';$Problems=New-Object 'System.Collections.Generic.List[string]'
Out '========================================';Out '       UNTRAPPED HEALTH DASHBOARD';Out '========================================';Out ('Time: '+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))

# POLICY
Out '';Out '=== POLICY CHECKS: BEGIN ===';$config=$null;$scheduled=$false;$override=$false
try{Write-Host '[POLICY] Reading config.json.';$config=Get-Content (Join-Path $Root 'config.json') -Raw|ConvertFrom-Json;$start=[TimeSpan]::Parse([string]$config.start);$end=[TimeSpan]::Parse([string]$config.end);$now=(Get-Date).TimeOfDay;$inWindow=if($start-eq$end){$true}elseif($start-lt$end){$now-ge$start-and$now-lt$end}else{$now-ge$start-or$now-lt$end};if(Test-Path (Join-Path $Root 'override-until.txt')){Write-Host '[POLICY] Checking override-until.txt.';try{$until=[DateTime]::Parse((Get-Content (Join-Path $Root 'override-until.txt') -Raw)).ToUniversalTime();$override=[DateTime]::UtcNow-lt$until}catch{Write-Host '[POLICY] Override file exists but could not be parsed.'}};$scheduled=[bool]($config.enabled-and$inWindow-and-not$override);Write-Host ('[POLICY] Blocking schedule active: '+$scheduled)}catch{Problem 'Config is invalid or unreadable.';Write-Host '[POLICY] FAILED to read/parse configuration.'}
$yt=TestHttps 'www.youtube.com';$chat=TestHttps 'chatgpt.com';$crush=TestHttps 'www.crushon.ai';$expectedReachable=-not$scheduled;$ytOK=$yt-eq$expectedReachable;$chatOK=$chat-eq$expectedReachable;$crushOK=-not$crush;Out 'POLICY';Out ('  YouTube : '+$(if($ytOK){if($scheduled){'BLOCKED OK'}else{'ALLOWED OK'}}else{'WRONG'}));Out ('  ChatGPT : '+$(if($chatOK){if($scheduled){'BLOCKED OK'}else{'ALLOWED OK'}}else{'WRONG'}));Out ('  CrushOn : '+$(if($crushOK){'BLOCKED OK'}else{'REACHABLE WRONG'}));if(!$ytOK){Problem 'YouTube does not match the configured policy.'};if(!$chatOK){Problem 'ChatGPT does not match the configured policy.'};if(!$crushOK){Problem 'CrushOn does not match the configured policy.'};Out '=== POLICY CHECKS: END ==='

# CORE
Out '';Out '=== UNTRAPPED CORE CHECKS: BEGIN ===';Write-Host '[CORE] Checking running processes and every required file.';$packet=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine-like'*packet-filter.ps1*'});$control=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine-like'*ultra-mode.ps1*'});$missing=@($CoreFiles|Where-Object{!(Test-Path(Join-Path $Root $_))});Out '';Out 'UNTRAPPED CORE';Out ('  Packet filter : '+$(if($packet.Count){'RUNNING OK'}else{'STOPPED'}));Out ('  Control plane : '+$(if($control.Count){'RUNNING OK'}else{'STOPPED'}));Out ('  Required files: '+($CoreFiles.Count-$missing.Count)+'/'+$CoreFiles.Count);if(!$packet.Count){Problem 'Packet filter is not running.'};if(!$control.Count){Problem 'Control plane is not running.'};if($missing.Count){Problem 'Required Untrapped files are missing: '+($missing-join', ')};Out '=== UNTRAPPED CORE CHECKS: END ==='

# EXTENSION SOURCE
$sourceBad=@();Out '';Out '=== EXTENSION SOURCE CHECKS: BEGIN ===';foreach($f in $ExtensionFiles){$p=Join-Path (Split-Path -Parent $Root) $f;Write-Host ('[EXTENSION SOURCE] Comparing '+$f+' with canonical GitHub source.');if(SameRemote $f $p){Out ('  '+$f+' : CURRENT OK')}else{Out ('  '+$f+' : DIFFERENT/MISSING');$sourceBad+=$f}};if($sourceBad.Count){Problem 'Untrapped Enhanced extension source needs repair.'};Out '=== EXTENSION SOURCE CHECKS: END ==='

# BRAVE EXTENSION
$installed=@();Out '';Out '=== BRAVE EXTENSION DISCOVERY: BEGIN ===';$userData=Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data';Write-Host ('[BRAVE] Searching '+$userData+' for installed Untrapped manifests.');if(Test-Path $userData){$profiles=@(Get-ChildItem $userData -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name-eq'Default'-or$_.Name-like'Profile *'});foreach($profile in $profiles){$extDir=Join-Path $profile.FullName 'Extensions';if(!(Test-Path $extDir)){continue};foreach($idDir in @(Get-ChildItem $extDir -Directory -ErrorAction SilentlyContinue)){foreach($verDir in @(Get-ChildItem $idDir.FullName -Directory -ErrorAction SilentlyContinue)){$m=Join-Path $verDir.FullName'manifest.json';if(Test-Path $m){try{$j=Get-Content $m -Raw|ConvertFrom-Json;if([string]$j.name-eq'Untrapped'){$installed+=$verDir.FullName}}catch{}}}}}};$installed=@($installed|Select-Object-Unique);Out 'BRAVE EXTENSION';if(!$installed.Count){Out '  Installed Untrapped copy: NOT FOUND';Problem 'Installed Brave Untrapped extension could not be located.'}else{foreach($d in $installed){$bad=@();Out ('  Found: '+$d);foreach($f in $ExtensionFiles){Write-Host ('[BRAVE] Comparing installed '+$f+' against canonical source.');if(!(SameRemote $f (Join-Path $d $f))){$bad+=$f}};if($bad.Count){Out ('  Installed copy: '+$bad.Count+' file(s) differ');Problem 'Installed Brave Untrapped extension differs from GitHub.'}else{Out '  Installed copy: CURRENT OK'}}};Out '=== BRAVE EXTENSION DISCOVERY: END ==='

# NETWORK / HOSTS / PROXY / VPN / WFP
Out '';Out '=== NETWORK/SYSTEM CHECKS: BEGIN ===';$adapters=@(Get-NetAdapter -ErrorAction SilentlyContinue|Where-Object Status-eq'Up');Write-Host ('[NETWORK] Active adapters found: '+$adapters.Count);$badIP=$false;foreach($a in $adapters){Write-Host ('[NETWORK] Inspecting adapter '+$a.Name+' (ifIndex '+$a.ifIndex+').');$c=Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue;if(!$c.IPv4Address-and!$c.IPv6Address){$badIP=$true}};$dnsOK=$false;try{Write-Host '[DNS] Resolving google.com.';$dnsOK=@(Resolve-DnsName 'google.com'-DnsOnly-ErrorAction Stop|Where-Object IPAddress).Count-gt 0}catch{};$httpsOK=TestHttps'www.google.com';$routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0'-ErrorAction SilentlyContinue);$bfeOK=$false;try{Write-Host '[WFP] Checking BFE service.';$bfeOK=(Get-Service BFE-ErrorAction Stop).Status-eq'Running'}catch{};$hosts=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts';$hostHits=@();if(Test-Path $hosts){Write-Host '[HOSTS] Scanning hosts file for target entries.';$hostHits=@(Get-Content $hosts|Where-Object{$_-match'(?i)(youtube|youtu\.be|chatgpt|crushon)'}|Where-Object{$_-notmatch'^\s*#'})};$proxy='DIRECT';try{Write-Host '[PROXY] Reading WinHTTP proxy configuration.';$p=netsh winhttp show proxy 2>$null;if($p-match'Proxy Server'){if($p-match'Direct access'){ $proxy='DIRECT'}else{$proxy='CONFIGURED'}}}catch{};$tunnels=@($adapters|Where-Object{$_.InterfaceDescription-match'(?i)(proton|speedify|vpn|wireguard|tun|tap)'});Out '';Out 'NETWORK';Out ('  Internet : '+$(if($httpsOK){'OK'}else{'FAIL'}));Out ('  DNS      : '+$(if($dnsOK){'OK'}else{'FAIL'}));Out ('  IP       : '+$(if(!$badIP-and$adapters.Count){'OK'}else{'CHECK'}));Out ('  Routes   : '+$(if($routes.Count){'OK'}else{'FAIL'}));Out ('  WFP/BFE  : '+$(if($bfeOK){'OK'}else{'FAIL'}));Out ('  Hosts    : '+$(if(!$hostHits.Count){'CLEAN OK'}else{'TARGET ENTRIES'}));Out ('  Proxy    : '+$proxy);Out ('  VPN/tunnel adapters: '+$tunnels.Count);if(!$httpsOK){Problem 'General HTTPS failed.'};if(!$dnsOK){Problem 'General DNS resolution failed.'};if($badIP){Problem 'An active network adapter has no IP address.'};if(!$routes.Count){Problem 'No IPv4 default route exists.'};if(!$bfeOK){Problem 'Windows Base Filtering Engine is not running.'};if($hostHits.Count){Problem 'Hosts file contains relevant target entries.'};Out '=== NETWORK/SYSTEM CHECKS: END ==='

# GITHUB
Out '';Out '=== GITHUB AVAILABILITY CHECK: BEGIN ===';try{Write-Host '[GITHUB] Requesting github.com.';[void](Invoke-WebRequest 'https://github.com'-UseBasicParsing-TimeoutSec 15-ErrorAction Stop);Out '  GitHub: ACCESSIBLE OK'}catch{Out '  GitHub: UNREACHABLE';Problem 'GitHub could not be reached.'};Out '=== GITHUB AVAILABILITY CHECK: END ==='

# AUTO-REPAIR
$needsRepair=($Problems.Count-gt 0-or$sourceBad.Count-gt 0);$RepairState='NOT NEEDED';$RepairExit='N/A';Out '';Out '=== AUTO-REPAIR: BEGIN ===';if($needsRepair-and(Test-Path $RepairPath)){Out '[AUTO-REPAIR] REQUIRED';Out '[AUTO-REPAIR] Cause(s):';foreach($p in @($Problems)){Out ('  -> '+$p)};Out '[AUTO-REPAIR] Launching elevated canonical repair engine.';try{$r=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$RepairPath) -WorkingDirectory $Root -Verb RunAs -Wait -PassThru -ErrorAction Stop;$RepairExit=[string]$r.ExitCode;Write-Host ('[AUTO-REPAIR] Repair process returned exit code '+$RepairExit+'.');if($r.ExitCode-eq0){$RepairState='COMPLETED'}else{$RepairState='FAILED';Problem 'Self-repair reported failure.'}}catch{$RepairState='FAILED TO START';$RepairExit='N/A';Problem 'Self-repair could not be started.';Write-Host ('[AUTO-REPAIR] START FAILED: '+$_.Exception.Message)}}elseif($needsRepair){$RepairState='UNAVAILABLE';Problem 'Self-repair engine is missing.';Out '[AUTO-REPAIR] REQUIRED but repair engine is unavailable.'}else{Out '[AUTO-REPAIR] No repair required.'};Out ('[AUTO-REPAIR] State: '+$RepairState);Out ('[AUTO-REPAIR] Exit code: '+$RepairExit);Out '=== AUTO-REPAIR: END ==='

# POST-REPAIR VERIFICATION
$PostRepair='NOT RUN';Out '';Out '=== POST-REPAIR VERIFICATION: BEGIN ===';if($needsRepair-and$RepairState-eq'COMPLETED'){Write-Host '[VERIFY] Waiting briefly for repaired processes to settle.';Start-Sleep -Seconds 2;$coreAfter=@($CoreFiles|Where-Object{!(Test-Path(Join-Path $Root $_))});$srcAfter=@($ExtensionFiles|Where-Object{!(SameRemote $_ (Join-Path (Split-Path -Parent $Root) $_))});$packetAfter=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine-like'*packet-filter.ps1*'});$controlAfter=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine-like'*ultra-mode.ps1*'});Write-Host ('[VERIFY] Missing core files after repair: '+$coreAfter.Count);Write-Host ('[VERIFY] Extension-source mismatches after repair: '+$srcAfter.Count);Write-Host ('[VERIFY] Packet filter processes after repair: '+$packetAfter.Count);Write-Host ('[VERIFY] Control plane processes after repair: '+$controlAfter.Count);if(!$coreAfter.Count-and!$srcAfter.Count-and$packetAfter.Count-and$controlAfter.Count){$PostRepair='CORE/SOURCE/PROCESS STATE VERIFIED'}else{$PostRepair='RECHECK NEEDED';Problem 'Post-repair verification did not confirm the complete Untrapped core/source state.'}}else{Out '[VERIFY] Not run because no completed repair occurred.'};Out ('[VERIFY] Result: '+$PostRepair);Out '=== POST-REPAIR VERIFICATION: END ==='

# ==================== DIAGNOSIS CONTRACT: DO NOT EDIT ====================
# Stable diagnosis semantics. DO NOT EDIT THIS SECTION.
$Diagnosis='ALL CLEAR';if($Problems.Count){$Diagnosis='ATTENTION NEEDED'}elseif($UpdateState-eq'UPDATED THIS RUN'){$Diagnosis='HEALTHY - DIAGNOSTIC UPDATED'}
# ================== END DIAGNOSIS CONTRACT ==================

# CONDENSED VIEW
Out '';Out '========================================';Out 'CONDENSED DIAGNOSIS';Out ('  OVERALL: '+$Diagnosis);Out ('  Auto-update : '+$UpdateState);Out ('  Auto-repair : '+$RepairState);Out ('  Repair verify: '+$PostRepair);Out ('  Issues      : '+$Problems.Count);if(!$Problems.Count){Out '  Result      : Untrapped is healthy and no unresolved faults were detected.'}else{foreach($p in $Problems){Out ('  ! '+$p)}}Out '========================================'

# DETAILED VIEW
Out '';Out 'DETAILED DIAGNOSTIC';Out ('  Diagnostic update detail: '+$UpdateDetail);Out ('  Auto-repair detail: '+$(if($needsRepair){'Repair was triggered because one or more health checks failed or an owned component differed from canonical source.'}else{'No repair was triggered because health checks passed and owned source matched canonical state.'}));Out ('  Auto-repair exit code: '+$RepairExit);Out ('  Post-repair verification: '+$PostRepair);Out ('  Extension source mismatches before repair: '+$(if($sourceBad.Count){$sourceBad-join', '}else{'NONE'}));Out ('  Brave copies found: '+$installed.Count);Out ('  Active adapters: '+$adapters.Count);Out ('  Default routes: '+$routes.Count);Out ('  Relevant Hosts entries: '+$hostHits.Count);Out ('  VPN/tunnel adapters: '+$tunnels.Count);Out ('  WinHTTP proxy: '+$proxy);Out ('  Override active: '+$override);Out ('  Scheduled blocking window: '+$scheduled);Out ('  Canonical source: '+$RepoBase);Out '  Repair scope: Untrapped-owned files/processes only; Windows network stack is not altered.';Out '  Next run: this diagnostic will again verify its own canonical version, source files, installed extension state, core processes, policy, and network prerequisites.'
Out '';Out 'STATUS';Out ('  '+$Diagnosis);Out ('  Auto-update: '+$UpdateState);Out ('  Auto-repair: '+$RepairState);Out ('  Extension auto-check: ENABLED');Out ('  Extension repair: ENABLED');Out '  Automatic changes are limited to Untrapped-owned components.'
$Lines|Set-Content $ReportPath -Encoding UTF8
if($needsRepair-or$UpdateState-eq'UPDATED'-or$UpdateState-eq'UPDATED THIS RUN'){try{Start-Process notepad.exe -ArgumentList $ReportPath -ErrorAction SilentlyContinue}catch{}}
if($Problems.Count){exit 1}else{exit 0}
