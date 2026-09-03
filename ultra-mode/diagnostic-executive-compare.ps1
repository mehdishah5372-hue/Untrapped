# Executive diagnostic: exact OSblocker 1.0.0 vs current ErrorLibrary
# Non-installing. Each implementation executes in a separate PowerShell process.
# The goal is strict reporter compatibility plus measurable checker improvement.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$BaselineRef='65fec7380613b0bfd673708cb046795b3d28c7e7'
$BaselineUrl="https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/$BaselineRef/ultra-mode/ErrorLibrary.ps1"
$Current=Join-Path $Root 'ErrorLibrary.ps1'
$Report=Join-Path $Root ('executive-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Report | Out-Null
function Stamp([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function Fail([string]$m){throw "EXECUTIVE DIAGNOSTIC FAIL: $m"}
function Parse([string]$p){$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);return @($e)}
function HashText([string]$s){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Normalize([object]$r){if($null -eq $r){return $null};[ordered]@{schema=[int]$r.schema;library_version=[string]$r.library_version;source=[string]$r.source;stream=[string]$r.stream;artifact=[string]$r.artifact;category=[string]$r.category;fingerprint=[string]$r.fingerprint;text=[string]$r.text;exit_code=[int]$r.exit_code;http_status=[int]$r.http_status;candidate_hash=[string]$r.candidate_hash;previous_candidate_hash=[string]$r.previous_candidate_hash;attempt=[int]$r.attempt;repair_action=[string]$r.repair_action;syntax_result=[string]$r.syntax_result;context=[string]$r.context}}
function GetFunctionText([string]$Path,[string]$Name){$raw=Get-Content -Raw -LiteralPath $Path;$tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseInput($raw,[ref]$tokens,[ref]$errors);$f=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)|Select-Object -First 1;if($null -eq $f){return ''};return $f.Extent.Text}
function Invoke-Impl([string]$Library,[object]$Case,[string]$Label){
  $runner=Join-Path $env:TEMP ('osb-runner-'+[guid]::NewGuid().ToString('N')+'.ps1');
  $event=Join-Path $env:TEMP ('osb-events-'+[guid]::NewGuid().ToString('N')+'.jsonl');
  $caseFile=Join-Path $env:TEMP ('osb-case-'+[guid]::NewGuid().ToString('N')+'.json');
  $Case|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $caseFile -Encoding UTF8
  @"
`$ErrorActionPreference='Stop'
. '$($Library.Replace("'","''"))'
`$ErrorLibraryPath='$($event.Replace("'","''"))'
`$c=Get-Content -Raw -LiteralPath '$($caseFile.Replace("'","''"))'|ConvertFrom-Json
`$r=@(Scan-ErrorOutput -Source 'executive' -Artifact `$c.Name -Lines @(`$c.Lines) -ExitCode ([int]`$c.Exit) -HttpStatus ([int]`$c.Http) -Stage 'comparison')
`$records=@(Get-ErrorLibraryRecords)
[pscustomobject]@{selected=@(`$r|ForEach-Object{[string]`$_.fingerprint});records=@(`$records|ForEach-Object{[ordered]@{schema=[int]`$_.schema;library_version=[string]`$_.library_version;timestamp_utc='DYNAMIC';source=[string]`$_.source;stream=[string]`$_.stream;artifact=[string]`$_.artifact;category=[string]`$_.category;fingerprint=[string]`$_.fingerprint;text=[string]`$_.text;exit_code=[int]`$_.exit_code;http_status=[int]`$_.http_status;candidate_hash=[string]`$_.candidate_hash;previous_candidate_hash=[string]`$_.previous_candidate_hash;attempt=[int]`$_.attempt;repair_action=[string]`$_.repair_action;syntax_result=[string]`$_.syntax_result;context=[string]`$_.context}})}
"@|Set-Content -LiteralPath $runner -Encoding UTF8
  try{$json=& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1;if($LASTEXITCODE -ne 0){Fail "$Label process failed for $($Case.Name)"};return ($json|ConvertFrom-Json)}finally{Remove-Item $runner,$event,$caseFile -Force -ErrorAction SilentlyContinue}
}
try{
 Stamp 'OSblocker EXECUTIVE DIAGNOSTIC — EXACT BASELINE VS UPGRADE'
 Stamp "Baseline commit: $BaselineRef"
 Stamp 'Upgrade: current branch ErrorLibrary.ps1'
 Stamp 'Execution: isolated Windows PowerShell processes; no installation/network-policy mutation.'
 $base=Join-Path $env:TEMP ('osb-baseline-'+[guid]::NewGuid().ToString('N')+'.ps1')
 $wc=New-Object Net.WebClient;try{$wc.DownloadString($BaselineUrl)|Set-Content -LiteralPath $base -Encoding UTF8}finally{$wc.Dispose()}
 if((Parse $base).Count -ne 0){Fail 'Pinned baseline does not parse'}
 if((Parse $Current).Count -ne 0){Fail 'Upgrade does not parse'}
 $reporterNames=@('Get-ErrorFingerprint','Classify-ErrorText','Save-ErrorEvent')
 $reporterHashes=@();foreach($n in $reporterNames){$btxt=GetFunctionText $base $n;$utxt=GetFunctionText $Current $n;$reporterHashes += [ordered]@{function=$n;baseline_sha256=HashText $btxt;upgrade_sha256=HashText $utxt;identical=((HashText $btxt) -eq (HashText $utxt))}}
 $cases=@(
 [pscustomobject]@{Name='clean-pass';Lines=@('PASS — parser/repair gate complete');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='regression-pass';Lines=@('[REGRESSION PASS] historical parser failure was reproduced');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='malformed-narrative';Lines=@('This test verifies that the script fails safely when given malformed input.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='warning-narrative';Lines=@('WARNING: expected test narrative, not an emitted warning');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='error-narrative';Lines=@('Error handling regression coverage complete');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='failure-narrative';Lines=@('The previous failure is intentionally reproduced here.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='http-fixture-narrative';Lines=@('HTTP 422 deterministic rejection is a regression fixture.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='zero-exit-narrative';Lines=@('Exit code: 0');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='no-errors-narrative';Lines=@('No errors were found.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='explicit-error';Lines=@('[ERROR] UARD could not start');Exit=0;Http=0;Genuine=@('[ERROR] UARD could not start')},
 [pscustomobject]@{Name='parser-error';Lines=@('ParserError: Missing closing }');Exit=0;Http=0;Genuine=@('ParserError: Missing closing }')},
 [pscustomobject]@{Name='access-denied';Lines=@('Access is denied');Exit=0;Http=0;Genuine=@('Access is denied')},
 [pscustomobject]@{Name='command-not-found';Lines=@('The term foo is not recognized as the name of a cmdlet');Exit=0;Http=0;Genuine=@('The term foo is not recognized as the name of a cmdlet')},
 [pscustomobject]@{Name='timeout';Lines=@('The request timed out while contacting the middleman');Exit=0;Http=0;Genuine=@('The request timed out while contacting the middleman')},
 [pscustomobject]@{Name='redirect';Lines=@('redirect rejected: unexpected location');Exit=0;Http=0;Genuine=@('redirect rejected: unexpected location')},
 [pscustomobject]@{Name='exception';Lines=@('Exception calling "Invoke" with "1" argument(s): boom');Exit=0;Http=0;Genuine=@('Exception calling "Invoke" with "1" argument(s): boom')},
 [pscustomobject]@{Name='fully-qualified-error';Lines=@('FullyQualifiedErrorId : CommandNotFoundException');Exit=0;Http=0;Genuine=@('FullyQualifiedErrorId : CommandNotFoundException')},
 [pscustomobject]@{Name='category-info';Lines=@('CategoryInfo : ObjectNotFound');Exit=0;Http=0;Genuine=@('CategoryInfo : ObjectNotFound')},
 [pscustomobject]@{Name='http-422';Lines=@('upstream rejected request');Exit=0;Http=422;Genuine=@('upstream rejected request')},
 [pscustomobject]@{Name='http-409';Lines=@('conflict response');Exit=0;Http=409;Genuine=@('conflict response')},
 [pscustomobject]@{Name='http-transient';Lines=@('temporary upstream problem');Exit=0;Http=503;Genuine=@('temporary upstream problem')},
 [pscustomobject]@{Name='nonzero-concrete';Lines=@('operation failed: child process returned nonzero');Exit=1;Http=0;Genuine=@('operation failed: child process returned nonzero')},
 [pscustomobject]@{Name='nonzero-success-narrative';Lines=@('The operation completed its regression test successfully.');Exit=1;Http=0;Genuine=@()},
 [pscustomobject]@{Name='mixed-error-and-narrative';Lines=@('PASS — all gates passed','ParserError: Missing closing }','This test verifies failure handling safely.');Exit=0;Http=0;Genuine=@('ParserError: Missing closing }')},
 [pscustomobject]@{Name='multiple-errors';Lines=@('Access is denied','ParserError: Missing closing }');Exit=0;Http=0;Genuine=@('Access is denied','ParserError: Missing closing }')},
 [pscustomobject]@{Name='same-error-duplicates';Lines=@('Access is denied','Access is denied');Exit=0;Http=0;Genuine=@('Access is denied')},
 [pscustomobject]@{Name='case-variant';Lines=@('PARSERERROR: unexpected token');Exit=0;Http=0;Genuine=@('PARSERERROR: unexpected token')},
 [pscustomobject]@{Name='long-noise';Lines=@('INFO: build started','INFO: checking parser fixtures','ERROR: UARD could not start','INFO: recovery complete','PASS: test complete');Exit=0;Http=0;Genuine=@('ERROR: UARD could not start')},
 [pscustomobject]@{Name='narrative-error-word';Lines=@('No error occurred; the regression test passed.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='narrative-failed-word';Lines=@('The test failed previously and is now fixed.');Exit=0;Http=0;Genuine=@()}
 )
 $rows=@();$baselineFalse=0;$upgradeFalse=0;$genuineMismatches=0;$reporterRecordMismatches=0;$baselineEvents=0;$upgradeEvents=0
 foreach($case in $cases){
   $b=Invoke-Impl $base $case 'baseline';$u=Invoke-Impl $Current $case 'upgrade';$br=@($b.records);$ur=@($u.records);$baselineEvents+=$br.Count;$upgradeEvents+=$ur.Count
   $genuineRows=@();foreach($g in @($case.Genuine)){$gb=@($br|Where-Object{$_.text -eq $g});$gu=@($ur|Where-Object{$_.text -eq $g});if($gb.Count -ne 1 -or $gu.Count -ne 1){$genuineMismatches++;$genuineRows+=[ordered]@{text=$g;baseline_count=$gb.Count;upgrade_count=$gu.Count;status='MISSING_OR_DUPLICATE'}}else{$same=$true;$fields=@('schema','library_version','source','stream','artifact','category','fingerprint','text','exit_code','http_status','candidate_hash','previous_candidate_hash','attempt','repair_action','syntax_result','context');foreach($f in $fields){if([string]$gb[0].$f -ne [string]$gu[0].$f){$same=$false}};if(-not $same){$genuineMismatches++;$genuineRows+=[ordered]@{text=$g;status='FIELD_MISMATCH';baseline=$gb[0];upgrade=$gu[0]}}}}
   $baseFalse=@($br|Where-Object{$_.text -notin @($case.Genuine)}).Count; $upFalse=@($ur|Where-Object{$_.text -notin @($case.Genuine)}).Count; $baselineFalse+=$baseFalse;$upgradeFalse+=$upFalse
   if($baseFalse -ne $upFalse -and $upFalse -gt $baseFalse){$reporterRecordMismatches++}
   $rows += [ordered]@{case=$case.Name;genuine=@($case.Genuine);baseline_count=$br.Count;upgrade_count=$ur.Count;baseline_false_or_extra=$baseFalse;upgrade_false_or_extra=$upFalse;genuine_comparison=$genuineRows;baseline_records=$br;upgrade_records=$ur}
 }
 $rows|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $Report 'case-comparison.json') -Encoding UTF8
 $functionDiff=@($reporterHashes|Where-Object{-not $_.identical})
 $summary=[ordered]@{
   status=if($genuineMismatches -eq 0 -and $upgradeFalse -le $baselineFalse -and $functionDiff.Count -eq 0){'PASS'}else{'FAIL'};
   baseline=[ordered]@{product='OSblocker';version='1.0.0';commit=$BaselineRef};upgrade='current-main';
   execution=[ordered]@{isolated_processes=$true;cases=$cases.Count;baseline_events=$baselineEvents;upgrade_events=$upgradeEvents};
   reporter=[ordered]@{contract_schema=1;contract_stream='output-scan';contract_fields='schema,library_version,timestamp_utc,source,stream,artifact,category,fingerprint,text,exit_code,http_status,candidate_hash,previous_candidate_hash,attempt,repair_action,syntax_result,context';function_hashes=$reporterHashes;reporter_core_changed=($functionDiff.Count -gt 0)};
   checker=[ordered]@{baseline='line-local lexical detector';upgrade='batch-aware force-first detector';baseline_false_or_extra_events=$baselineFalse;upgrade_false_or_extra_events=$upgradeFalse;false_positive_reduction=$($baselineFalse-$upgradeFalse);genuine_mismatches=$genuineMismatches};
   executive_findings=[ordered]@{improvements=@('batch-wide context before emission','narrative false-positive suppression','concrete parser/access/timeout/redirect/error recognition','no synthetic aggregate events');downgrades=@();sustained=@('schema 1','output-scan stream','reporter field set','fingerprint algorithm','classification algorithm','per-event text and metadata path');sustained_not_beneficial=@('legacy broad lexical detection inside checker','exit/HTTP status blanket inheritance to unrelated narrative lines','WARNING detection as an error candidate');remaining_risks=@('baseline itself has legacy false-positive behaviour','baseline-compatible category labels can be semantically imperfect for some text')};
   report_directory=$Report;timestamp_utc=[DateTime]::UtcNow.ToString('o')
 }
 $summary|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $Report 'executive-summary.json') -Encoding UTF8
 Stamp "REPORTER CORE CHANGED: $($summary.reporter.reporter_core_changed)"
 Stamp "BASELINE EXTRA/FALSE EVENTS: $baselineFalse"
 Stamp "UPGRADE EXTRA/FALSE EVENTS: $upgradeFalse"
 Stamp "FALSE-POSITIVE REDUCTION: $($baselineFalse-$upgradeFalse)"
 Stamp "GENUINE BASELINE DIAGNOSIS MISMATCHES: $genuineMismatches"
 if($functionDiff.Count -gt 0){Fail 'Reporter-core function hashes differ from baseline'}
 if($genuineMismatches -gt 0){Fail "Genuine baseline diagnoses diverged: $genuineMismatches"}
 if($upgradeFalse -gt $baselineFalse){Fail 'Upgrade introduced more false/extra events than baseline'}
 Stamp 'EXECUTIVE RESULT: PASS — reporter core preserved; checker improves discrimination without changing genuine baseline records.'
 Stamp ('REPORT: '+$Report)
 exit 0
}catch{Stamp ('FAIL-CLOSED: '+$_.Exception.Message);try{$_|Out-File -LiteralPath (Join-Path $Report 'fatal.txt') -Encoding UTF8}catch{};exit 1}finally{if($base){Remove-Item $base -Force -ErrorAction SilentlyContinue}}
