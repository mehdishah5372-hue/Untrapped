# Untrapped Ultra Mode - self repair engine
# Repairs only Untrapped-owned text/config/extension components.
# Does not modify Firewall, WFP, Winsock, DNS, routes, adapters, VPN, Hosts, or override policy.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionRoot=Split-Path -Parent $Root
$RepoBase='https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/'
$BackupRoot=Join-Path $Root 'repair-backups'
$RepairReport=Join-Path $Root 'repair-success-latest.txt'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$log=New-Object 'System.Collections.Generic.List[string]'
$changed=$false
$failed=$false

function Log([string]$s){$x='['+(Get-Date -Format 'HH:mm:ss')+'] '+$s;Write-Host $x;[void]$log.Add($x)}
function Valid([hashtable]$x,[byte[]]$b){try{$t=[Text.Encoding]::UTF8.GetString($b);if($x.Type -eq 'script'){[void][scriptblock]::Create($t)}elseif($x.Type -eq 'json'){$null=$t|ConvertFrom-Json}else{if($b.Length -lt 20){throw 'File is unexpectedly small.'}};return $true}catch{return $false}}
function GetCanonical([hashtable]$x){
    $url=$RepoBase+$x.Remote+'?cb='+[DateTime]::UtcNow.Ticks
    Log ('DOWNLOAD START '+$x.Remote)
    $r=Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $b=[Text.Encoding]::UTF8.GetBytes([string]$r.Content)
    if(-not (Valid $x $b)){throw ('Canonical validation failed: '+$x.Remote)}
    Log ('DOWNLOAD OK '+$x.Remote+' ('+$b.Length+' bytes)')
    return $b
}
function Hash([byte[]]$b){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($b))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function RepairOne([string]$base,[hashtable]$x,[string]$label){
    $path=Join-Path $base $x.Rel
    Log ('CHECK '+$label+'/'+$x.Rel)
    try{$remote=GetCanonical $x}catch{Log ('ERROR '+$x.Rel+' download/validation failed: '+$_.Exception.Message);$script:failed=$true;return}
    $same=$false
    if(Test-Path -LiteralPath $path){try{$local=[IO.File]::ReadAllBytes($path);$same=(Hash $local -eq (Hash $remote))}catch{}}
    if($same){Log ('OK CURRENT '+$label+'/'+$x.Rel);return}
    Log ('DIFF '+$label+'/'+$x.Rel)
    try{
        if(-not (Test-Path -LiteralPath $BackupRoot)){New-Item -ItemType Directory -Path $BackupRoot -Force|Out-Null}
        if(Test-Path -LiteralPath $path){$backup=Join-Path $BackupRoot ($stamp+'-'+$label.Replace('/','_')+'-'+$x.Rel.Replace('/','_'));Copy-Item -LiteralPath $path -Destination $backup -Force;Log ('BACKUP OK '+$backup)}
        $tmp=$path+'.untrapped-repair-'+[guid]::NewGuid().ToString('N')+'.tmp'
        [IO.File]::WriteAllBytes($tmp,$remote)
        if(-not ((Hash ([IO.File]::ReadAllBytes($tmp))) -eq (Hash $remote))){throw 'Temporary write verification failed.'}
        Move-Item -LiteralPath $tmp -Destination $path -Force
        if(-not ((Hash ([IO.File]::ReadAllBytes($path))) -eq (Hash $remote))){throw 'Post-write SHA256 verification failed.'}
        Log ('REPAIRED+VERIFIED '+$label+'/'+$x.Rel)
        $script:changed=$true
    }catch{Log ('FAIL '+$label+'/'+$x.Rel+': '+$_.Exception.Message);$script:failed=$true;Remove-Item ($path+'.untrapped-repair-*') -Force -ErrorAction SilentlyContinue}
}

$Core=@(
 @{Remote='ultra-mode/packet-filter.ps1';Rel='packet-filter.ps1';Type='script'},
 @{Remote='ultra-mode/ultra-mode.ps1';Rel='ultra-mode.ps1';Type='script'},
 @{Remote='ultra-mode/status-untrapped.ps1';Rel='status-untrapped.ps1';Type='script'},
 @{Remote='ultra-mode/self-repair.ps1';Rel='self-repair.ps1';Type='script'},
 @{Remote='ultra-mode/config.json';Rel='config.json';Type='json'})
