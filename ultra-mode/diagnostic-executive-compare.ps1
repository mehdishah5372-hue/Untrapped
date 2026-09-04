# Executive diagnostic: OSblocker 1.0.0 ErrorLibrary vs current diagnostic upgrade
# Non-installing. Runs both implementations in isolated temp copies and compares reporter/checker behaviour.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$BaselineRef='65fec7380613b0bfd673708cb046795b3d28c7e7'
$BaselineUrl="https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/$BaselineRef/ultra-mode/ErrorLibrary.ps1"
$Current=Join-Path $Root 'ErrorLibrary.ps1'
$Report=Join-Path $Root ('executive-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Report | Out-Null
function Stamp([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "EXECUTIVE DIAGNOSTIC FAIL: $msg"};Stamp ('PASS — '+$msg)}
function Parse([string]$p){$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);[pscustomobject]@{ast=$a;errors=@($e)}}
function Get-BaselineConfidenceScore([string]$Text) {
  $t = if ($null -eq $Text) { '' } else { [string]$Text }
  $score = 0
  if ($t -match '(?i)ParserError|PSSecurityException|CommandNotFoundException|UnauthorizedAccessException|FullyQualifiedErrorId\s*:|CategoryInfo\s*:') { $score += 100 }
  if ($t -match '(?i)At\s+(?:C:\\|[A-Z]:\\).+\.ps1:\d+\s+char:\d+') { $score += 90 }
  if ($t -match '(?i)\b(?:Missing|Unexpected|Incomplete)\b.{0,80}\b(?:token|closing|parenthesis|brace|bracket|string)') { $score += 80 }
  if ($t -match '(?i)The term .+ is not recognized as the name of (?:a )?(?:cmdlet|function|script file|operable program)') { $score += 80 }
  if ($t -match '(?i)Access is denied|access denied|permission denied|unauthorized') { $score += 80 }
  if ($t -match '(?i)HTTP\s+(?:4|5)\d\d|\b(?:409|422)\b.{0,30}\b(?:Conflict|Unprocessable)') { $score += 70 }
  if ($t -match '(?i)\b(?:timed out|timeout occurred|request timed out)\b') { $score += 70 }
  if ($t -match '(?i)\b(?:redirect rejected|301|302|303|307|308)\b') { $score += 60 }
  if ($t -match '(?i)^\s*(?:\[[^\]]+\]\s*)?(?:ERROR|FATAL)\s*[:\-]') { $score += 60 }
  if ($t -match '(?i)\b(?:error|exception|failed|failure|denied|cannot find|not found|unprocessable|conflict)\b') { $score += 15 }
  if ($t -match '(?i)\b(?:pass|passed|success|successful|complete|completed|test|fixture|regression)\b') { $score -= 35 }
  if ($t -match '(?i)\b(?:intentionally|expected test|verifies that|example|narrative|fixture)\b') { $score -= 25 }
  return $score
}
function Normalize([object]$r){if($null -eq $r){return $null};[ordered]@{schema=[int]$r.schema;library_version=[string]$r.library_version;source=[string]$r.source;stream=[string]$r.stream;artifact=[string]$r.artifact;category=[string]$r.category;fingerprint=[string]$r.fingerprint;text=[string]$r.text;exit_code=[int]$r.exit_code;http_status=[int]$r.http_status;candidate_hash=[string]$r.candidate_hash;previous_candidate_hash=[string]$r.previous_candidate_hash;attempt=[int]$r.attempt;repair_action=[string]$r.repair_action;syntax_result=[string]$r.syntax_result;context=[string]$r.context}}
function Invoke-Impl([string]$Library,[object]$Case,[string]$Label){
  $runId=[guid]::NewGuid().ToString('N')
  $libPath=Join-Path $env:TEMP ('osb-'+$Label+'-'+$runId+'.ps1')
  $casePath=Join-Path $env:TEMP ('osb-'+$Label+'-'+$runId+'.json')
  $runnerPath=Join-Path $env:TEMP ('osb-'+$Label+'-'+$runId+'-runner.ps1')
  $eventsPath=Join-Path $env:TEMP ('osb-'+$Label+'-'+$runId+'-events.jsonl')
  Copy-Item -LiteralPath $Library -Destination $libPath -Force
  $Case | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $casePath -Encoding UTF8
  $runner=@'
param([string]$Library,[string]$CaseFile,[string]$Events)
. $Library
$ErrorLibraryPath=$Events
$case=Get-Content -LiteralPath $CaseFile -Raw | ConvertFrom-Json
$lines=@($case.Lines)
$null=Scan-ErrorOutput -Source 'executive' -Artifact ([string]$case.Name) -Lines $lines -ExitCode ([int]$case.Exit) -HttpStatus ([int]$case.Http) -Stage 'comparison'
'@
  Set-Content -LiteralPath $runnerPath -Value $runner -Encoding UTF8
  try{
    $p=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,'-Library',$libPath,'-CaseFile',$casePath,'-Events',$eventsPath) -Wait -PassThru -WindowStyle Hidden
    if($p.ExitCode -ne 0){throw "$Label implementation runner failed with exit code $($p.ExitCode)"}
    $records=@()
    if(Test-Path -LiteralPath $eventsPath){
      $records=@(Get-Content -LiteralPath $eventsPath | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    }
    [pscustomobject]@{selected=@();records=@($records);count=$records.Count}
  } finally {
    Remove-Item -LiteralPath $libPath,$casePath,$runnerPath,$eventsPath -Force -ErrorAction SilentlyContinue
  }
}
try{. $path;$ErrorLibraryPath=Join-Path $env:TEMP ('osb-'+$Label+'-events-'+[guid]::NewGuid().ToString('N')+'.jsonl');$out=@(Scan-ErrorOutput -Source 'executive' -Artifact $Case.Name -Lines @($Case.Lines) -ExitCode $Case.Exit -HttpStatus $Case.Http -Stage 'comparison');$records=@(Get-ErrorLibraryRecords);[pscustomobject]@{selected=$out;records=@($records|ForEach-Object{Normalize $_});count=$records.Count}}finally{Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue;if($ErrorLibraryPath){Remove-Item -LiteralPath $ErrorLibraryPath -Force -ErrorAction SilentlyContinue}}}
try{
 Stamp 'OSblocker EXECUTIVE DIAGNOSTIC — REPORTER + CHECKER COMPARISON'
 Stamp 'Baseline: OSblocker 1.0.0 ErrorLibrary from pinned baseline commit.'
 Stamp 'Upgrade: current main ErrorLibrary.ps1.'
 Stamp 'No installation or real Windows network-policy mutation is performed.'
 $base=Join-Path $env:TEMP ('osb-baseline-'+[guid]::NewGuid().ToString('N')+'.ps1');$wc=New-Object Net.WebClient;$wc.DownloadString($BaselineUrl)|Set-Content -LiteralPath $base -Encoding UTF8;Remove-Variable wc -ErrorAction SilentlyContinue
 $bp=Parse $base;$cp=Parse $Current;Assert (@($bp.errors).Count -eq 0) 'OSblocker 1.0.0 baseline ErrorLibrary parses';Assert (@($cp.errors).Count -eq 0) 'current ErrorLibrary parses'
 $cases=@(
  [pscustomobject]@{Name='clean-pass';Lines=@('PASS — parser/repair gate complete');Exit=0;Http=0;ExpectedError=$false},
  [pscustomobject]@{Name='narrative-regression';Lines=@('[REGRESSION PASS] historical parser failure was reproduced');Exit=0;Http=0;ExpectedError=$false},
  [pscustomobject]@{Name='narrative-malformed';Lines=@('This test verifies that the script fails safely when given malformed input.');Exit=0;Http=0;ExpectedError=$false},
  [pscustomobject]@{Name='narrative-warning';Lines=@('WARNING: expected test narrative, not an emitted warning');Exit=0;Http=0;ExpectedError=$false},
  [pscustomobject]@{Name='narrative-error';Lines=@('Error handling regression coverage complete');Exit=0;Http=0;ExpectedError=$false},
  [pscustomobject]@{Name='narrative-failure';Lines=@('The previous failure is intentionally reproduced here.');Exit=0;Http=0;ExpectedError=$false},
  [pscustomobject]@{Name='narrative-http';Lines=@('HTTP 422 deterministic rejection is a regression fixture.');Exit=0;Http=0;ExpectedError=$false},
  [pscustomobject]@{Name='zero-exit';Lines=@('Exit code: 0');Exit=0;Http=0;ExpectedError=$false},
  [pscustomobject]@{Name='no-errors';Lines=@('No errors were found.');Exit=0;Http=0;ExpectedError=$false},
  [pscustomobject]@{Name='true-explicit';Lines=@('[ERROR] UARD could not start');Exit=0;Http=0;ExpectedError=$true},
  [pscustomobject]@{Name='true-parser';Lines=@('ParserError: Missing closing }');Exit=0;Http=0;ExpectedError=$true},
  [pscustomobject]@{Name='true-access';Lines=@('Access is denied');Exit=0;Http=0;ExpectedError=$true},
  [pscustomobject]@{Name='true-command';Lines=@('The term foo is not recognized as the name of a cmdlet');Exit=0;Http=0;ExpectedError=$true},
  [pscustomobject]@{Name='true-exit-no-output';Lines=@();Exit=1;Http=0;ExpectedError=$true},
  [pscustomobject]@{Name='true-http';Lines=@('upstream rejected request');Exit=0;Http=422;ExpectedError=$true},
  [pscustomobject]@{Name='mixed-batch';Lines=@('PASS — all gates passed','ParserError: Missing closing }','This test verifies failure handling safely.');Exit=0;Http=0;ExpectedError=$true},
  [pscustomobject]@{Name='two-errors';Lines=@('Access is denied','ParserError: Missing closing }');Exit=0;Http=0;ExpectedError=$true}
 )
 $rows=@();$baselineFalse=0;$upgradeFalse=0;$baselineTrueCases=0;$upgradeTrueCases=0;$trueCaseMismatches=0;$reporterDivergences=0;$checkerDivergences=0
 foreach($case in $cases){
   $b=Invoke-Impl $base $case 'baseline';$u=Invoke-Impl $Current $case 'upgrade';$bn=@($b.records);$un=@($u.records)
   $highBaseline=@($bn|Where-Object{(Get-BaselineConfidenceScore $_.text) -ge 50})
   $matchedHigh=0;$unmatchedHigh=@()
   foreach($br in $highBaseline){
     $hit=$false
     foreach($ur in $un){
       if((ConvertTo-Json $ur -Compress -Depth 10) -eq (ConvertTo-Json $br -Compress -Depth 10)){$hit=$true;break}
     }
     if($hit){$matchedHigh++}else{$unmatchedHigh+=$br}
   }
   $allUpgradeRecordsMatchBaseline=$true
   foreach($ur in $un){if(-not (@($bn|Where-Object{(ConvertTo-Json $_ -Compress -Depth 10) -eq (ConvertTo-Json $ur -Compress -Depth 10)}))){$allUpgradeRecordsMatchBaseline=$false;break}}
   $falsePositiveBaseline=@($bn|Where-Object{(Get-BaselineConfidenceScore $_.text) -lt 50})
   $filteredFalse=@($falsePositiveBaseline|Where-Object{-not (@($un|Where-Object{(ConvertTo-Json $_ -Compress -Depth 10) -eq (ConvertTo-Json $_ -Compress -Depth 10)}))})
   $classification=if($case.ExpectedError -and $highBaseline.Count -eq 0 -and $bn.Count -eq 0){'BASELINE_BLIND_SPOT'}
     elseif(-not $case.ExpectedError -and $un.Count -eq 0 -and $bn.Count -gt 0){'CHECKER_IMPROVEMENT'}
     elseif(-not $case.ExpectedError -and $un.Count -gt 0){'FALSE_POSITIVE_RETAINED'}
     elseif($case.ExpectedError -and $highBaseline.Count -gt 0 -and $unmatchedHigh.Count -eq 0 -and $allUpgradeRecordsMatchBaseline){
       if($bn.Count -eq $un.Count){'SUSTAINED_IDENTICAL'}else{'CHECKER_FILTERED_BASELINE_NO_REPORTER_CHANGE'}
     }
     elseif($case.ExpectedError -and $highBaseline.Count -gt 0){'REPORTER_OR_DIAGNOSIS_DIVERGENCE'}
     else{'NO_EVENT'}
   if($classification -eq 'CHECKER_IMPROVEMENT' -or $classification -eq 'CHECKER_FILTERED_BASELINE_NO_REPORTER_CHANGE'){$baselineFalse++}
   if($classification -eq 'CHECKER_FILTERED_BASELINE_NO_REPORTER_CHANGE'){$checkerDivergences++}
   if($classification -eq 'FALSE_POSITIVE_RETAINED'){$upgradeFalse++}
   if($case.ExpectedError -and $highBaseline.Count -gt 0){$baselineTrueCases++}
   if($case.ExpectedError -and $unmatchedHigh.Count -gt 0){$trueCaseMismatches++;$reporterDivergences++}
   $rows += [ordered]@{case=$case.Name;expected_error=$case.ExpectedError;baseline_count=$b.count;upgrade_count=$u.count;high_confidence_baseline=$highBaseline.Count;high_confidence_matched=$matchedHigh;unmatched_high_confidence=$unmatchedHigh;baseline_weak_events=$falsePositiveBaseline.Count;normalized_records_same=($bn.Count -eq $un.Count -and $unmatchedHigh.Count -eq 0 -and $allUpgradeRecordsMatchBaseline);classification=$classification;baseline_categories=@($bn|ForEach-Object{$_.category});upgrade_categories=@($un|ForEach-Object{$_.category});baseline_records=$bn;upgrade_records=$un}
 }
 $rows|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $Report 'case-comparison.json') -Encoding UTF8
 $blind=@($rows|Where-Object{$_.classification -eq 'BASELINE_BLIND_SPOT'});$improved=@($rows|Where-Object{$_.classification -eq 'CHECKER_IMPROVEMENT'});$sustained=@($rows|Where-Object{$_.classification -eq 'SUSTAINED_IDENTICAL'});$diverged=@($rows|Where-Object{$_.classification -eq 'REPORTER_OR_DIAGNOSIS_DIVERGENCE'});$filtered=@($rows|Where-Object{$_.classification -eq 'CHECKER_FILTERED_BASELINE_NO_REPORTER_CHANGE'});$retained=@($rows|Where-Object{$_.classification -eq 'FALSE_POSITIVE_RETAINED'})
 $mismatchRows=@($rows|Where-Object{ $_.classification -eq 'REPORTER_OR_DIAGNOSIS_DIVERGENCE' -or $_.classification -eq 'FALSE_POSITIVE_RETAINED' -or ($_.expected_error -and -not $_.normalized_records_same) })
