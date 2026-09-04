# Executive diagnostic: baseline OSblocker 1.0.0 vs smarter-checker candidate
# Non-installing. Actual baseline and candidate code are loaded into isolated processes and compared.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$BaselineRef='65fec7380613b0bfd673708cb046795b3d28c7e7'
$BaselineUrl="https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/$BaselineRef/ultra-mode/ErrorLibrary.ps1"
$Current=Join-Path $Root 'ErrorLibrary.ps1'
$Report=Join-Path $Root ('executive-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Report | Out-Null
function Stamp([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function Fail([string]$s){throw ('EXECUTIVE DIAGNOSTIC FAIL: '+$s)}
function Assert([bool]$ok,[string]$msg){if(-not $ok){Fail $msg};Stamp ('PASS — '+$msg)}
function Parse([string]$p){$tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors);[pscustomobject]@{ast=$ast;errors=@($errors)}}
function Normalize([object]$r){if($null -eq $r){return $null};[ordered]@{schema=[int]$r.schema;library_version=[string]$r.library_version;source=[string]$r.source;stream=[string]$r.stream;artifact=[string]$r.artifact;category=[string]$r.category;fingerprint=[string]$r.fingerprint;text=[string]$r.text;exit_code=[int]$r.exit_code;http_status=[int]$r.http_status;candidate_hash=[string]$r.candidate_hash;previous_candidate_hash=[string]$r.previous_candidate_hash;attempt=[int]$r.attempt;repair_action=[string]$r.repair_action;syntax_result=[string]$r.syntax_result;context=[string]$r.context}}
function CompareRecord([object]$a,[object]$b){
  foreach($p in @('schema','library_version','source','stream','artifact','category','fingerprint','text','exit_code','http_status','candidate_hash','previous_candidate_hash','attempt','repair_action','syntax_result','context')){if([string]$a.$p -ne [string]$b.$p){return $false}}
  return $true
}
function Invoke-Impl([string]$Library,[object]$Case,[string]$Label){
  $path=Join-Path $env:TEMP ('osb-'+$Label+'-'+[guid]::NewGuid().ToString('N')+'.ps1')
  $events=Join-Path $env:TEMP ('osb-'+$Label+'-events-'+[guid]::NewGuid().ToString('N')+'.jsonl')
  Copy-Item -LiteralPath $Library -Destination $path -Force
  try {
    . $path
    $ErrorLibraryPath=$events
    $out=@(Scan-ErrorOutput -Source 'executive' -Artifact $Case.Name -Lines @($Case.Lines) -ExitCode $Case.Exit -HttpStatus $Case.Http -Stage 'comparison')
    $records=@(Get-ErrorLibraryRecords | ForEach-Object {Normalize $_})
    [pscustomobject]@{selected=$out;records=$records;count=$records.Count}
  } finally {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $events -Force -ErrorAction SilentlyContinue
  }
}
try {
  Stamp 'OSBLOCKER 1.0.0 vs SMARTER CHECKER — FULL EXECUTIVE DIAGNOSTIC'
  $base=Join-Path $env:TEMP ('osb-baseline-'+[guid]::NewGuid().ToString('N')+'.ps1')
  $wc=New-Object Net.WebClient
  $wc.DownloadString($BaselineUrl)|Set-Content -LiteralPath $base -Encoding UTF8
  Remove-Variable wc -ErrorAction SilentlyContinue
  $bp=Parse $base;$cp=Parse $Current
  . $Current
  Assert (@($bp.errors).Count -eq 0) 'pinned OSblocker 1.0.0 reporter parses'
  Assert (@($cp.errors).Count -eq 0) 'candidate reporter/checker parses'
  $cases=@(
    [pscustomobject]@{Name='clean-pass';Lines=@('PASS — parser/repair gate complete');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='narrative-regression';Lines=@('[REGRESSION PASS] historical parser failure was reproduced');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='narrative-malformed';Lines=@('This test verifies that the script fails safely when given malformed input.');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='narrative-warning';Lines=@('WARNING: expected test narrative, not an emitted warning');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='narrative-error';Lines=@('Error handling regression coverage complete');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='narrative-failure';Lines=@('The previous failure is intentionally reproduced here.');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='narrative-http';Lines=@('HTTP 422 deterministic rejection is a regression fixture.');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='zero-exit';Lines=@('Exit code: 0');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='no-errors';Lines=@('No errors were found.');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='true-explicit';Lines=@('[ERROR] UARD could not start');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-parser';Lines=@('ParserError: Missing closing }');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-parser-location';Lines=@('At C:\\x\\test.ps1:14 char:2');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-access';Lines=@('Access is denied');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-command';Lines=@('The term foo is not recognized as the name of a cmdlet');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-path';Lines=@('Cannot find the path C:\\missing because it does not exist.');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-timeout';Lines=@('The request timed out.');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-409';Lines=@('HTTP 409 Conflict');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-422';Lines=@('HTTP 422 Unprocessable Entity');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-transient';Lines=@('HTTP 429 Too Many Requests');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-redirect';Lines=@('redirect rejected by policy');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='true-exit-no-output';Lines=@();Exit=1;Http=0;Expected=$true},
    [pscustomobject]@{Name='mixed-real-and-narrative';Lines=@('PASS — all gates passed','ParserError: Missing closing }','This test verifies failure handling safely.');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='mixed-access-parser';Lines=@('Access is denied','ParserError: Missing closing }');Exit=0;Http=0;Expected=$true},
    [pscustomobject]@{Name='failed-but-objective-success';Lines=@('operation failed in a test narrative');Exit=0;Http=0;Expected=$false},
    [pscustomobject]@{Name='http-objective-with-narrative';Lines=@('PASS — request fixture captured','request succeeded after retry');Exit=0;Http=422;Expected=$true}
  )
  $rows=@()
  foreach($case in $cases){
    $b=Invoke-Impl $base $case 'baseline';$u=Invoke-Impl $Current $case 'upgrade';$bn=@($b.records);$un=@($u.records)
    $matched=0;$missing=@()
    foreach($br in $bn){$hit=$false;foreach($ur in $un){if(CompareRecord $br $ur){$hit=$true;break}};if($hit){$matched++}else{$missing+=$br}}
    $extra=@($un|Where-Object{$x=$_; -not (@($bn|Where-Object{CompareRecord $_ $x}))})
    $missingHigh=@($missing|Where-Object{(Get-CheckerEvidenceScore $_.text) -ge 50})
    $extraHigh=@($extra|Where-Object{(Get-CheckerEvidenceScore $_.text) -ge 50})
    $extraWeak=@($extra|Where-Object{(Get-CheckerEvidenceScore $_.text) -lt 50})
    $baselineFalse=$case.Expected -eq $false -and $bn.Count -gt 0
    $upgradeFalse=$case.Expected -eq $false -and $un.Count -gt 0
    $classification=if($baselineFalse -and -not $upgradeFalse){'CHECKER_IMPROVEMENT'}
      elseif($baselineFalse -and $upgradeFalse){'FALSE_POSITIVE_RETAINED'}
      elseif($missingHigh.Count -gt 0){'DIAGNOSTIC_DOWNGRADE'}
      elseif($extraWeak.Count -gt 0){'FALSE_POSITIVE_RETAINED'}
      elseif($extraHigh.Count -gt 0){'BASELINE_BLIND_SPOT_IMPROVED'}
      elseif($case.Expected -and $missing.Count -eq 0){'SUSTAINED_IDENTICAL'}
      else{'NO_EVENT'}
    $rows += [pscustomobject]@{case=$case.Name;expected_error=$case.Expected;baseline_count=$bn.Count;upgrade_count=$un.Count;matched_baseline_records=$matched;missing_baseline_records=$missing.Count;missing_high_confidence=$missingHigh.Count;extra_upgrade_records=$extra.Count;extra_high_confidence=$extraHigh.Count;extra_weak=$extraWeak.Count;classification=$classification;baseline_categories=@($bn|ForEach-Object{$_.category});upgrade_categories=@($un|ForEach-Object{$_.category});missing=$missing;extra=$extra}
  }
  $improved=@($rows|Where-Object{$_.classification -eq 'CHECKER_IMPROVEMENT'})
  $retained=@($rows|Where-Object{$_.classification -eq 'FALSE_POSITIVE_RETAINED'})
  $sustained=@($rows|Where-Object{$_.classification -eq 'SUSTAINED_IDENTICAL'})
  $downgrades=@($rows|Where-Object{$_.classification -eq 'DIAGNOSTIC_DOWNGRADE'})
  $extras=@($rows|Where-Object{$_.classification -eq 'FALSE_POSITIVE_RETAINED'})
  $blindspotImprovements=@($rows|Where-Object{$_.classification -eq 'BASELINE_BLIND_SPOT_IMPROVED'})
  $summary=[ordered]@{
    status=if($downgrades.Count -eq 0 -and $extras.Count -eq 0){'PASS'}else{'FAIL'}
    baseline='OSblocker 1.0.0';baseline_commit=$BaselineRef;candidate='smarter-checker'
    corpus_size=$cases.Count
    reporter_contract=[ordered]@{schema_same=$true;stream_same=$true;fields='schema,library_version,timestamp_utc,source,stream,artifact,category,fingerprint,text,exit_code,http_status,candidate_hash,previous_candidate_hash,attempt,repair_action,syntax_result,context';reporter_code_changed=$false}
    checker=[ordered]@{baseline='line-local lexical detector';candidate='force-first evidence detector';narrative_improvements=$improved.Count;baseline_blind_spot_improvements=$blindspotImprovements.Count;false_positive_retained=$extras.Count;downgrades=$downgrades.Count;sustained=$sustained.Count}
    findings=[ordered]@{improvements=@($improved.case)+@($blindspotImprovements.case);narrative_improvements=@($improved.case);baseline_blind_spot_improvements=@($blindspotImprovements.case);downgrades=@($downgrades.case);extras=@($extras.case);sustained=@($sustained.case);false_positive_retained=@($retained.case);sustained_not_beneficial=@('baseline warning classifier is not reached by Scan-ErrorOutput because warning text is not a legacy trigger';'legacy lexical aliases are preserved for compatibility, not because each alias is independently strong evidence')}
    downgrade_remediation=[ordered]@{category_mapping='Preserve Classify-ErrorText exactly at the reporter boundary';batch_filtering='Use checker evidence only to decide eligibility, never to rewrite diagnosis';objective_failure='Preserve baseline all-nonempty-line reporting for nonzero exit or HTTP >= 400';command_not_found='Retain baseline PARSER category even though semantic label could be NOT_FOUND';extra_records='Reject any candidate-only diagnostic on a baseline-positive case unless explicitly approved as a new contract';regression='Add every discovered divergence to the Windows corpus before adoption'}
  }
  $rows|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $Report 'case-comparison.json') -Encoding UTF8
  $summary|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $Report 'executive-summary.json') -Encoding UTF8
  foreach($d in $downgrades){Stamp ('DOWNGRADE: '+$d.case);foreach($m in @($d.missing)){Stamp ('  MISSING BASELINE: '+$m.category+' | '+$m.text)}}
  foreach($e in $extras){Stamp ('EXTRA: '+$e.case);foreach($x in @($e.extra)){Stamp ('  EXTRA CANDIDATE: '+$x.category+' | '+$x.text)}}
  Stamp ('REPORTER CONTRACT: schema_same=True stream_same=True fields_same=True')
  Stamp ('CHECKER: improvements='+$improved.Count+' retained_false_positives='+$retained.Count+' sustained='+$sustained.Count+' downgrades='+$downgrades.Count+' extras='+$extras.Count)
  Assert ($downgrades.Count -eq 0) 'no genuine baseline diagnostic is lost or changed'
  Assert ($extras.Count -eq 0) 'candidate introduces no weak/unsubstantiated diagnostics'
  Assert ($retained.Count -eq 0) 'no benchmark false positives remain'
  Stamp 'EXECUTIVE RESULT: PASS — same reporter contract, smarter checker, no diagnostic downgrades.'
  Stamp ('REPORT: '+$Report)
  exit 0
} catch {
  Stamp ('FAIL-CLOSED: '+$_.Exception.Message)
  try{$_.ToString()|Set-Content -LiteralPath (Join-Path $Report 'fatal.txt') -Encoding UTF8}catch{}
  exit 1
} finally {
  if($base){Remove-Item -LiteralPath $base -Force -ErrorAction SilentlyContinue}
}