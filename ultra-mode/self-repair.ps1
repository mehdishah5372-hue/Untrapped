# UARD (Untrapped Auto-Repair Diagnostic) ver 1.0.0 - TRUE BASELINE
# Baseline 1.0.0 may be retained or upgraded; never silently downgraded.
# Performance revision: cache canonical artifacts, targeted Brave discovery, and no pointless retries.
$ErrorActionPreference = 'Stop'
$UARDName = 'UARD (Untrapped Auto-Repair Diagnostic)'
$UARDVersion = '1.0.0'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionRoot = Split-Path -Parent $Root
$Middleman = 'https://untrapped-update-middleman-310-production.up.railway.app'
$ArtifactBase = $Middleman + '/v1/artifact/'
$BackupRoot = Join-Path $Root 'repair-backups'
$Report = Join-Path $Root 'repair-success-latest.txt'
$log = New-Object 'System.Collections.Generic.List[string]'
$changed = $false
$failed = $false
$unknown = $false
$normAttempted = $false
$normOK = $false
$normFail = $false
$normFiles = New-Object 'System.Collections.Generic.List[string]'
$CanonicalCache = @{}
$RunStopwatch = [Diagnostics.Stopwatch]::StartNew()

function Log([string]$Message) { $line = '[' + (Get-Date -Format HH:mm:ss) + '] ' + $Message; Write-Host $line; [void]$log.Add($line) }
function HashBytes([byte[]]$Bytes) { $sha = [Security.Cryptography.SHA256]::Create(); try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() } }
function VersionOf([byte[]]$Bytes) { try { $text=[Text.Encoding]::UTF8.GetString($Bytes); $m=[regex]::Match($text,'(?im)^(?:#|//).*?ver(?:sion)?\s+([0-9]+(?:\.[0-9]+){2})'); if($m.Success){return [version]$m.Groups[1].Value} }catch{}; return [version]'0.0.0' }
function Normalize([byte[]]$Bytes,[string]$Name,[string]$Type) {
    if($Type -eq 'json'){return $Bytes}; $text=[Text.Encoding]::UTF8.GetString($Bytes); $text=$text.TrimStart([char]0xFEFF).Trim(); if(-not $text.StartsWith('{')){return $Bytes}; try{$json=$text|ConvertFrom-Json -ErrorAction Stop}catch{return $Bytes}; if($json -is [string]){return $Bytes}; $value=$null
    foreach($key in @('powershell','script','source','code','content','text','body')){if($json.PSObject.Properties.Name -contains $key -and $json.$key -is [string]){$value=[string]$json.$key;break}}
    $language=([string]$json.language).ToLowerInvariant();$encoding=([string]$json.encoding).ToLowerInvariant();$explicitPowerShell=$language -in @('powershell','powershell-script','powershellscript','ps1','pwsh')
    if($null -eq $value -and $explicitPowerShell -and ($json.PSObject.Properties.Name -contains 'commands')){$items=@($json.commands);$value=($items|ForEach-Object{[string]$_})-join "`r`n"}
    if($null -eq $value){return $Bytes};$script:normAttempted=$true
    try{if($encoding -eq 'base64' -or ([string]$json.content_encoding).ToLowerInvariant() -eq 'base64'){$out=[Convert]::FromBase64String($value)}else{$out=[Text.Encoding]::UTF8.GetBytes($value)};$script:normOK=$true;[void]$script:normFiles.Add($Name);Log ('NORMALIZE SUCCESS '+$Name+' -> native '+$Type);return $out}catch{$script:normFail=$true;Log ('NORMALIZE FAILED '+$Name+': '+$_.Exception.Message);return $Bytes}
}
function RemoteBytes([string]$Name,[string]$Type) {
    if($CanonicalCache.ContainsKey($Name)){return $CanonicalCache[$Name]}
    $last=$null
    for($attempt=1;$attempt -le 4;$attempt++){
        try{
            Log ('FETCH '+$Name+' attempt '+$attempt+'/4')
            $req=[Net.HttpWebRequest]::Create($ArtifactBase+$Name+'?cb='+[DateTime]::UtcNow.Ticks);$req.Method='GET';$req.Timeout=30000;$req.ReadWriteTimeout=30000;$req.UserAgent='UARD/1.0'
            $resp=$req.GetResponse();try{$stream=$resp.GetResponseStream();$ms=New-Object IO.MemoryStream;$stream.CopyTo($ms);$raw=$ms.ToArray()}finally{if($stream){$stream.Dispose()};$resp.Dispose()}
            $bytes=Normalize $raw $Name $Type;$CanonicalCache[$Name]=$bytes;Log ('DOWNLOAD OK '+$Name+' '+$bytes.Length+' bytes SHA256='+ (HashBytes $bytes));return $bytes
        }catch{ $last=$_; $code=0;try{$code=[int]$_.Exception.Response.StatusCode}catch{}; if($code -in @(408,429) -or $code -ge 500){Log ('TRANSIENT FETCH ERROR '+$Name+' HTTP '+$code+'; retrying')}else{Log ('CANONICAL VALIDATION FAILED '+$Name+': '+$_.Exception.Message);break} }
    }
    $script:unknown=$true; Log ('UNVERIFIED '+$Name+' canonical source unavailable; no repair failure established.'); return $null
}
function ValidPS([byte[]]$Bytes,[string]$Name){try{$null=[Text.Encoding]::UTF8.GetString($Bytes);$null=[scriptblock]::Create($null);return $true}catch{Log ('SCRIPT VALIDATION FAILED '+$Name+': '+$_.Exception.Message);return $false}}
function Install([string]$Path,[byte[]]$Bytes){$dir=Split-Path -Parent $Path;if(-not(Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null};$tmp=$Path+'.uaudtmp';[IO.File]::WriteAllBytes($tmp,$Bytes);Move-Item -LiteralPath $tmp -Destination $Path -Force}
function Backup([string]$Path){if(Test-Path -LiteralPath $Path){$stamp=Get-Date -Format 'yyyyMMdd-HHmmssfff';$rel=$Path.Substring($Root.Length).TrimStart('\');$dst=Join-Path $BackupRoot ($stamp+'-'+($rel -replace '[\\/:]','_'));$d=Split-Path -Parent $dst;if(-not(Test-Path $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null};Copy-Item -LiteralPath $Path -Destination $dst -Force;Log ('BACKUP '+$Path+' -> '+$dst)}}

Log ($UARDName+' ver '+$UARDVersion+' - TRUE BASELINE')
Log ('MIDDLEMAN '+$Middleman)
Log 'Protected boundary: no Windows Firewall/WFP/DNS/routes/Hosts/proxy/VPN/adapter/override-policy changes.'
$core=@('config.json','packet-filter.ps1','self-repair.ps1','status-untrapped.ps1','ultra-mode.ps1')
foreach($name in $core){$path=Join-Path $Root $name;$type=if($name -eq 'config.json'){'json'}else{'ps1'};$remote=RemoteBytes ('ultra-mode/'+$name) $type;if($null -eq $remote){continue};if($type -eq 'ps1' -and -not(ValidPS $remote $name)){ $script:failed=$true;continue };$current=if(Test-Path $path){[IO.File]::ReadAllBytes($path)}else{$null};$rh=HashBytes $remote;$ch=if($null -ne $current){HashBytes $current}else{''};if($rh -ne $ch){Backup $path;Install $path $remote;$script:changed=$true;Log ('REPAIRED '+$name+' SHA256='+$rh)}else{Log ('CURRENT '+$name)}}

$braveRoots=@((Join-Path $ExtensionRoot 'extension'),(Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'))
$manifests=New-Object 'System.Collections.Generic.List[string]';foreach($r in $braveRoots){if(Test-Path $r){Get-ChildItem -LiteralPath $r -Filter manifest.json -File -Recurse -ErrorAction SilentlyContinue|ForEach-Object{if(-not $manifests.Contains($_.FullName)){[void]$manifests.Add($_.FullName)}}}}
Log ('BRAVE: Untrapped copies found: '+$manifests.Count)
foreach($m in $manifests){$d=Split-Path -Parent $m;$remote=RemoteBytes 'manifest.json' 'json';if($null -eq $remote){continue};$cur=[IO.File]::ReadAllBytes($m);if((HashBytes $cur) -ne (HashBytes $remote)){Backup $m;Install $m $remote;$script:changed=$true;Log ('REPAIRED Brave manifest '+$m)}}

foreach($native in @('WinDivert.dll','WinDivert64.sys')){$found=Get-ChildItem -LiteralPath $Root -Filter $native -File -Recurse -ErrorAction SilentlyContinue|Select-Object -First 1;if($found){Log ('NATIVE OK '+$native)}else{Log ('NATIVE MISSING '+$native);$script:failed=$true}}
$pf=Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.ProcessName -match '^(powershell|pwsh)$' -and $_.Path -and $_.Path -like '*Untrapped*'};if($pf){Log ('CONTROL PROCESS: '+$pf.Count+' Untrapped-owned PowerShell process(es)')}else{Log 'CONTROL PROCESS: no Untrapped-owned PowerShell process detected'}

if($normAttempted){if($normFail){Log 'NORMALIZATION RESULT: UNSUCCESSFUL'}else{Log 'NORMALIZATION RESULT: SUCCESSFUL'}}else{Log 'NORMALIZATION RESULT: NOT NEEDED'}
if($failed){Log '[DIAGNOSIS] REPAIR INCOMPLETE'}elseif($unknown){Log '[DIAGNOSIS] VERIFICATION INCOMPLETE'}elseif($changed){Log '[DIAGNOSIS] REPAIR SUCCESS'}else{Log '[DIAGNOSIS] NO REPAIR REQUIRED'}
$RunStopwatch.Stop();Log ('RUNTIME '+$RunStopwatch.Elapsed.ToString())
if($changed -or $failed -or $unknown){$reportText=@($UARDName+' ver '+$UARDVersion+' - TRUE BASELINE','Run: '+(Get-Date),'Diagnosis: '+(if($failed){'REPAIR INCOMPLETE'}elseif($unknown){'VERIFICATION INCOMPLETE'}elseif($changed){'REPAIR SUCCESS'}else{'NO REPAIR REQUIRED'}),'Normalization: '+(if($normAttempted){if($normFail){'UNSUCCESSFUL'}else{'SUCCESSFUL'}}else{'NOT NEEDED'}),'Middleman: '+$Middleman,'','Protected boundary unchanged.','',$log);$reportText|Set-Content -LiteralPath $Report -Encoding UTF8;Start-Process notepad.exe -ArgumentList @($Report)|Out-Null}
exit (if($failed){1}elseif($unknown){2}else{0})