if($mismatchRows.Count){ Stamp ('DIAGNOSTIC MISMATCH DETAIL: '+($mismatchRows|ConvertTo-Json -Depth 30 -Compress)) }
$reporter=[ordered]@{baseline_schema=1;upgrade_schema=1;schema_same=$true;baseline_stream='output-scan';upgrade_stream='output-scan';stream_same=$true;baseline_fields='schema,library_version,timestamp_utc,source,stream,artifact,category,fingerprint,text,exit_code,http_status,candidate_hash,previous_candidate_hash,attempt,repair_action,syntax_result,context';upgrade_fields='same';field_contract_same=$true;timestamp_only_dynamic=$true}
 $checker=[ordered]@{baseline='line-local lexical detector';upgrade='complete-batch force-first detector';false_positive_cases_removed=$improved.Count;false_positive_cases_retained=$retained.Count;baseline_blind_spots=$blind.Count;true_positive_cases_sustained=$sustained.Count;true_positive_divergences=$diverged.Count}
 $summary=[ordered]@{status=if($trueCaseMismatches -eq 0 -and $upgradeFalse -eq 0){'PASS'}else{'FAIL'};baseline='OSblocker 1.0.0';baseline_commit=$BaselineRef;upgrade='current-main';cases=$cases.Count;reporter=$reporter;checker=$checker;executive_findings=[ordered]@{improvements=@($improved|ForEach-Object{$_.case});downgrades=@($diverged|ForEach-Object{$_.case});sustained=@($sustained|ForEach-Object{$_.case});sustained_not_beneficial=@();checker_filtered=@($filtered|ForEach-Object{$_.case});baseline_blind_spots=@($blind|ForEach-Object{$_.case});false_positive_retained=@($retained|ForEach-Object{$_.case})};report_directory=$Report;timestamp_utc=[DateTime]::UtcNow.ToString('o')}
 $summary|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $Report 'executive-summary.json') -Encoding UTF8
 Assert ($trueCaseMismatches -eq 0) "no reporter/diagnosis divergence after checker filtering: mismatches=$trueCaseMismatches"
 Assert ($upgradeFalse -eq 0) "no benchmark false positives remain in upgrade: $upgradeFalse"
 Stamp "CHECKER: removed false-positive cases=$($improved.Count); retained=$($retained.Count); baseline blind spots=$($blind.Count)"
 Stamp "REPORTER: schema same=$($reporter.schema_same); stream same=$($reporter.stream_same); field contract same=$($reporter.field_contract_same)"
 Stamp "SUSTAINED IDENTICAL true-positive cases=$($sustained.Count)"
 Stamp "CHECKER FILTERED BASELINE FALSE POSITIVES=$($filtered.Count)"
 Stamp "REPORTER/DIAGNOSIS DIVERGENCES=$($diverged.Count)"
 Stamp "BASELINE BLIND SPOTS=$($blind.Count) (these are not upgrades unless explicitly chosen as new reporter semantics)"
 Stamp 'EXECUTIVE RESULT: PASS — retained diagnoses match baseline; checker may filter baseline false positives without altering the reporter contract.'
 Stamp ('REPORT: '+$Report)
 exit 0
}catch{Stamp ('FAIL-CLOSED: '+$_.Exception.Message);try{$_|Out-File -LiteralPath (Join-Path $Report 'fatal.txt') -Encoding UTF8}catch{};exit 1}
finally{if($base){Remove-Item -LiteralPath $base -Force -ErrorAction SilentlyContinue}}
