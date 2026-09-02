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

function Trace([string]$Stage,[string]$Message) {
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] [' + $Stage + '] ' + $Message
    Write-Host $line
    [void]$Lines.Add($line)
}
function Out([string]$s) { Trace 'INFO' $s }
function Problem([string]$s) { if ($s -and -not ($Problems -contains $s)) { [void]$Problems.Add($s) } }
function Get-RemoteText([string]$p) {
    $u = $RepoBase + $p + '?cb=' + [DateTime]::UtcNow.Ticks
    Trace 'DOWNLOAD' ('Starting canonical download: ' + $p)
    $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    Trace 'DOWNLOAD' ('Completed: ' + $p + ' (' + $r.Content.Length + ' bytes)')
    return [string]$r.Content
}
function ValidScript([string]$t) { try { [void][scriptblock]::Create($t); return $true } catch { return $false } }
function SameRemote([string]$p,[string]$local) {
    try {
        Trace 'CHECK' ('Comparing local file with canonical: ' + $p)
        if (-not (Test-Path -LiteralPath $local)) { Trace 'DIFF' ('Local file missing: ' + $local); return $false }
        $remote = Get-RemoteText $p
        $same = ([IO.File]::ReadAllText($local) -ceq $remote)
        if ($same) { Trace 'OK' ($p + ' matches canonical.') } else { Trace 'DIFF' ($p + ' differs from canonical.') }
        return $same
    } catch { Trace 'ERROR' ('Comparison failed for ' + $p + ': ' + $_.Exception.Message); return $false }
}
function TestHttps([string]$hostName) {
    try { Trace 'HTTPS' ('Testing ' + $hostName + ':443'); $r=Test-NetConnection -ComputerName $hostName -Port 443 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue; if($r.TcpTestSucceeded){Trace 'OK' ($hostName+':443 reachable')}else{Trace 'FAIL' ($hostName+':443 not reachable')}; return [bool]$r.TcpTestSucceeded } catch { Trace 'ERROR' ('HTTPS test failed for '+$hostName+': '+$_.Exception.Message); return $false }
}
function Find-BraveUntrapped {
    Trace 'BRAVE' 'Searching Brave profiles for installed Untrapped copies.'
    $found=New-Object 'System.Collections.Generic.List[string]'
    $userData=Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
    if(-not(Test-Path -LiteralPath $userData)){Trace 'BRAVE' 'Brave User Data directory not found.';return @()}
    $profiles=@(Get-ChildItem -LiteralPath $userData -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -eq 'Default' -or $_.Name -like 'Profile *'})
    Trace 'BRAVE' ('Profiles examined: '+$profiles.Count)
    foreach($profile in $profiles){$extDir=Join-Path $profile.FullName 'Extensions';if(-not(Test-Path -LiteralPath $extDir)){continue};foreach($idDir in @(Get-ChildItem -LiteralPath $extDir -Directory -ErrorAction SilentlyContinue)){foreach($verDir in @(Get-ChildItem -LiteralPath $idDir.FullName -Directory -ErrorAction SilentlyContinue)){$manifest=Join-Path $verDir.FullName 'manifest.json';if(-not(Test-Path -LiteralPath $manifest)){continue};try{$m=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json;if([string]$m.name -eq 'Untrapped'){[void]$found.Add($verDir.FullName);Trace 'BRAVE' ('Found Untrapped: '+$verDir.FullName)}}catch{}}}}
    $result=@($found|Sort-Object -Unique);Trace 'BRAVE' ('Installed Untrapped copies found: '+$result.Count);return $result
}

