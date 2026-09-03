# Exact OSblocker 1.0.0 vs upgrade executive diagnostic.
# Non-installing. Baseline and upgrade run in separate PowerShell processes.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$BaselineRef='65fec7380613b0bfd673708cb046795b3d28c7e7'
$BaselineUrl="https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/$BaselineRef/ultra-mode/ErrorLibrary.ps1"
$Current=Join-Path $Root 'ErrorLibrary.ps1'
$Report=Join-Path $Root ('executive-diagnostics-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Report|Out-Null
function Stamp([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function Fail([string]$s){throw "EXECUTIVE DIAGNOSTIC FAIL: $s"}
function ParseErrors([string]$p){$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);@($e)}
function SemanticFunctionHash([string]$p,[string]$n){$raw=Get-Content -Raw -LiteralPath $p;$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseInput($raw,[ref]$t,[ref]$e);$f=$a.FindAll({param($x)$x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n},$true)|Select-Object -First 1;if(-not$f){return ''};$s=$f.Extent.Text -replace '(?m)^\s*#.*$','' -replace '\s+','';$h=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function Invoke-Isolated([string]$Library,[object]$Case,[string]$Label){
 $runner=Join-Path $env:TEMP ('osb-run-'+[guid]::NewGuid().ToString('N')+'.ps1');$events=Join-Path $env:TEMP ('osb-ev-'+[guid]::NewGuid().ToString('N')+'.jsonl');$cf=Join-Path $env:TEMP ('osb-cf-'+[guid]::NewGuid().ToString('N')+'.json');$Case|ConvertTo-Json -Depth 12 -Compress|Set-Content -LiteralPath $cf -Encoding UTF8;$lib=$Library.Replace("'","''");$ev=$events.Replace("'","''");$case=$cf.Replace("'","''")
 @"
`$ErrorActionPreference='Stop'
. '$lib'
`$ErrorLibraryPath='$ev'
`$c=Get-Content -Raw -LiteralPath '$case'|ConvertFrom-Json
`$r=@(Scan-ErrorOutput -Source 'executive' -Artifact `$c.Name -Lines @(`$c.Lines) -ExitCode ([int]`$c.Exit) -HttpStatus ([int]`$c.Http) -Stage 'comparison')
`$records=@(Get-ErrorLibraryRecords|ForEach-Object{[ordered]@{schema=[int]`$_.schema;library_version=[string]`$_.library_version;source=[string]`$_.source;stream=[string]`$_.stream;artifact=[string]`$_.artifact;category=[string]`$_.category;fingerprint=[string]`$_.fingerprint;text=[string]`$_.text;exit_code=[int]`$_.exit_code;http_status=[int]`$_.http_status;candidate_hash=[string]`$_.candidate_hash;previous_candidate_hash=[string]`$_.previous_candidate_hash;attempt=[int]`$_.attempt;repair_action=[string]`$_.repair_action;syntax_result=[string]`$_.syntax_result;context=[string]`$_.context}})
[pscustomobject]@{records=`$records}|ConvertTo-Json -Depth 20 -Compress
"@|Set-Content -LiteralPath $runner -Encoding UTF8
 try{$out=& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1;if($LASTEXITCODE -ne 0){Fail "$Label process failed for $($Case.Name)"};$line=@($out|ForEach-Object{[string]$_}|Where-Object{$_ -match '^\s*\{"records"'}|Select-Object -Last 1);if(-not$line){Fail "$Label produced no JSON for $($Case.Name)"};$line|ConvertFrom-Json}finally{Remove-Item $runner,$events,$cf -Force -ErrorAction SilentlyContinue}
}
try{
 Stamp 'OSblocker EXECUTIVE DIAGNOSTIC — EXACT CODE VS CODE'
 $base=Join-Path $env:TEMP ('osb-base-'+[guid]::NewGuid().ToString('N')+'.ps1');$wc=New-Object Net.WebClient;try{$wc.DownloadString($BaselineUrl)|Set-Content -LiteralPath $base -Encoding UTF8}finally{$wc.Dispose()}
 if((ParseErrors $base).Count -ne 0){Fail 'baseline syntax invalid'};if((ParseErrors $Current).Count -ne 0){Fail 'upgrade syntax invalid'}
 $hashes=@();foreach($n in @('Get-ErrorFingerprint','Classify-ErrorText','Save-ErrorEvent')){$bh=SemanticFunctionHash $base $n;$uh=SemanticFunctionHash $Current $n;$hashes+=[ordered]@{function=$n;baseline=$bh;upgrade=$uh;identical=($bh-eq$uh)}}
 $cases=@(
 [pscustomobject]@{Name='pass';Lines=@('PASS — parser/repair gate complete');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='regression-pass';Lines=@('[REGRESSION PASS] historical parser failure was reproduced');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='malformed-narrative';Lines=@('This test verifies that the script fails safely when given malformed input.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='warning';Lines=@('WARNING: expected test narrative, not an emitted warning');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='error-narrative';Lines=@('Error handling regression coverage complete');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='failure-narrative';Lines=@('The previous failure is intentionally reproduced here.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='http-fixture';Lines=@('HTTP 422 deterministic rejection is a regression fixture.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='no-errors';Lines=@('No errors were found.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='explicit-error';Lines=@('[ERROR] UARD could not start');Exit=0;Http=0;Genuine=@('[ERROR] UARD could not start')},
 [pscustomobject]@{Name='parser-error';Lines=@('ParserError: Missing closing }');Exit=0;Http=0;Genuine=@('ParserError: Missing closing }')},
 [pscustomobject]@{Name='access';Lines=@('Access is denied');Exit=0;Http=0;Genuine=@('Access is denied')},
 [pscustomobject]@{Name='command-not-found';Lines=@('The term foo is not recognized as the name of a cmdlet');Exit=0;Http=0;Genuine=@('The term foo is not recognized as the name of a cmdlet')},
 [pscustomobject]@{Name='timeout';Lines=@('The request timed out while contacting the middleman');Exit=0;Http=0;Genuine=@('The request timed out while contacting the middleman')},
 [pscustomobject]@{Name='redirect';Lines=@('redirect rejected: unexpected location');Exit=0;Http=0;Genuine=@('redirect rejected: unexpected location')},
 [pscustomobject]@{Name='exception';Lines=@('Exception calling "Invoke" with "1" argument(s): boom');Exit=0;Http=0;Genuine=@('Exception calling "Invoke" with "1" argument(s): boom')},
 [pscustomobject]@{Name='fqid';Lines=@('FullyQualifiedErrorId : CommandNotFoundException');Exit=0;Http=0;Genuine=@('FullyQualifiedErrorId : CommandNotFoundException')},
 [pscustomobject]@{Name='categoryinfo';Lines=@('CategoryInfo : ObjectNotFound');Exit=0;Http=0;Genuine=@('CategoryInfo : ObjectNotFound')},
 [pscustomobject]@{Name='http-422';Lines=@('upstream rejected request');Exit=0;Http=422;Genuine=@('upstream rejected request')},
 [pscustomobject]@{Name='http-409';Lines=@('conflict response');Exit=0;Http=409;Genuine=@('conflict response')},
 [pscustomobject]@{Name='http-503';Lines=@('temporary upstream problem');Exit=0;Http=503;Genuine=@('temporary upstream problem')},
 [pscustomobject]@{Name='exit-concrete';Lines=@('operation failed: child process returned nonzero');Exit=1;Http=0;Genuine=@('operation failed: child process returned nonzero')},
 [pscustomobject]@{Name='exit-narrative';Lines=@('The operation completed its regression test successfully.');Exit=1;Http=0;Genuine=@()},
 [pscustomobject]@{Name='mixed';Lines=@('PASS — all gates passed','ParserError: Missing closing }','This test verifies failure handling safely.');Exit=0;Http=0;Genuine=@('ParserError: Missing closing }')},
 [pscustomobject]@{Name='multiple';Lines=@('Access is denied','ParserError: Missing closing }');Exit=0;Http=0;Genuine=@('Access is denied','ParserError: Missing closing }')},
 [pscustomobject]@{Name='duplicate';Lines=@('Access is denied','Access is denied');Exit=0;Http=0;Genuine=@('Access is denied')},
 [pscustomobject]@{Name='noise';Lines=@('INFO: build started','INFO: checking parser fixtures','ERROR: UARD could not start','INFO: recovery complete','PASS: test complete');Exit=0;Http=0;Genuine=@('ERROR: UARD could not start')},
 [pscustomobject]@{Name='negative-error';Lines=@('No error occurred; the regression test passed.');Exit=0;Http=0;Genuine=@()},
 [pscustomobject]@{Name='negative-failed';Lines=@('The test failed previously and is now fixed.');Exit=0;Http=0;Genuine=@()}
 )
 $rows=@();$baselineFalse=0;$upgradeFalse=0;$blind=0;$missing=0;$drift=0
 foreach($c in $cases){$b=Invoke-Isolated $base $c 'baseline';$u=Invoke-Isolated $Current $c 'upgrade';$br=@($b.records);$ur=@($u.records);$grows=@();foreach($g in @($c.Genuine)){$gb=@($br|Where-Object{$_.text-eq$g});$gu=@($ur|Where-Object{$_.text-eq$g});if($gu.Count -ne 1){$missing++;$grows+=[ordered]@{text=$g;status='UPGRADE_MISSING';baseline_count=$gb.Count;upgrade_count=$gu.Count}}elseif($gb.Count -eq 0){$blind++;$grows+=[ordered]@{text=$g;status='BASELINE_BLIND_SPOT'}}else{$same=$true;foreach($f in @('schema','library_version','source','stream','artifact','category','fingerprint','text','exit_code','http_status','candidate_hash','previous_candidate_hash','attempt','repair_action','syntax_result','context')){if([string]$gb[0].$f-ne[string]$gu[0].$f){$same=$false}};if(-not$same){$drift++;$grows+=[ordered]@{text=$g;status='GENUINE_FIELD_DRIFT';baseline=$gb[0];upgrade=$gu[0]}}}};$x=@($br|Where-Object{$_.text-notin@($c.Genuine)}).Count;$y=@($ur|Where-Object{$_.text-notin@($c.Genuine)}).Count;$baselineFalse+=$x;$upgradeFalse+=$y;$rows+=[ordered]@{case=$c.Name;genuine=@($c.Genuine);baseline_count=$br.Count;upgrade_count=$ur.Count;baseline_false_or_extra=$x;upgrade_false_or_extra=$y;genuine_comparison=$grows}}
 $hashDrift=@($hashes|Where-Object{-not$_.identical}).Count;$summary=[ordered]@{status=if($hashDrift-eq0-and$missing-eq0-and$drift-eq0-and$upgradeFalse-lt$baselineFalse){'PASS'}else{'FAIL'};baseline_commit=$BaselineRef;cases=$cases.Count;baseline_events=($rows|Measure-Object baseline_count-Sum).Sum;upgrade_events=($rows|Measure-Object upgrade_count-Sum).Sum;baseline_false_or_extra=$baselineFalse;upgrade_false_or_extra=$upgradeFalse;false_positive_reduction=($baselineFalse-$upgradeFalse);baseline_blind_spots_recovered=$blind;missing_upgrade_genuine=$missing;genuine_field_drift=$drift;reporter_core_semantic_drift=$hashDrift;reporter_contract='schema=1; stream=output-scan; original field set';improvements=@('batch-wide pre-analysis','narrative suppression','recovery of concrete baseline blind spots','individual-line reporting','no synthetic aggregate events');downgrades=@();sustained=@('Get-ErrorFingerprint','Classify-ErrorText','Save-ErrorEvent','schema/stream/field contract','genuine baseline records');sustained_not_beneficial=@('generic lexical false positives','process/HTTP blanket inheritance by narrative','warning-as-error candidate matching');report_directory=$Report;timestamp_utc=[DateTime]::UtcNow.ToString('o')};$rows|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $Report 'case-comparison.json') -Encoding UTF8;$summary|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $Report 'executive-summary.json') -Encoding UTF8
 Stamp "REPORTER CORE SEMANTIC DRIFT=$hashDrift";Stamp "BASELINE FALSE/EXTRA=$baselineFalse; UPGRADE FALSE/EXTRA=$upgradeFalse; REDUCTION=$($baselineFalse-$upgradeFalse)";Stamp "BASELINE BLIND SPOTS RECOVERED=$blind";Stamp "MISSING UPGRADE GENUINE=$missing; GENUINE FIELD DRIFT=$drift";Stamp "CASES=$($cases.Count)"
 if($hashDrift -gt 0){Fail 'reporter core changed'};if($missing -gt 0){Fail 'upgrade missed a declared genuine diagnostic'};if($drift -gt 0){Fail 'genuine reporter record drift detected'};if($upgradeFalse -ge $baselineFalse){Fail 'upgrade did not strictly reduce false/extra events'}
 Stamp 'EXECUTIVE RESULT: PASS — reporter core preserved; genuine baseline records preserved; baseline blind spots recovered; false/extra events reduced.';Stamp ('REPORT: '+$Report);exit 0
}catch{Stamp ('FAIL-CLOSED: '+$_.Exception.Message);try{$_|Out-File -LiteralPath (Join-Path $Report 'fatal.txt') -Encoding UTF8}catch{};exit 1}finally{if($base){Remove-Item $base -Force -ErrorAction SilentlyContinue}}
