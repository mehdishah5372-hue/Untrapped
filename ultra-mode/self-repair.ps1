# Untrapped Ultra Mode - bounded self-repair engine
#
# EDITOR NOTE: THE DIAGNOSIS CONTRACT IS IMMUTABLE.
# If this file is edited in the future, DO NOT EDIT, REMOVE, REORDER, OR CHANGE
# the DIAGNOSIS CONTRACT section or its severity/exit semantics. Repair mechanics
# may evolve, but diagnosis must remain stable and must report what actually happened.
#
# Repairs only Untrapped-owned PowerShell/config/extension text components.
# It does not modify Windows Firewall, WFP, Winsock, DNS, routes, adapters, VPN,
# Hosts, or the override policy.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionRoot=Split-Path -Parent $Root
$RepoBase='https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/'
$BackupRoot=Join-Path $Root 'repair-backups'
$RepairReport=Join-Path $Root 'repair-success-latest.txt'
$Core=@(
 @{Remote='ultra-mode/packet-filter.ps1';Rel='packet-filter.ps1';Type='script'},
 @{Remote='ultra-mode/ultra-mode.ps1';Rel='ultra-mode.ps1';Type='script'},
 @{Remote='ultra-mode/status-untrapped.ps1';Rel='status-untrapped.ps1';Type='script'},
 @{Remote='ultra-mode/self-repair.ps1';Rel='self-repair.ps1';Type='script'},
 @{Remote='ultra-mode/config.json';Rel='config.json';Type='json'}
)
$Ext=@(
 @{Remote='manifest.json';Rel='manifest.json';Type='json'},
 @{Remote='background.js';Rel='background.js';Type='script'},
 @{Remote='content.js';Rel='content.js';Type='script'},
 @{Remote='popup.html';Rel='popup.html';Type='text'},
 @{Remote='popup.js';Rel='popup.js';Type='script'},
 @{Remote='bootstrap.bundle.min.js';Rel='bootstrap.bundle.min.js';Type='script'}
)
function Valid([hashtable]$x,[string]$t){if([string]::IsNullOrWhiteSpace($t)){return $false};try{switch($x.Type){'script'{[void][scriptblock]::Create($t);return $true};'json'{$null=$t|ConvertFrom-Json;return $true};default{return $t.Length -gt 20}}}catch{return $false}}
function Download([hashtable]$x){$tmp=Join-Path $env:TEMP ('untrapped-repair-'+[guid]::NewGuid().ToString('N')+'-'+[IO.Path]::GetFileName($x.Rel));Invoke-WebRequest -Uri ($RepoBase+$x.Remote+'?cb='+[DateTime]::UtcNow.Ticks) -OutFile $tmp -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop;$text=[IO.File]::ReadAllText($tmp);if(!(Valid $x $text)){Remove-Item $tmp -Force -ErrorAction SilentlyContinue;throw "Canonical $($x.Rel) failed validation."};return @{Path=$tmp;Text=$text}}
function SameCanonical([hashtable]$x,[string]$path){if(!(Test-Path $path)){return $false};$d=Download $x;try{return [IO.File]::ReadAllText($path) -ceq $d.Text}finally{Remove-Item $d.Path -Force -ErrorAction SilentlyContinue}}
try{
 if(!(Test-Path $BackupRoot)){New-Item -ItemType Directory -Path $BackupRoot -Force|Out-Null}
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$changed=$false;$failed=$false
 $rl=New-Object 'System.Collections.Generic.List[string]'
 [void]$rl.Add('UNTRAPPED ULTRA MODE - SELF-REPAIR REPORT')
 [void]$rl.Add('Time: '+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
 [void]$rl.Add('Repair engine: CANONICAL-SOURCE + VALIDATE + BACKUP + VERIFY')
 [void]$rl.Add('')
 function RepairSet([string]$base,$items,[string]$label){foreach($x in $items){$path=Join-Path $base $x.Rel;$need=$true;if(Test-Path $path){try{$need=!(SameCanonical $x $path)}catch{$need=$true;Write-Host "[COMPARE ERROR] $label/$($x.Rel): $($_.Exception.Message)";[void]$rl.Add("[COMPARE ERROR] $label/$($x.Rel): $($_.Exception.Message)")}};if(!$need){Write-Host "[CURRENT] $label/$($x.Rel)";[void]$rl.Add("[CURRENT] $label/$($x.Rel)");continue};Write-Host "[REPAIR NEEDED] $label/$($x.Rel)";[void]$rl.Add("[REPAIR NEEDED] $label/$($x.Rel)");$tmp=$null;try{$d=Download $x;$tmp=$d.Path;if(Test-Path $path){$backup=Join-Path $BackupRoot ($stamp+'-'+$label.Replace('/','_')+'-'+$x.Rel.Replace('/','_'));Copy-Item $path $backup -Force;[void]$rl.Add('[BACKUP] '+$backup)};Copy-Item $tmp $path -Force;if(!(SameCanonical $x $path)){throw "Post-write verification failed for $($x.Rel)."};Write-Host "[OK REPAIRED+VERIFIED] $label/$($x.Rel)";[void]$rl.Add("[OK REPAIRED+VERIFIED] $label/$($x.Rel)");$script:changed=$true}catch{Write-Host "[FAIL REPAIR] $label/$($x.Rel): $($_.Exception.Message)";[void]$rl.Add("[FAIL] $label/$($x.Rel): $($_.Exception.Message)");$script:failed=$true}finally{if($tmp){Remove-Item $tmp -Force -ErrorAction SilentlyContinue}}}}
 RepairSet $ExtensionRoot $Ext 'extension-source';RepairSet $Root $Core 'ultra-mode'
 $userData=Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data';$matches=@()
 if(Test-Path $userData){$profiles=@(Get-ChildItem $userData -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -eq 'Default' -or $_.Name -like 'Profile *'});foreach($profile in $profiles){$extDir=Join-Path $profile.FullName 'Extensions';if(!(Test-Path $extDir)){continue};foreach($idDir in @(Get-ChildItem $extDir -Directory -ErrorAction SilentlyContinue)){foreach($verDir in @(Get-ChildItem $idDir.FullName -Directory -ErrorAction SilentlyContinue)){$manifest=Join-Path $verDir.FullName 'manifest.json';if(Test-Path $manifest){try{$j=Get-Content $manifest -Raw|ConvertFrom-Json;if([string]$j.name -eq 'Untrapped'){$matches+=$verDir.FullName}}catch{}}}}}}
 $matches=@($matches|Select-Object -Unique)
 if($matches.Count){foreach($m in $matches){Write-Host "[FOUND] Brave Untrapped extension: $m";[void]$rl.Add('[FOUND] Brave extension: '+$m);RepairSet $m $Ext 'brave-extension'}}else{Write-Host '[INFO] Brave-installed Untrapped extension not found.';[void]$rl.Add('[INFO] No Brave-installed Untrapped extension directory was found.')}
 foreach($native in @('WinDivert.dll','WinDivert64.sys')){if(Test-Path (Join-Path $Root $native)){[void]$rl.Add("[OK] $native present.")}else{[void]$rl.Add("[FAIL] $native missing; native binary not modified.");$failed=$true}}
 if($changed){Write-Host '[RESTART] Reloading Untrapped control plane.';[void]$rl.Add('[RESTART] Reloading control processes.');foreach($pat in @('*packet-filter.ps1*','*ultra-mode.ps1*')){@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -like $pat})|ForEach-Object{Stop-Process $_.ProcessId -Force -ErrorAction SilentlyContinue}};Start-Sleep -Milliseconds 700;foreach($f in @('packet-filter.ps1','ultra-mode.ps1')){if(Test-Path (Join-Path $Root $f)){Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root $f)) -WorkingDirectory $Root -Verb RunAs -WindowStyle Hidden -ErrorAction SilentlyContinue}};[void]$rl.Add('[OK] Control restart issued.')}
 # ==================== DIAGNOSIS CONTRACT: DO NOT EDIT ====================
 # This section defines the stable meaning of repair success/failure.
 # Do not edit this section during future maintenance. Change repair mechanics above it.
 [void]$rl.Add('')
 if($failed){[void]$rl.Add('[DIAGNOSIS] REPAIR INCOMPLETE: one or more canonical components could not be repaired or verified.');$rl|Set-Content $RepairReport -Encoding UTF8;Start-Process notepad.exe -ArgumentList $RepairReport -ErrorAction SilentlyContinue;exit 1}
 if($changed){[void]$rl.Add('[DIAGNOSIS] REPAIR SUCCESS: changed components were written from canonical GitHub source and post-write verified.');[void]$rl.Add('[DIAGNOSIS] Affected control processes were restarted because repair changed Untrapped-owned files.')}else{[void]$rl.Add('[DIAGNOSIS] NO REPAIR REQUIRED: all repairable local components matched canonical source.')}
 $rl|Set-Content $RepairReport -Encoding UTF8;if($changed){Start-Process notepad.exe -ArgumentList $RepairReport -ErrorAction SilentlyContinue};exit 0
}catch{try{@('UNTRAPPED SELF-REPAIR FAILURE','Time: '+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'),'[DIAGNOSIS] REPAIR ENGINE FAILURE: '+$_.Exception.Message)|Set-Content $RepairReport -Encoding UTF8;Start-Process notepad.exe -ArgumentList $RepairReport -ErrorAction SilentlyContinue}catch{};exit 1}