$UpdateState='UNKNOWN';$UpdateDetail='';$updatedThisRun=$false
Out ''
Out '=== AUTO-UPDATE: BEGIN ==='
Trace 'UPDATE' 'Checking canonical diagnostic without restarting the console.'
try {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $remote=Get-RemoteText 'ultra-mode/status-untrapped.ps1'
    $local=[IO.File]::ReadAllText($SelfPath)
    Trace 'UPDATE' ('Local characters: '+$local.Length+' | Canonical characters: '+$remote.Length)
    if($remote -ne $local){
        Trace 'UPDATE' 'DIFFERENCE DETECTED - validating canonical diagnostic.'
        if($remote.Length -lt 1500 -or -not(ValidScript $remote)){throw 'Downloaded diagnostic failed validation; local copy preserved.'}
        Copy-Item -LiteralPath $SelfPath -Destination ($SelfPath+'.preupdate.bak') -Force
        Trace 'UPDATE' 'Backup created.'
        [IO.File]::WriteAllText($SelfPath,$remote,(New-Object Text.UTF8Encoding($false)))
        if(([IO.File]::ReadAllText($SelfPath))-cne$remote){throw 'Diagnostic post-write verification failed.'}
        Trace 'UPDATE' 'Canonical diagnostic written and VERIFIED.'
        $updatedThisRun=$true
        $UpdateState='UPDATED THIS RUN'
        $UpdateDetail='A newer canonical diagnostic was installed and verified. This same PowerShell process continues using the verified run logic; no console restart occurs.'
        Trace 'UPDATE' 'Update complete. Continuing in THIS console - no restart.'
    }else{$UpdateState='ALREADY CURRENT';$UpdateDetail='Local diagnostic exactly matches canonical GitHub source; no update was needed.';Trace 'UPDATE' $UpdateState}
}catch{$UpdateState='FAILED';$UpdateDetail='Diagnostic auto-update failed: '+$_.Exception.Message;Trace 'UPDATE' ('FAILED: '+$_.Exception.Message);Problem 'Diagnostic auto-update failed.'}
Out '=== AUTO-UPDATE: END ==='

Out '';Out '========================================';Out '       UNTRAPPED HEALTH DASHBOARD';Out '========================================';Out ('Time: '+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Out '';Out '=== POLICY CHECKS: BEGIN ==='
$config=$null;$scheduled=$false;$override=$false
try{$config=Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw|ConvertFrom-Json;$start=[TimeSpan]::Parse([string]$config.start);$end=[TimeSpan]::Parse([string]$config.end);$now=(Get-Date).TimeOfDay;if($start -eq $end){$inWindow=$true}elseif($start -lt $end){$inWindow=$now -ge $start -and $now -lt $end}else{$inWindow=$now -ge $start -or $now -lt $end};$overrideFile=Join-Path $Root 'override-until.txt';if(Test-Path -LiteralPath $overrideFile){try{$until=[DateTime]::Parse((Get-Content -LiteralPath $overrideFile -Raw)).ToUniversalTime();$override=[DateTime]::UtcNow -lt $until}catch{Trace 'POLICY' 'Override file exists but could not be parsed.'}};$scheduled=[bool]($config.enabled -and $inWindow -and -not $override);Trace 'POLICY' ('Blocking schedule active: '+$scheduled+' | Override active: '+$override)}catch{Problem 'Config is invalid or unreadable.';Trace 'ERROR' 'FAILED to read/parse configuration.'}
$yt=TestHttps 'www.youtube.com';$chat=TestHttps 'chatgpt.com';$crush=TestHttps 'www.crushon.ai';$expectedReachable=-not$scheduled;$ytOK=($yt -eq $expectedReachable);$chatOK=($chat -eq $expectedReachable);$crushOK=-not$crush
Out 'POLICY';Out ('  YouTube : '+$(if($ytOK){if($scheduled){'BLOCKED OK'}else{'ALLOWED OK'}}else{'WRONG'}));Out ('  ChatGPT : '+$(if($chatOK){if($scheduled){'BLOCKED OK'}else{'ALLOWED OK'}}else{'WRONG'}));Out ('  CrushOn : '+$(if($crushOK){'BLOCKED OK'}else{'REACHABLE WRONG'}));if(-not$ytOK){Problem 'YouTube does not match the configured policy.'};if(-not$chatOK){Problem 'ChatGPT does not match the configured policy.'};if(-not$crushOK){Problem 'CrushOn does not match the configured policy.'};Out '=== POLICY CHECKS: END ==='

Out '';Out '=== UNTRAPPED CORE CHECKS: BEGIN ===';Trace 'CORE' 'Checking required files and running processes.'
$packet=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -like '*packet-filter.ps1*'});$control=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -like '*ultra-mode.ps1*'});$missing=@($CoreFiles|Where-Object{-not(Test-Path -LiteralPath (Join-Path $Root $_))});$coreBad=@();foreach($f in $CoreTextFiles){if(-not(SameRemote ('ultra-mode/'+$f) (Join-Path $Root $f))){$coreBad+=$f}}
Out 'UNTRAPPED CORE';Out ('  Packet filter : '+$(if($packet.Count){'RUNNING OK'}else{'STOPPED'}));Out ('  Control plane : '+$(if($control.Count){'RUNNING OK'}else{'STOPPED'}));Out ('  Required files: '+($CoreFiles.Count-$missing.Count)+'/'+$CoreFiles.Count);Out ('  Canonical mismatches: '+$(if($coreBad.Count){$coreBad -join ', '}else{'NONE'}));if(-not$packet.Count){Problem 'Packet filter is not running.'};if(-not$control.Count){Problem 'Control plane is not running.'};if($missing.Count){Problem ('Required Untrapped files are missing: '+($missing -join ', '))};if($coreBad.Count){Problem 'Untrapped core source differs from canonical GitHub.'};Out '=== UNTRAPPED CORE CHECKS: END ==='

