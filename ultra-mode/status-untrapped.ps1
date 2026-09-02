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
function Get-RemoteText([string]$p){$u=$RepoBase+$p+'?cb='+[DateTime]::UtcNow.Ticks;return (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content}
function SameRemote([string]$p,[string]$local){try{if(!(Test-Path $local)){return $false};return ([IO.File]::ReadAllText($local)-ceq(Get-RemoteText $p))}catch{return $false}}
function ValidScript([string]$t){try{[void][scriptblock]::Create($t);return $true}catch{return $false}}
function Out([string]$s){Write-Host $s;[void]$Lines.Add($s)}
function Problem([string]$s){if(!($Problems -contains $s)){[void]$Problems.Add($s)}}
function TestHttps([string]$h){try{return [bool](Test-NetConnection $h -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded}catch{return $false}}

# ==================== AUTO-UPDATE ====================
$UpdateState='UNKNOWN';$UpdateDetail=''
try{
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $remote=Get-RemoteText 'ultra-mode/status-untrapped.ps1';$local=[IO.File]::ReadAllText($SelfPath)
 if($remote -ne $local){
  if($remote.Length -lt 1500 -or !(ValidScript $remote)){throw 'Downloaded diagnostic failed validation; local copy was preserved.'}
  [IO.File]::Copy($SelfPath,$SelfPath+'.preupdate.bak',$true)
  [IO.File]::WriteAllText($SelfPath,$remote,(New-Object Text.UTF8Encoding($false)))
  $UpdateState='UPDATED';$UpdateDetail='Downloaded, validated, backed up, and installed a newer diagnostic from canonical GitHub source.'
  $env:UNTRAPPED_STATUS_UPDATED='1'
  $child=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SelfPath) -WorkingDirectory $Root -Wait -PassThru
  exit $child.ExitCode
 }
 $UpdateState=if($env:UNTRAPPED_STATUS_UPDATED){'UPDATED THIS RUN'}else{'ALREADY CURRENT'}
 $UpdateDetail=if($UpdateState -eq 'ALREADY CURRENT'){'Local diagnostic exactly matches canonical GitHub source; no diagnostic update was needed.'}{'New diagnostic is now running after update.'}
}catch{$UpdateState='FAILED';$UpdateDetail='Diagnostic auto-update failed: '+$_.Exception.Message;Problem 'Diagnostic auto-update failed.'}

$Lines=New-Object 'System.Collections.Generic.List[string]';$Problems=New-Object 'System.Collections.Generic.List[string]'
Out '========================================';Out '       UNTRAPPED HEALTH DASHBOARD';Out '========================================';Out ('Time: '+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))

# POLICY
$config=$null;$scheduled=$false;$override=$false
try{$config=Get-Content (Join-Path $Root 'config.json') -Raw|ConvertFrom-Json;$start=[TimeSpan]::Parse([string]$config.start);$end=[TimeSpan]::Parse([string]$config.end);$now=(Get-Date).TimeOfDay;$inWindow=if($start-eq$end){$true}elseif($start-lt$end){$now-ge$start-and$now-lt$end}else{$now-ge$start-or$now-lt$end};if(Test-Path (Join-Path $Root 'override-until.txt')){try{$until=[DateTime]::Parse((Get-Content (Join-Path $Root 'override-until.txt') -Raw)).ToUniversalTime();$override=[DateTime]::UtcNow-lt$until}catch{}};$scheduled=[bool]($config.enabled-and$inWindow-and-not$override)}catch{Problem 'Config is invalid or unreadable.'}
$yt=TestHttps 'www.youtube.com';$chat=TestHttps 'chatgpt.com';$crush=TestHttps 'www.crushon.ai';$expectedReachable=-not$scheduled;$ytOK=$yt-eq$expectedReachable;$chatOK=$chat-eq$expectedReachable;$crushOK=-not$crush
Out '';Out 'POLICY';Out ('  YouTube : '+$(if($ytOK){if($scheduled){'BLOCKED OK'}else{'ALLOWED OK'}}else{'WRONG'}));Out ('  ChatGPT : '+$(if($chatOK){if($scheduled){'BLOCKED OK'}else{'ALLOWED OK'}}else{'WRONG'}));Out ('  CrushOn : '+$(if($crushOK){'BLOCKED OK'}else{'REACHABLE WRONG'}));if(!$ytOK){Problem 'YouTube does not match the configured policy.'};if(!$chatOK){Problem 'ChatGPT does not match the configured policy.'};if(!$crushOK){Problem 'CrushOn does not match the configured policy.'}

