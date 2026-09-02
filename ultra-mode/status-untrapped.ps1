# Untrapped Ultra Mode - concise self-updating health dashboard
$ErrorActionPreference='Continue'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$SelfPath=$MyInvocation.MyCommand.Path;$ReportPath=Join-Path $Root 'diagnostic-latest.txt';$ConfigPath=Join-Path $Root 'config.json';$OverridePath=Join-Path $Root 'override-until.txt';$PacketPath=Join-Path $Root 'packet-filter.ps1';$SelfRepairPath=Join-Path $Root 'self-repair.ps1'
$UpdateUrl='https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/ultra-mode/status-untrapped.ps1'
# Self-update before doing anything else. A one-shot marker prevents update loops.
if(-not $env:UNTRAPPED_STATUS_UPDATED){try{
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $tmp=Join-Path $env:TEMP ('untrapped-status-'+[guid]::NewGuid().ToString('N')+'.ps1')
  Invoke-WebRequest ($UpdateUrl+'?cb='+[DateTime]::UtcNow.Ticks) -OutFile $tmp -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
  $remote=[IO.File]::ReadAllText($tmp);$local=[IO.File]::ReadAllText($SelfPath)
  if($remote.Length -gt 1500 -and $remote -ne $local){
    [void][scriptblock]::Create($remote)
    [IO.File]::Copy($SelfPath,$SelfPath+'.preupdate.bak', $true)
    [IO.File]::WriteAllText($SelfPath,$remote,(New-Object Text.UTF8Encoding($false)))
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    $env:UNTRAPPED_STATUS_UPDATED='1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SelfPath
    exit $LASTEXITCODE
  }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}catch{# GitHub unavailable: continue with the local diagnostic.
}}
$lines=New-Object System.Collections.Generic.List[string];$problems=New-Object System.Collections.Generic.List[string]
function R([string]$x){Write-Host $x;[void]$lines.Add($x)}
function P([string]$x){if(-not ($problems -contains $x)){[void]$problems.Add($x)}}
function Repair{
 if(Test-Path $SelfRepairPath){try{R '[REPAIR] Running Untrapped self-repair...';Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SelfRepairPath) -WorkingDirectory $Root -Verb RunAs -Wait -WindowStyle Hidden -ErrorAction Stop;R '[REPAIR OK] Self-repair completed.';return $true}catch{R '[REPAIR FAIL] Self-repair could not start.'}}
 if(Test-Path $PacketPath){try{@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|? CommandLine -like '*packet-filter.ps1*')|%{Stop-Process $_.ProcessId -Force -ErrorAction SilentlyContinue};Start-Sleep -Milliseconds 500;Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PacketPath) -WorkingDirectory $Root -Verb RunAs -WindowStyle Hidden -ErrorAction Stop;R '[REPAIR OK] Packet filter restarted.';return $true}catch{R '[REPAIR FAIL] Packet filter restart failed.';P 'Untrapped packet filter could not be restarted.'}}
 return $false
}
function Reach([string]$host){try{return [bool](Test-NetConnection $host -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded}catch{return $false}}
function DnsOK([string]$host){try{return @((Resolve-DnsName $host -DnsOnly -ErrorAction Stop|? IPAddress)).Count -gt 0}catch{return $false}}
$now=Get-Date
R '';R '========================================';R '       UNTRAPPED HEALTH DASHBOARD';R '========================================';R "Time: $($now.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
$config=$null;$active=$false;$override=$false
try{$config=Get-Content $ConfigPath -Raw|ConvertFrom-Json;$s=[TimeSpan]::Parse([string]$config.start);$e=[TimeSpan]::Parse([string]$config.end);$t=$now.TimeOfDay;if($s -eq $e){$active=$true}elseif($s -lt $e){$active=$t -ge $s -and $t -lt $e}else{$active=$t -ge $s -or $t -lt $e}}catch{P 'Config is invalid.'}
if(Test-Path $OverridePath){try{$u=[DateTime]::Parse((Get-Content $OverridePath -Raw)).ToUniversalTime();$override=[DateTime]::UtcNow -lt $u}catch{P 'Override file is malformed.'}}
$scheduled=[bool]($config.enabled -and $active -and -not $override)
R '';R 'POLICY'
$yt=Reach 'www.youtube.com';$ch=Reach 'chatgpt.com';$cr=Reach 'www.crushon.ai';$ytOK=($yt -eq (-not $scheduled));$chOK=($ch -eq (-not $scheduled));$crOK=(-not $cr)
R "  YouTube       $(if($ytOK){if($scheduled){'BLOCKED ✓'}else{'ALLOWED ✓'}}else{'WRONG ✗'})";R "  ChatGPT       $(if($chOK){if($scheduled){'BLOCKED ✓'}else{'ALLOWED ✓'}}else{'WRONG ✗'})";R "  CrushOn       $(if($crOK){'BLOCKED ✓'}else{'REACHABLE ✗'})";R "  Schedule      $($config.start) -> $($config.end) | $(if($scheduled){'BLOCKING'}else{'NOT BLOCKING'})";R "  Override      $(if($override){'ACTIVE'}else{'OFF'})"
if(!$ytOK){P "YouTube does not match policy (expected $(if($scheduled){'blocked'}else{'allowed'}))."};if(!$chOK){P "ChatGPT does not match policy (expected $(if($scheduled){'blocked'}else{'allowed'}))."};if(!$crOK){P 'CrushOn is reachable while it should be blocked.'}
$packet=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|? CommandLine -like '*packet-filter.ps1*');$control=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|? CommandLine -like '*ultra-mode.ps1*');$required=@('WinDivert.dll','WinDivert64.sys','config.json','packet-filter.ps1','ultra-mode.ps1','status-untrapped.ps1','self-repair.ps1');$fileCount=@($required|%{Test-Path (Join-Path $Root $_)}|? {$_}).Count
R '';R 'UNTRAPPED';R "  Packet filter $(if($packet.Count){'RUNNING ✓'}else{'STOPPED ✗'})";R "  Control plane $(if($control.Count){'RUNNING ✓'}else{'STOPPED ✗'})";R "  Required files $fileCount/$($required.Count) $(if($fileCount -eq $required.Count){'✓'}else{'✗'})";if(!$packet.Count){P 'Packet filter is not running.'};if(!$control.Count){P 'Control plane is not running.'};if($fileCount -lt $required.Count){P 'One or more required Untrapped files are missing.'}
R '';R 'NETWORK';$ad=@(Get-NetAdapter|? Status -eq 'Up');$badIP=$false;foreach($a in $ad){$c=Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue;if(!$c.IPv4Address -and !$c.IPv6Address){$badIP=$true}};$dnsGood=DnsOK 'google.com';$httpsGood=Reach 'www.google.com';$routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue);$fwGood=$true;try{$fwGood=@(Get-NetFirewallProfile|? {!$_.Enabled}).Count -eq 0}catch{$fwGood=$false};$bfeGood=$false;try{$bfeGood=(Get-Service BFE).Status -eq 'Running'}catch{}
R "  Internet      $(if($httpsGood){'OK ✓'}else{'FAIL ✗'})";R "  DNS           $(if($dnsGood){'OK ✓'}else{'FAIL ✗'})";R "  IP addresses  $(if(!$badIP -and $ad.Count){'OK ✓'}else{'CHECK ✗'})";R "  Routes        $(if($routes.Count){'OK ✓'}else{'FAIL ✗'})";R "  Firewall      $(if($fwGood){'OK ✓'}else{'CHECK ✗'})";R "  WFP/BFE       $(if($bfeGood){'OK ✓'}else{'FAIL ✗'})";R "  Adapters      $($ad.Count) UP $(if($ad.Count){'✓'}else{'✗'})";if(!$httpsGood){P 'General HTTPS path failed.'};if(!$dnsGood){P 'General DNS resolution failed.'};if($badIP){P 'An active adapter has no IP address.'};if(!$routes.Count){P 'No IPv4 default route.'};if(!$fwGood){P 'A Windows Firewall profile is disabled.'};if(!$bfeGood){P 'WFP Base Filtering Engine is not running.'}
R '';R 'BROWSERS / SEARCH PATH';foreach($b in @('brave','chrome','msedge','firefox')){$running=@(Get-Process -Name $b -ErrorAction SilentlyContinue).Count;R "  $b $(if($httpsGood){'web path OK ✓'}else{'web path FAIL ✗'}) | $(if($running){'running'}else{'not running'})"};if(!$httpsGood){P 'Browser/search HTTPS path failed.'}
R '';R 'OTHER';$hostsBad=$false;try{$h=@(Get-Content 'C:\Windows\System32\drivers\etc\hosts'|? {$_ -match '(youtube|youtu\.be|ytimg|googlevideo|chatgpt|crushon)' -and $_ -notmatch '^\s*#'});$hostsBad=$h.Count -gt 0}catch{};$vpn=@(Get-NetAdapter|? Name -match '(?i)proton|speedify|vpn|wireguard|tun|tap');R "  Hosts         $(if(!$hostsBad){'CLEAN ✓'}else{'ENTRIES ✗'})";R "  VPN/tunnel    $(if($vpn.Count){($vpn|% Name)-join ', '}else{'none detected'})";try{[void](Invoke-WebRequest 'https://github.com' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop);R '  GitHub        ACCESSIBLE ✓'}catch{R '  GitHub        UNREACHABLE ✗';P 'GitHub could not be reached.'};if($hostsBad){P 'Unexpected target entries exist in Hosts.'}
# Only auto-repair when the actual blocking policy is wrong, or Untrapped itself is missing.
if((!$ytOK -or !$chOK -or !$crOK) -or !$packet.Count -or !$control.Count -or $fileCount -lt $required.Count){R '';R '[REPAIR] Untrapped-owned fault detected.';[void](Repair)}
R '';R '========================================';if($problems.Count){R "STATUS: ATTENTION NEEDED ($($problems.Count))";foreach($x in $problems){R "  ! $x"}}else{R 'STATUS: ALL CLEAR ✓'};R '========================================';R 'Full diagnostic: diagnostic-latest.txt';R 'Auto-update: ENABLED (GitHub checked at startup)';R 'Automatic repairs are limited to Untrapped-owned files/processes.'
$lines|Set-Content $ReportPath -Encoding UTF8
if($problems.Count){try{Start-Process notepad.exe -ArgumentList $ReportPath -ErrorAction SilentlyContinue}catch{}}
if($problems.Count){exit 1}else{exit 0}