Out '';Out '=== EXTENSION SOURCE CHECKS: BEGIN ===';$sourceBad=@();foreach($f in $ExtensionFiles){if(-not(SameRemote $f (Join-Path $Parent $f))){$sourceBad+=$f}};Out ('  Extension source mismatches: '+$(if($sourceBad.Count){$sourceBad -join ', '}else{'NONE'}));if($sourceBad.Count){Problem 'Untrapped Enhanced extension source needs repair.'};Out '=== EXTENSION SOURCE CHECKS: END ==='

Out '';Out '=== BRAVE EXTENSION DISCOVERY: BEGIN ===';$installed=Find-BraveUntrapped;if(-not$installed.Count){Out '  Installed Untrapped copy: NOT FOUND';Problem 'Installed Brave Untrapped extension could not be located.'}else{foreach($d in $installed){$bad=@();foreach($f in $ExtensionFiles){if(-not(SameRemote $f (Join-Path $d $f))){$bad+=$f}};if($bad.Count){Out ('  Installed copy: '+$bad.Count+' file(s) differ');Problem 'Installed Brave Untrapped extension differs from GitHub.'}else{Out '  Installed copy: CURRENT OK'}}};Out '=== BRAVE EXTENSION DISCOVERY: END ==='

Out '';Out '=== NETWORK/SYSTEM CHECKS: BEGIN ===';$adapters=@(Get-NetAdapter -ErrorAction SilentlyContinue|Where-Object{$_.Status -eq 'Up'});Trace 'NETWORK' ('Active adapters found: '+$adapters.Count);$routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue);$dnsOK=$false;try{Trace 'DNS' 'Resolving google.com.';$dnsOK=@((Resolve-DnsName 'google.com' -DnsOnly -ErrorAction Stop|Where-Object{$_.IPAddress})).Count -gt 0;if($dnsOK){Trace 'OK' 'DNS resolution succeeded.'}else{Trace 'FAIL' 'DNS returned no IP.'}}catch{Trace 'FAIL' ('DNS resolution failed: '+$_.Exception.Message)};$httpsOK=TestHttps 'www.google.com';$bfeOK=$false;try{$svc=Get-Service -Name BFE -ErrorAction Stop;$bfeOK=$svc.Status -eq 'Running';Trace $(if($bfeOK){'OK'}else{'FAIL'}) ('BFE status: '+$svc.Status)}catch{Trace 'ERROR' 'Could not query BFE.'};$hosts=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts';$hostHits=@();if(Test-Path -LiteralPath $hosts){Trace 'HOSTS' 'Scanning hosts file.';$hostHits=@(Get-Content -LiteralPath $hosts|Where-Object{$_ -match '(?i)(youtube|youtu\.be|chatgpt|crushon)' -and $_ -notmatch '^\s*#'})};$proxy='UNKNOWN';try{$proxyOutput=netsh winhttp show proxy 2>$null;if($proxyOutput -match 'Direct access'){$proxy='DIRECT'}elseif($proxyOutput -match 'Proxy Server'){$proxy='CONFIGURED'}}catch{};Out 'NETWORK / SYSTEM';Out ('  Active adapters: '+$adapters.Count);Out ('  Default routes: '+$routes.Count);Out ('  DNS: '+$(if($dnsOK){'OK'}else{'FAILED'}));Out ('  Google HTTPS: '+$(if($httpsOK){'OK'}else{'FAILED'}));Out ('  Hosts target entries: '+$hostHits.Count);Out ('  WinHTTP proxy: '+$proxy);Out ('  BFE/WFP prerequisite: '+$(if($bfeOK){'RUNNING'}else{'NOT RUNNING/UNKNOWN'}));if($adapters.Count -gt 0){if(-not$dnsOK){Problem 'External DNS resolution is failing.'};if(-not$httpsOK){Problem 'External HTTPS connectivity to Google is failing.'}};if($hostHits.Count){Problem 'Relevant Hosts entries were found.'};if(-not$bfeOK){Problem 'Base Filtering Engine prerequisite is not running.'};Out '=== NETWORK/SYSTEM CHECKS: END ==='