# CORE
$packet=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine-like'*packet-filter.ps1*'});$control=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine-like'*ultra-mode.ps1*'});$missing=@($CoreFiles|Where-Object{!(Test-Path(Join-Path $Root $_))});Out '';Out 'UNTRAPPED CORE';Out ('  Packet filter : '+$(if($packet.Count){'RUNNING OK'}else{'STOPPED'}));Out ('  Control plane : '+$(if($control.Count){'RUNNING OK'}else{'STOPPED'}));Out ('  Required files: '+($CoreFiles.Count-$missing.Count)+'/'+$CoreFiles.Count);if(!$packet.Count){Problem 'Packet filter is not running.'};if(!$control.Count){Problem 'Control plane is not running.'};if($missing.Count){Problem 'Required Untrapped files are missing: '+($missing-join', ')}

# EXTENSION SOURCE
$sourceBad=@();Out '';Out 'EXTENSION SOURCE';foreach($f in $ExtensionFiles){$p=Join-Path (Split-Path -Parent $Root) $f;if(SameRemote $f $p){Out ('  '+$f+' : CURRENT OK')}else{Out ('  '+$f+' : DIFFERENT/MISSING');$sourceBad+=$f}};if($sourceBad.Count){Problem 'Untrapped Enhanced extension source needs repair.'}

# BRAVE EXTENSION
$installed=@();$userData=Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data';if(Test-Path $userData){$profiles=@(Get-ChildItem $userData -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name-eq'Default'-or$_.Name-like'Profile *'});foreach($profile in $profiles){$extDir=Join-Path $profile.FullName 'Extensions';if(!(Test-Path $extDir)){continue};foreach($idDir in @(Get-ChildItem $extDir -Directory -ErrorAction SilentlyContinue)){foreach($verDir in @(Get-ChildItem $idDir.FullName -Directory -ErrorAction SilentlyContinue)){$m=Join-Path $verDir.FullName'manifest.json';if(Test-Path $m){try{$j=Get-Content $m -Raw|ConvertFrom-Json;if([string]$j.name-eq'Untrapped'){$installed+=$verDir.FullName}}catch{}}}}}};$installed=@($installed|Select-Object-Unique);Out '';Out 'BRAVE EXTENSION';if(!$installed.Count){Out '  Installed Untrapped copy: NOT FOUND';Problem 'Installed Brave Untrapped extension could not be located.'}else{foreach($d in $installed){$bad=@();Out ('  Found: '+$d);foreach($f in $ExtensionFiles){if(!(SameRemote $f (Join-Path $d $f))){$bad+=$f}};if($bad.Count){Out ('  Installed copy: '+$bad.Count+' file(s) differ');Problem 'Installed Brave Untrapped extension differs from GitHub.'}else{Out '  Installed copy: CURRENT OK'}}}

