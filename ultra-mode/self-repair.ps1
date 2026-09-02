# Untrapped Ultra Mode - bounded self-repair engine
# Repairs Untrapped's PowerShell control plane AND the Untrapped Enhanced browser-extension
# source from the canonical GitHub repository. It never changes Windows Firewall, WFP,
# Winsock, DNS, routes, adapters, VPN, Hosts, or the user's override policy.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionRoot=Split-Path -Parent $Root
$RepoBase='https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/'
$BackupRoot=Join-Path $Root 'repair-backups'
$RepairReport=Join-Path $Root 'repair-success-latest.txt'
$Targets=@(
 @{Name='ultra-mode/packet-filter.ps1';Local='packet-filter.ps1';Type='script'},
 @{Name='ultra-mode/ultra-mode.ps1';Local='ultra-mode.ps1';Type='script'},
 @{Name='ultra-mode/status-untrapped.ps1';Local='status-untrapped.ps1';Type='script'},
 @{Name='ultra-mode/config.json';Local='config.json';Type='json'},
 @{Name='manifest.json';Local='manifest.json';Type='json';Extension=$true},
 @{Name='content.js';Local='content.js';Type='script';Extension=$true},
 @{Name='background.js';Local='background.js';Type='script';Extension=$true},
 @{Name='popup.html';Local='popup.html';Type='html';Extension=$true}
)
function Say([string]$s){Write-Host $s}
function ValidScript([string]$t){try{[void][scriptblock]::Create($t);$true}catch{$false}}
function ValidJson([string]$t){try{$null=$t|ConvertFrom-Json;$true}catch{$false}}
function Valid([hashtable]$x,[string]$t){if([string]::IsNullOrWhiteSpace($t)){return $false};switch($x.Type){'script'{ValidScript $t};'json'{ValidJson $t};default{$t.Length -gt 20}}}
try{
 if(!(Test-Path $BackupRoot)){New-Item -ItemType Directory -Path $BackupRoot -Force|Out-Null}
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$changed=$false;$failed=$false;$rl=New-Object System.Collections.Generic.List[string]
 [void]$rl.Add('UNTRAPPED ULTRA MODE - SELF-REPAIR SUCCESS REPORT');[void]$rl.Add('Time: '+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'));[void]$rl.Add('')
 foreach($x in $Targets){
  $base=if($x.Extension){$ExtensionRoot}else{$Root};$path=Join-Path $base $x.Local;$need=!(Test-Path $path);$reason=if($need){'missing'}else{''}
  if(!$need){try{if(!(Valid $x ([IO.File]::ReadAllText($path)))){$need=$true;$reason='invalid syntax/content'}}catch{$need=$true;$reason='unreadable'}}
  if(!$need){Say "[OK] $($x.Local) checked.";[void]$rl.Add("[OK] $($x.Local) - no repair needed.");continue}
  Say "[REPAIR NEEDED] $($x.Local) is $reason; fetching canonical copy.";[void]$rl.Add("[REPAIR] $($x.Local) was $reason.")
  $tmp=Join-Path $env:TEMP ('untrapped-repair-'+[guid]::NewGuid().ToString('N')+'-'+[IO.Path]::GetFileName($x.Local))
  try{
   Invoke-WebRequest -Uri ($RepoBase+$x.Name) -OutFile $tmp -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
   $remote=[IO.File]::ReadAllText($tmp);if(!(Valid $x $remote)){throw 'Downloaded canonical file failed validation.'}
   if(Test-Path $path){$backup=Join-Path $BackupRoot ($stamp+'-'+[IO.Path]::GetFileName($x.Local));Copy-Item $path $backup -Force;Say "[OK BACKUP] $backup";[void]$rl.Add('[BACKUP] '+$backup)}
   Copy-Item $tmp $path -Force;Say "[OK REPAIRED] $($x.Local) restored.";[void]$rl.Add("[OK REPAIRED] $($x.Local) restored from validated GitHub copy.");$changed=$true
  }catch{Say "[FAIL REPAIR] $($x.Local): $($_.Exception.Message)";[void]$rl.Add("[FAIL] $($x.Local): $($_.Exception.Message)");$failed=$true}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
 }
 foreach($native in @('WinDivert.dll','WinDivert64.sys')){if(Test-Path (Join-Path $Root $native)){Say "[OK] $native present.";[void]$rl.Add("[OK] $native present.")}else{Say "[FAIL] $native missing; not modified.";[void]$rl.Add("[FAIL] $native missing; native binaries were not modified.");$failed=$true}}
 if($changed){Say '[RESTART] Reloading Untrapped control plane.';[void]$rl.Add('[RESTART] Reloading PowerShell control processes.');foreach($pat in @('*packet-filter.ps1*','*ultra-mode.ps1*')){@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|? CommandLine -like $pat)|%{Stop-Process $_.ProcessId -Force -ErrorAction SilentlyContinue}};Start-Sleep -Milliseconds 700;foreach($f in @('packet-filter.ps1','ultra-mode.ps1')){if(Test-Path (Join-Path $Root $f)){Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root $f)) -WorkingDirectory $Root -Verb RunAs -WindowStyle Hidden -ErrorAction SilentlyContinue}};[void]$rl.Add('[OK] Control processes restart commands issued.')}
 if($failed){[void]$rl.Add('');[void]$rl.Add('[FAIL] Self-repair did not complete successfully.');$rl|Set-Content $RepairReport -Encoding UTF8;Start-Process notepad.exe -ArgumentList $RepairReport -ErrorAction SilentlyContinue;exit 1}
 [void]$rl.Add('');if($changed){[void]$rl.Add('[SUCCESS] Untrapped control plane and/or Enhanced extension source repaired successfully.');Say '[HEALTHY] Repair completed.'}else{[void]$rl.Add('[HEALTHY] No repair required.');Say '[HEALTHY] No repair required.'};$rl|Set-Content $RepairReport -Encoding UTF8;if($changed){Start-Process notepad.exe -ArgumentList $RepairReport -ErrorAction SilentlyContinue};exit 0
}catch{try{@('UNTRAPPED SELF-REPAIR FAILURE','Time: '+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'),'[FAIL] '+$_.Exception.Message)|Set-Content $RepairReport -Encoding UTF8;Start-Process notepad.exe -ArgumentList $RepairReport -ErrorAction SilentlyContinue}catch{};exit 1}
