# UAUD Diagnostics 1.0.0 — self-diagnosing launcher for the complete UAUD/UARD chain
# Runs UAUD as a child process, captures ALL stdout/stderr, performs independent stage
# health checks, fingerprints failures, and emits a precise diagnostic report.
# This script never installs policy and never changes firewall/WFP/DNS/Hosts/routes/VPN/proxy.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$PSExe="$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$Middleman='https://untrapped-update-middleman-000-999-production.up.railway.app'
$RunId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$ReportRoot=Join-Path $Root 'uaud-diagnostics';$Run=Join-Path $ReportRoot $RunId
New-Item -ItemType Directory -Force -Path $Run | Out-Null
function Stamp([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function HashFile([string]$p){$sha=Get-FileHash -LiteralPath $p -Algorithm SHA256;return $sha.Hash.ToLowerInvariant()}
function WriteJson([string]$name,[object]$o){$o|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $Run $name) -Encoding UTF8}
function Fingerprint([string]$text){$n=$text.ToLowerInvariant();$n=[regex]::Replace($n,'\d{4,}','<n>');$n=[regex]::Replace($n,'[0-9a-f]{16,}','<hex>');$n=[regex]::Replace($n,'https?://\S+','<url>');$n=[regex]::Replace($n,'\s+',' ');$n=$n.Trim();$bytes=[Text.Encoding]::UTF8.GetBytes($n);$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function StageFromText([string]$line){if($line -match 'STAGE 0|canonical'){return 'CANON/MIDDLEMAN'}elseif($line -match 'STAGE 1|JSON -> PS'){return 'JSON_TO_PS'}elseif($line -match 'STAGE 2|PARSER'){return 'PS_PARSER'}elseif($line -match 'STAGE 3|adaptive repair|repair validator'){return 'ADAPTIVE_REPAIR'}elseif($line -match 'STAGE 4|AST'){return 'AST_TO_CANON'}elseif($line -match 'STAGE 5|equivalence|CANONICAL_MISMATCH'){return 'CANONICAL_EQUIVALENCE'}elseif($line -match 'STAGE 6|behavioural|behaviour'){return 'WINDOWS_BEHAVIOUR'}elseif($line -match 'UARD|self-repair|INSTALL'){return 'UARD/INSTALL'}else{return 'ORCHESTRATOR'}}
function Diagnose([string[]]$lines){
  $errLines=@($lines|Where-Object{$_ -and ($_ -match '(?i)(error|exception|failure|failed|invalid|mismatch|rejected|missing|cannot|could not|not found|denied|timeout|refused|unsafe|cooked|unknown)')})
  $stageErrors=@()
  foreach($l in $errLines){$stage=StageFromText $l;$stageErrors+= [ordered]@{stage=$stage;message=$l;fingerprint=(Fingerprint $l)}}
  $groups=@($stageErrors|Group-Object fingerprint|Sort-Object Count -Descending|ForEach-Object{[ordered]@{fingerprint=$_.Name;count=$_.Count;stage=($_.Group[0].stage);messages=@($_.Group|Select-Object -ExpandProperty message -Unique)}})
  [ordered]@{error_lines=$errLines;stage_errors=$stageErrors;fingerprints=$groups}
}
Stamp 'UAUD DIAGNOSTICS 1.0.0 — starting complete-chain diagnosis'
WriteJson 'run.json' ([ordered]@{run_id=$RunId;started_utc=[DateTime]::UtcNow.ToString('o');root=$Root;middleman=$Middleman;mode='diagnostic-only';install_performed=$false})
$pre=[ordered]@{powershell_exists=(Test-Path -LiteralPath $PSExe);uaud_exists=(Test-Path -LiteralPath (Join-Path $Root 'UAUD.ps1'));uard_exists=(Test-Path -LiteralPath (Join-Path $Root 'self-repair.ps1'));validator_exists=(Test-Path -LiteralPath (Join-Path $Root 'UAUD-validate.ps1'));sandbox_exists=(Test-Path -LiteralPath (Join-Path $Root 'sandbox-behaviour.ps1'));schema_exists=(Test-Path -LiteralPath (Join-Path $Root 'artifact-schema.json'));evidence_exists=(Test-Path -LiteralPath (Join-Path $Root 'evidence.ps1'));error_library_exists=(Test-Path -LiteralPath (Join-Path $Root 'ErrorLibrary.ps1'));config_exists=(Test-Path -LiteralPath (Join-Path $Root 'config.json'));packet_filter_exists=(Test-Path -LiteralPath (Join-Path $Root 'packet-filter.ps1'))}
WriteJson 'preflight.json' $pre
if(-not $pre.powershell_exists){Stamp 'FATAL: Windows PowerShell missing';exit 2}
$static=@()
foreach($file in @('UAUD.ps1','self-repair.ps1','UAUD-validate.ps1','sandbox-behaviour.ps1','evidence.ps1','ErrorLibrary.ps1','packet-filter.ps1')){
  $p=Join-Path $Root $file
  if(Test-Path -LiteralPath $p){
    $t=$null;$e=$null
    try{$ast=[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);$static+=[ordered]@{file=$file;parse_pass=(@($e).Count -eq 0);errors=@($e|ForEach-Object{[ordered]@{message=$_.Message;line=$_.Extent.StartLineNumber;column=$_.Extent.StartColumnNumber}});sha256=HashFile $p;bytes=(Get-Item -LiteralPath $p).Length}}catch{$static+=[ordered]@{file=$file;parse_pass=$false;errors=@([ordered]@{message=$_.Exception.Message});sha256=$null;bytes=$null}}
  }else{$static+=[ordered]@{file=$file;parse_pass=$false;errors=@([ordered]@{message='FILE_MISSING'});sha256=$null;bytes=$null}}
}
WriteJson 'static-parser-check.json' $static
Stamp 'Independent static parser checks complete'
try{
  $health=Invoke-WebRequest -UseBasicParsing -Uri ($Middleman+'/health') -TimeoutSec 20
  $healthObj=$health.Content|ConvertFrom-Json
  WriteJson 'middleman-health.json' ([ordered]@{http_status=[int]$health.StatusCode;body=$healthObj;pass=($healthObj.version -eq '3.2.0' -and [int]$healthObj.protocol -eq 3 -and [string]$healthObj.baseline -eq '1.0.0')})
  Stamp "Middleman health: HTTP $($health.StatusCode), version=$($healthObj.version), protocol=$($healthObj.protocol), baseline=$($healthObj.baseline)"
}catch{WriteJson 'middleman-health.json' ([ordered]@{pass=$false;error=$_.Exception.Message;fingerprint=(Fingerprint $_.Exception.Message)});Stamp "MIDDLEMAN DIAGNOSIS: $($_.Exception.Message)"}
$psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$PSExe;$psi.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $Root 'UAUD.ps1')+'"';$psi.WorkingDirectory=$Root;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$false
Stamp 'Launching UAUD as diagnostic child process — no installation is performed by this wrapper'
$proc=New-Object Diagnostics.Process;$proc.StartInfo=$psi
try{[void]$proc.Start();$stdout=$proc.StandardOutput.ReadToEnd();$stderr=$proc.StandardError.ReadToEnd();$proc.WaitForExit();$rc=$proc.ExitCode}catch{$stdout='';$stderr=($_|Out-String);$rc=2}
$stdout|Set-Content -LiteralPath (Join-Path $Run 'stdout.txt') -Encoding UTF8;$stderr|Set-Content -LiteralPath (Join-Path $Run 'stderr.txt') -Encoding UTF8
$all=@($stdout -split "`r?`n")+@($stderr -split "`r?`n")
$diagnosis=Diagnose $all
WriteJson 'diagnosis.json' $diagnosis
$stageSummary=@('CANON/MIDDLEMAN','JSON_TO_PS','PS_PARSER','ADAPTIVE_REPAIR','AST_TO_CANON','CANONICAL_EQUIVALENCE','WINDOWS_BEHAVIOUR','UARD/INSTALL','ORCHESTRATOR')|ForEach-Object{[ordered]@{stage=$_;observed=(@($all|Where-Object{(StageFromText $_) -eq $_}).Count -gt 0);errors=@($diagnosis.stage_errors|Where-Object{$_.stage -eq $_}).Count}}
WriteJson 'stage-summary.json' $stageSummary
WriteJson 'environment.json' ([ordered]@{computer=$env:COMPUTERNAME;user=$env:USERNAME;cwd=(Get-Location).Path;powershell=$PSVersionTable;language_mode=$ExecutionContext.SessionState.LanguageMode;execution_policy=@(Get-ExecutionPolicy -List|ForEach-Object{$_.ToString()});run_id=$RunId})
WriteJson 'result.json' ([ordered]@{uaud_exit_code=$rc;diagnostic_error_count=@($diagnosis.stage_errors).Count;status=if($rc -eq 0 -and @($diagnosis.stage_errors).Count -eq 0){'SUCCESS'}else{'FAIL_DIAGNOSED'};timestamp_utc=[DateTime]::UtcNow.ToString('o');report=$Run})
Stamp ''
Stamp '=== UAUD SELF-DIAGNOSIS ==='
Stamp "UAUD EXIT CODE: $rc"
Stamp "DIAGNOSTIC REPORT: $Run"
if(@($diagnosis.stage_errors).Count -eq 0){Stamp 'DIAGNOSIS: no error-like output detected; UAUD completed without reported failure.'}else{
  foreach($g in @($diagnosis.fingerprints)){
    Stamp "FAILURE: stage=$($g.stage) count=$($g.count) fingerprint=$($g.fingerprint)"
    foreach($m in @($g.messages)){Stamp "  DETAIL: $m"}
  }
}
if($rc -eq 0 -and @($diagnosis.stage_errors).Count -eq 0){Stamp 'RESULT: PASS — UAUD chain reported success.';exit 0}
Stamp 'RESULT: FAIL — nothing is installed by this diagnostic wrapper; use the report to identify the exact failing stage.'
exit 1