# NETWORK / HOSTS / PROXY / VPN / WFP
Out '';Out 'NETWORK';$adapters=@(Get-NetAdapter -ErrorAction SilentlyContinue|Where-Object Status-eq'Up');$badIP=$false;foreach($a in $adapters){$c=Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue;if(!$c.IPv4Address-and!$c.IPv6Address){$badIP=$true}};$dnsOK=$false;try{$dnsOK=@(Resolve-DnsName 'google.com'-DnsOnly-ErrorAction Stop|Where-Object IPAddress).Count-gt 0}catch{};$httpsOK=TestHttps'www.google.com';$routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0'-ErrorAction SilentlyContinue);$bfeOK=$false;try{$bfeOK=(Get-Service BFE-ErrorAction Stop).Status-eq'Running'}catch{};$hosts=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts';$hostHits=@();if(Test-Path $hosts){$hostHits=@(Get-Content $hosts|Where-Object{$_-match'(?i)(youtube|youtu\.be|chatgpt|crushon)'}|Where-Object{$_-notmatch'^\s*#'})};$proxy='DIRECT';try{$p=netsh winhttp show proxy 2>$null;if($p-match'Proxy Server'){if($p-match'Direct access'){ $proxy='DIRECT'}else{$proxy='CONFIGURED'}}}catch{};$tunnels=@($adapters|Where-Object{$_.InterfaceDescription-match'(?i)(proton|speedify|vpn|wireguard|tun|tap)'});Out ('  Internet : '+$(if($httpsOK){'OK'}else{'FAIL'}));Out ('  DNS      : '+$(if($dnsOK){'OK'}else{'FAIL'}));Out ('  IP       : '+$(if(!$badIP-and$adapters.Count){'OK'}else{'CHECK'}));Out ('  Routes   : '+$(if($routes.Count){'OK'}else{'FAIL'}));Out ('  WFP/BFE  : '+$(if($bfeOK){'OK'}else{'FAIL'}));Out ('  Hosts    : '+$(if(!$hostHits.Count){'CLEAN OK'}else{'TARGET ENTRIES'}));Out ('  Proxy    : '+$proxy);Out ('  VPN/tunnel adapters: '+$tunnels.Count);if(!$httpsOK){Problem 'General HTTPS failed.'};if(!$dnsOK){Problem 'General DNS resolution failed.'};if($badIP){Problem 'An active network adapter has no IP address.'};if(!$routes.Count){Problem 'No IPv4 default route exists.'};if(!$bfeOK){Problem 'Windows Base Filtering Engine is not running.'};if($hostHits.Count){Problem 'Hosts file contains relevant target entries.'}

# GITHUB
Out '';Out 'GITHUB';try{[void](Invoke-WebRequest 'https://github.com'-UseBasicParsing-TimeoutSec 15-ErrorAction Stop);Out '  GitHub: ACCESSIBLE OK'}catch{Out '  GitHub: UNREACHABLE';Problem 'GitHub could not be reached.'}

# AUTO-REPAIR
$preRepairProblems=@($Problems);$needsRepair=($Problems.Count-gt 0-or$sourceBad.Count-gt 0);$RepairState='NOT NEEDED';$RepairExit='N/A';if($needsRepair-and(Test-Path $RepairPath)){Out '';Out '[AUTO-REPAIR] REQUIRED';Out '[AUTO-REPAIR] Starting canonical repair engine...';try{$r=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$RepairPath) -WorkingDirectory $Root -Verb RunAs -Wait -PassThru -ErrorAction Stop;$RepairExit=[string]$r.ExitCode;if($r.ExitCode-eq0){$RepairState='COMPLETED'}else{$RepairState='FAILED';Problem 'Self-repair reported failure.'}}catch{$RepairState='FAILED TO START';$RepairExit='N/A';Problem 'Self-repair could not be started.'}}elseif($needsRepair){$RepairState='UNAVAILABLE';Problem 'Self-repair engine is missing.'}

# POST-REPAIR VERIFICATION
$PostRepair='NOT RUN';if($needsRepair-and$RepairState-eq'COMPLETED'){Start-Sleep -Seconds 2;$coreAfter=@($CoreFiles|Where-Object{!(Test-Path(Join-Path $Root $_))});$srcAfter=@($ExtensionFiles|Where-Object{!(SameRemote $_ (Join-Path (Split-Path -Parent $Root) $_))});$packetAfter=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine-like'*packet-filter.ps1*'});$controlAfter=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine-like'*ultra-mode.ps1*'});if(!$coreAfter.Count-and!$srcAfter.Count-and$packetAfter.Count-and$controlAfter.Count){$PostRepair='CORE/SOURCE VERIFIED'}else{$PostRepair='RECHECK NEEDED';Problem 'Post-repair verification did not confirm the complete Untrapped core/source state.'}}

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