$Ext=@(
 @{Remote='manifest.json';Rel='manifest.json';Type='json'},
 @{Remote='background.js';Rel='background.js';Type='script'},
 @{Remote='content.js';Rel='content.js';Type='script'},
 @{Remote='popup.html';Rel='popup.html';Type='text'},
 @{Remote='popup.js';Rel='popup.js';Type='script'},
 @{Remote='bootstrap.bundle.min.js';Rel='bootstrap.bundle.min.js';Type='script'})

try{
 Log '=== SELF-REPAIR BEGIN ==='
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 Log 'Repair source: canonical GitHub main branch.'
 foreach($x in $Ext){RepairOne $ExtensionRoot $x 'extension-source'}
 foreach($x in $Core){RepairOne $Root $x 'ultra-mode'}

 Log 'BRAVE CHECK Searching installed profiles.'
 $userData=Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
 $matches=@()
 if(Test-Path $userData){
  $profiles=@(Get-ChildItem $userData -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -eq 'Default' -or $_.Name -like 'Profile *'})
  foreach($profile in $profiles){
   $ed=Join-Path $profile.FullName 'Extensions'
   if(Test-Path $ed){foreach($id in @(Get-ChildItem $ed -Directory -ErrorAction SilentlyContinue)){foreach($ver in @(Get-ChildItem $id.FullName -Directory -ErrorAction SilentlyContinue)){$m=Join-Path $ver.FullName 'manifest.json';if(Test-Path $m){try{$j=Get-Content $m -Raw|ConvertFrom-Json;if([string]$j.name -eq 'Untrapped'){$matches+=$ver.FullName}}catch{}}}}}
  }
 }
 $matches=@($matches|Sort-Object -Unique)
 Log ('BRAVE CHECK Installed Untrapped copies found: '+$matches.Count)
 foreach($m in $matches){foreach($x in $Ext){RepairOne $m $x 'brave-extension'}}

 foreach($native in @('WinDivert.dll','WinDivert64.sys')){if(Test-Path (Join-Path $Root $native)){Log ('OK PRESENT '+$native)}else{Log ('FAIL MISSING '+$native);$failed=$true}}

 if($changed){
  Log 'RESTART Starting Untrapped control plane after repaired files.'
  foreach($pat in @('*packet-filter.ps1*','*ultra-mode.ps1*')){@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -like $pat})|ForEach-Object{Log ('STOP '+$_.ProcessId+' '+$pat);Stop-Process $_.ProcessId -Force -ErrorAction SilentlyContinue}}
  Start-Sleep -Milliseconds 700
  foreach($f in @('packet-filter.ps1','ultra-mode.ps1')){if(Test-Path (Join-Path $Root $f)){Log ('START '+$f);Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root $f)) -WorkingDirectory $Root -Verb RunAs -WindowStyle Hidden -ErrorAction SilentlyContinue}}
  Log 'RESTART Control-plane start commands issued.'
 }else{Log 'RESTART NOT NEEDED No Untrapped-owned files changed.'}

 # ==================== DIAGNOSIS CONTRACT: DO NOT EDIT ====================
 # Stable repair diagnosis semantics.
 [void]$log.Add('')
 if($failed){[void]$log.Add('[DIAGNOSIS] REPAIR INCOMPLETE: one or more canonical components could not be repaired or verified.');$log|Set-Content $RepairReport -Encoding UTF8;Start-Process notepad.exe -ArgumentList $RepairReport -ErrorAction SilentlyContinue;exit 1}
 if($changed){[void]$log.Add('[DIAGNOSIS] REPAIR SUCCESS: changed components were written from canonical GitHub source and post-write verified.');[void]$log.Add('[DIAGNOSIS] Affected control processes were restarted because repair changed Untrapped-owned files.')}else{[void]$log.Add('[DIAGNOSIS] NO REPAIR REQUIRED: all repairable local components matched canonical source.')}
 $log|Set-Content $RepairReport -Encoding UTF8
 Log '=== SELF-REPAIR END ==='
 if($changed){Start-Process notepad.exe -ArgumentList $RepairReport -ErrorAction SilentlyContinue}
 exit 0
}catch{
 Log ('FATAL '+$_.Exception.Message)
 try{@('UNTRAPPED SELF-REPAIR FAILURE','Time: '+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'),'[DIAGNOSIS] REPAIR ENGINE FAILURE: '+$_.Exception.Message)|Set-Content $RepairReport -Encoding UTF8;Start-Process notepad.exe -ArgumentList $RepairReport -ErrorAction SilentlyContinue}catch{}
 exit 1
}
