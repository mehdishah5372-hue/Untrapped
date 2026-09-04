# Force-first diagnostic sandbox: actual OSblocker 1.0.0 code vs candidate code
# Non-installing. Both implementations run independently with isolated ErrorLibrary files.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$BaselineRef='65fec7380613b0bfd673708cb046795b3d28c7e7'
$BaselineUrl="https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/$BaselineRef/ultra-mode/ErrorLibrary.ps1"
$Candidate=Join-Path $Root 'ErrorLibrary.ps1'
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw ('DIAGNOSTIC SANDBOX FAIL: '+$msg)};Write-Host ('DIAGNOSTIC SANDBOX PASS: '+$msg)}
function Invoke-Library([string]$Library,[object]$Case,[string]$Label){
  $path=Join-Path $env:TEMP ('osb-'+$Label+'-'+[guid]::NewGuid().ToString('N')+'.ps1')
  $events=Join-Path $env:TEMP ('osb-'+$Label+'-events-'+[guid]::NewGuid().ToString('N')+'.jsonl')
  Copy-Item -LiteralPath $Library -Destination $path -Force
  try{
    . $path
    $ErrorLibraryPath=$events
    [void](Scan-ErrorOutput -Source 'diagnostic-sandbox' -Artifact $Case.Name -Lines @($Case.Lines) -ExitCode $Case.Exit -HttpStatus $Case.Http -Stage 'benchmark')
    return @(Get-ErrorLibraryRecords)
  }finally{
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $events -Force -ErrorAction SilentlyContinue
  }
}
function Same([object]$a,[object]$b){
  foreach($p in @('schema','library_version','source','stream','artifact','category','fingerprint','text','exit_code','http_status','candidate_hash','previous_candidate_hash','attempt','repair_action','syntax_result','context')){if([string]$a.$p -ne [string]$b.$p){return $false}}
  return $true
}
try{
  $base=Join-Path $env:TEMP ('osb-baseline-'+[guid]::NewGuid().ToString('N')+'.ps1')
  $wc=New-Object Net.WebClient
  $wc.DownloadString($BaselineUrl)|Set-Content -LiteralPath $base -Encoding UTF8
  Remove-Variable wc -ErrorAction SilentlyContinue
  $bp=Get-Content -Raw -LiteralPath $base
  $cp=Get-Content -Raw -LiteralPath $Candidate
  $bt=$null;$be=$null;$ct=$null;$ce=$null
  [void][System.Management.Automation.Language.Parser]::ParseInput($bp,[ref]$bt,[ref]$be)
  [void][System.Management.Automation.Language.Parser]::ParseInput($cp,[ref]$ct,[ref]$ce)
  Assert (@($be).Count -eq 0) 'pinned baseline parses'
  Assert (@($ce).Count -eq 0) 'candidate parses'
  $cases=@(
    [pscustomobject]@{Name='clean';Lines=@('PASS — all gates passed');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='narrative-error';Lines=@('Error handling regression coverage complete');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='narrative-failure';Lines=@('The previous failure is intentionally reproduced here.');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='narrative-http';Lines=@('HTTP 422 deterministic rejection is a regression fixture.');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='true-error';Lines=@('[ERROR] UARD could not start');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-parser';Lines=@('ParserError: Missing closing }');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-command';Lines=@('The term foo is not recognized as the name of a cmdlet');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-access';Lines=@('Access is denied');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-path';Lines=@('Cannot find the path C:\\missing because it does not exist.');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-timeout';Lines=@('The request timed out.');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-409';Lines=@('HTTP 409 Conflict');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-422';Lines=@('HTTP 422 Unprocessable Entity');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-429';Lines=@('HTTP 429 Too Many Requests');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-redirect';Lines=@('redirect rejected by policy');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-exit';Lines=@('fatal process output');Exit=1;Http=0;Expected=$true},
    [pscustomobject]@{Name='mixed';Lines=@('PASS — all gates passed','ParserError: Missing closing }','This test verifies failure handling safely.');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='multi';Lines=@('Access is denied','ParserError: Missing closing }');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='http-batch';Lines=@('PASS — request fixture captured','request succeeded after retry');Exit=0;Http=422;Expected=$true}
  )
  . $Candidate
  $improvements=0;$blindspotImprovements=0;$retained=0;$downgrades=0;$extras=0;$sustained=0;$filteredBaseline=0
  foreach($case in $cases){
    $b=@(Invoke-Library $base $case 'baseline');$u=@(Invoke-Library $Candidate $case 'candidate')
    $missing=@($b|Where-Object{$x=$_;-not(@($u|Where-Object{Same $_ $x}))})
    $extra=@($u|Where-Object{$x=$_;-not(@($b|Where-Object{Same $_ $x}))})
    $missingHigh=@($missing|Where-Object{(Get-CheckerEvidenceScore $_.text) -ge 50})
    $missingWeak=@($missing|Where-Object{(Get-CheckerEvidenceScore $_.text) -lt 50})
    $extraHigh=@($extra|Where-Object{(Get-CheckerEvidenceScore $_.text) -ge 50})
    $extraWeak=@($extra|Where-Object{(Get-CheckerEvidenceScore $_.text) -lt 50})
    if(-not $case.Expected){
      if($b.Count -gt 0 -and $u.Count -eq 0){$improvements++}elseif($u.Count -gt 0){$retained++}
    } else {
      if($missingHigh.Count -gt 0){$downgrades++}
      elseif($missingWeak.Count -gt 0){$filteredBaseline++}
      elseif($extraWeak.Count -gt 0){$extras++}
      elseif($extraHigh.Count -gt 0){$blindspotImprovements++}
      else{$sustained++}
    }
    Write-Host ('CASE '+$case.Name+': baseline='+$b.Count+' candidate='+$u.Count+' missing_high='+$missingHigh.Count+' missing_weak='+$missingWeak.Count+' extra_high='+$extraHigh.Count+' extra_weak='+$extraWeak.Count)
    foreach($m in $missing){Write-Host ('  MISSING: '+$m.category+' | '+$m.text)}
    foreach($x in $extra){Write-Host ('  EXTRA: '+$x.category+' | '+$x.text)}
  }
  Assert ($downgrades -eq 0) ('no high-confidence baseline diagnostic lost: '+$downgrades)
  Assert ($extras -eq 0) ('no weak/unsubstantiated candidate diagnostics: '+$extras)
  Assert ($retained -eq 0) ('no benchmark false positives retained: '+$retained)
  Assert ($improvements -gt 0 -or $blindspotImprovements -gt 0) ('checker demonstrably improves noisy output or baseline blind spots: improvements='+$improvements+' blindspots='+$blindspotImprovements)
  Write-Host ('RESULT narrative_improvements='+$improvements+' baseline_blind_spot_improvements='+$blindspotImprovements+' sustained='+$sustained+' baseline_weak_filtered='+$filteredBaseline+' retained_false_positives='+$retained+' downgrades='+$downgrades+' weak_extras='+$extras)
  Write-Host 'REPORTER: baseline classification/fingerprint/schema contract preserved.'
  exit 0
}catch{Write-Host ('FAIL-CLOSED: '+$_.Exception.Message);if($base){Remove-Item -LiteralPath $base -Force -ErrorAction SilentlyContinue};exit 1}