Out '';Out '=== AUTO-REPAIR: BEGIN ===';$RepairState='NOT NEEDED';$RepairExit='';$untrappedNeed=$false;if($coreBad.Count -or $sourceBad.Count -or $missing.Count -or -not$packet.Count -or -not$control.Count){$untrappedNeed=$true};if($Problems.Count -gt 0 -and $untrappedNeed){$RepairState='STARTING';Trace 'AUTO-REPAIR' 'Untrapped-owned problems detected. Starting self-repair.';try{$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);if($isAdmin){Trace 'AUTO-REPAIR' 'Current console is elevated; repair runs in THIS console.';& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RepairPath;$RepairExit=[string]$LASTEXITCODE}else{Trace 'AUTO-REPAIR' 'Launching elevated repair window and waiting for completion.';$r=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$RepairPath) -WorkingDirectory $Root -Verb RunAs -Wait -PassThru -ErrorAction Stop;$RepairExit=[string]$r.ExitCode};if($RepairExit -eq '0'){$RepairState='COMPLETED'}else{$RepairState='FAILED'}}catch{$RepairState='FAILED TO START';$RepairExit=$_.Exception.Message;Trace 'AUTO-REPAIR' ('FAILED: '+$_.Exception.Message)}}else{Trace 'AUTO-REPAIR' 'No Untrapped-owned repair trigger detected.'};Out ('[AUTO-REPAIR] State: '+$RepairState);Out ('[AUTO-REPAIR] Exit code: '+$RepairExit);Out '=== AUTO-REPAIR: END ==='

Out '';Out '=== POST-REPAIR VERIFICATION: BEGIN ===';$postMissing=@($CoreFiles|Where-Object{-not(Test-Path -LiteralPath (Join-Path $Root $_))});$postCoreBad=@();foreach($f in $CoreTextFiles){if(-not(SameRemote ('ultra-mode/'+$f) (Join-Path $Root $f))){$postCoreBad+=$f}};$postSourceBad=@();foreach($f in $ExtensionFiles){if(-not(SameRemote $f (Join-Path $Parent $f))){$postSourceBad+=$f}};$postInstalled=Find-BraveUntrapped;$postInstalledBad=0;foreach($d in $postInstalled){foreach($f in $ExtensionFiles){if(-not(SameRemote $f (Join-Path $d $f))){$postInstalledBad++}}};$postPacket=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -like '*packet-filter.ps1*'});$postControl=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -like '*ultra-mode.ps1*'});$PostRepair='NO REPAIR REQUIRED';if($RepairState -eq 'FAILED' -or $RepairState -eq 'FAILED TO START'){$PostRepair='REPAIR INCOMPLETE - RECHECK NEEDED'}elseif($RepairState -eq 'COMPLETED' -and ($postMissing.Count -or $postCoreBad.Count -or $postSourceBad.Count -or $postInstalledBad -or -not$postPacket.Count -or -not$postControl.Count)){$PostRepair='REPAIR INCOMPLETE - RECHECK NEEDED'}elseif($RepairState -eq 'COMPLETED'){$PostRepair='REPAIR SUCCESS - VERIFIED'};Out ('[VERIFY] Missing core files after repair: '+$postMissing.Count);Out ('[VERIFY] Core canonical mismatches after repair: '+$postCoreBad.Count);Out ('[VERIFY] Extension-source mismatches after repair: '+$postSourceBad.Count);Out ('[VERIFY] Installed Brave copies after repair: '+$postInstalled.Count);Out ('[VERIFY] Installed Brave mismatched files after repair: '+$postInstalledBad);Out ('[VERIFY] Packet filter processes after repair: '+$postPacket.Count);Out ('[VERIFY] Control plane processes after repair: '+$postControl.Count);Out ('[VERIFY] Result: '+$PostRepair);Out '=== POST-REPAIR VERIFICATION: END ==='

