# Remote observable harness. Safe: parses source and executes only explicitly sandboxed policy helpers.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$Run=Join-Path $Root 'uaud-evidence\remote-'+(Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $Run -Force|Out-Null
function SaveJ([string]$stage,[string]$name,[object]$o){$d=Join-Path $Run $stage;New-Item -ItemType Directory -Path $d -Force|Out-Null;$o|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $d $name) -Encoding UTF8}
function SaveT([string]$stage,[string]$name,[string]$s){$d=Join-Path $Run $stage;New-Item -ItemType Directory -Path $d -Force|Out-Null;[string]$s|Set-Content -LiteralPath (Join-Path $d $name) -Encoding UTF8}
$files=@('config.json','packet-filter.ps1','self-repair.ps1','ErrorLibrary.ps1','UAUD-validate.ps1','UAUD.ps1','evidence.ps1','observable-pipeline.json')
$summary=@()
foreach($n in $files){
  $p=Join-Path $Root $n
  $stage='validate-'+([IO.Path]::GetFileNameWithoutExtension($n))
  if(-not(Test-Path -LiteralPath $p)){throw "Required remote artifact missing: $n"}
  if($n -like '*.ps1'){
    $tokens=$null;$errors=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)
    $ok=@($errors).Count -eq 0
    $details=@($errors|ForEach-Object{[ordered]@{message=$_.Message;line=$_.Extent.StartLineNumber;column=$_.Extent.StartColumnNumber}})
  } elseif($n -in @('config.json','observable-pipeline.json')){
    try{$null=Get-Content -LiteralPath $p -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;$ok=$true;$details=@()}catch{$ok=$false;$details=@([ordered]@{message=$_.Exception.Message;line=0;column=0})}
  } else {throw "Unsupported remote validation artifact type: $n"}
  SaveJ $stage 'result.json' ([ordered]@{stage=$stage;file=$n;result=if($ok){'PASS'}else{'FAIL'};errors=$details})
  $summary+=[ordered]@{stage=$stage;result=if($ok){'PASS'}else{'FAIL'};file=$n}
  if(-not $ok){$details|ForEach-Object{Write-Error ($n + ':' + $_.line + ':' + $_.column + ': ' + $_.message)};exit 1}
}
$stage='behaviour';try{$out=& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'sandbox-behaviour.ps1') 2>&1|Out-String;SaveT $stage 'stdout.txt' $out;SaveJ $stage 'result.json' ([ordered]@{stage=$stage;result='PASS';exit_code=0});$summary+=[ordered]@{stage=$stage;result='PASS'}}catch{$e=$_.Exception.Message;SaveT $stage 'stderr.txt' $e;SaveJ $stage 'result.json' ([ordered]@{stage=$stage;result='FAIL';error=$e;exit_code=1});$summary+=[ordered]@{stage=$stage;result='FAIL'};Write-Error $e;exit 1}
SaveJ 'run' 'input.json' ([ordered]@{pipeline=(Get-Content (Join-Path $Root 'observable-pipeline.json') -Raw|ConvertFrom-Json);started_utc=[DateTime]::UtcNow.ToString('o')})
SaveJ 'run' 'result.json' ([ordered]@{result='SUCCESS';stages=$summary;completed_utc=[DateTime]::UtcNow.ToString('o')})
Write-Host "REMOTE UAUD HARNESS PASS"
Write-Host "EVIDENCE_ROOT: $Run"
Write-Host "STAGES: $($summary.Count)"