# ==================== DIAGNOSIS CONTRACT: DO NOT EDIT ====================
# Stable diagnosis semantics.
$Diagnosis='ALL CLEAR';if($RepairState -eq 'FAILED' -or $RepairState -eq 'FAILED TO START' -or $RepairState -eq 'UNAVAILABLE' -or $PostRepair -eq 'REPAIR INCOMPLETE - RECHECK NEEDED'){$Diagnosis='REPAIR INCOMPLETE'}elseif($Problems.Count -eq 0){if($PostRepair -eq 'REPAIR SUCCESS - VERIFIED'){$Diagnosis='REPAIR SUCCESS - VERIFIED'}elseif($UpdateState -eq 'UPDATED THIS RUN'){$Diagnosis='HEALTHY - DIAGNOSTIC UPDATED'}else{$Diagnosis='ALL CLEAR'}}else{$untrappedFault=$false;foreach($p in $Problems){if($p -match '(?i)Untrapped|Packet filter|Control plane|extension|Self-repair|core source|Required Untrapped'){$untrappedFault=$true}};if($untrappedFault){$Diagnosis='ATTENTION NEEDED - UNTRAPPED'}else{$Diagnosis='ATTENTION NEEDED - EXTERNAL PREREQUISITE'}}

Out '';Out 'CONDENSED DIAGNOSIS';Out ('OVERALL: '+$Diagnosis);Out ('Auto-update: '+$UpdateState);Out ('Auto-repair: '+$RepairState);Out ('Repair verify: '+$PostRepair);Out ('Issues: '+$Problems.Count);foreach($p in $Problems){Out ('! '+$p)};Out '';Out 'DETAILED DIAGNOSTIC';Out ('Update detail: '+$UpdateDetail);Out ('Repair triggered: '+$untrappedNeed);Out ('Pre-repair issue count: '+$Problems.Count);Out ('Extension source mismatches before repair: '+$(if($sourceBad.Count){$sourceBad -join ', '}else{'NONE'}));Out ('Brave copies found before repair: '+$installed.Count);Out ('Active adapters: '+$adapters.Count);Out ('Default routes: '+$routes.Count);Out ('Relevant Hosts entries: '+$hostHits.Count);Out ('WinHTTP proxy: '+$proxy);Out ('BFE running: '+$bfeOK);Out ('Override active: '+$override);Out ('Scheduled blocking window: '+$scheduled);Out ('Canonical source: '+$RepoBase);Out 'Repair scope: Untrapped-owned files/processes only; Windows network stack is not altered.';Out 'ACTION TRACE: Every check, comparison, repair trigger, repair result, and verification result is printed above.';Out 'Next run: self-update first, then policy/core/extension/Brave/network checks, repair if needed, and full post-repair verification.';Out '';Out 'STATUS';Out $Diagnosis;Out ('Auto-update: '+$UpdateState);Out 'Extension auto-check: ENABLED';Out 'Extension repair: ENABLED';Out 'Automatic changes are limited to Untrapped-owned components.'

try{$Lines|Set-Content -LiteralPath $ReportPath -Encoding UTF8;Trace 'REPORT' ('Saved permanent diagnostic report: '+$ReportPath)}catch{Write-Host ('[REPORT ERROR] '+$_.Exception.Message)}
Start-Process notepad.exe -ArgumentList $ReportPath -ErrorAction SilentlyContinue
Write-Host '';Write-Host '=== LIVE DIAGNOSTIC COMPLETE ===';Write-Host 'The live console remains open. The permanent report was saved to diagnostic-latest.txt.'
