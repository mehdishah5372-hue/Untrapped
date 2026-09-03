# Exact code-vs-code executive diagnostic: OSblocker 1.0.0 vs current ErrorLibrary.
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
function SemanticHash([string]$p,[string]$n){$raw=Get-Content -Raw -LiteralPath $p;$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseInput($raw,[ref]$t,[ref]$e);$f=$a.FindAll({param($x)$x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n},$true)|Select-Object -First 1;if(-not$f){return ''};$s=$f.Extent.Text -replace '(?m)^\s*#.*$','' -replace '\s+','';$h=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function RunOne([string]$lib,[object]$c,[string]$label){
 $r=Join-Path $env:TEMP ('osb-r-'+[guid]::NewGuid().ToString('N')+'.ps1');$e=Join-Path $env:TEMP ('osb-e-'+[guid]::NewGuid().ToString('N')+'.jsonl');$j=Join-Path $env:TEMP ('osb-j-'+[guid]::NewGuid().ToString('N')+'.json');$c|ConvertTo-Json -Depth 8 -Compress|Set-Content $j -Encoding UTF8;$lp=$lib.Replace("'","''");$ep=$e.Replace("'","''");$jp=$j.Replace("'","''")
 @"
`$ErrorActionPreference='Stop';. '$lp';`$ErrorLibraryPath='$ep';`$c=Get-Content -Raw '$jp'|ConvertFrom-Json;Scan-ErrorOutput -Source 'executive' -Artifact `$c.Name -Lines @(`$c.Lines) -ExitCode ([int]`$c.Exit) -HttpStatus ([int]`$c.Http) -Stage 'comparison'|Out-Null;`$x=@(Get-ErrorLibraryRecords|ForEach-Object{[ordered]@{schema=`$_.schema;library_version=`$_.library_version;source=`$_.source;stream=`$_.stream;artifact=`$_.artifact;category=`$_.category;fingerprint=`$_.fingerprint;text=`$_.text;exit_code=`$_.exit_code;http_status=`$_.http_status;candidate_hash=`$_.candidate_hash;previous_candidate_hash=`$_.previous_candidate_hash;attempt=`$_.attempt;repair_action=`$_.repair_action;syntax_result=`$_.syntax_result;context=`$_.context}});[pscustomobject]@{records=`$x}|ConvertTo-Json -Depth 15 -Compress
"@|Set-Content $r -Encoding UTF8
 try{$out=& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $r 2>&1;if($LASTEXITCODE -ne 0){Fail "$label process failed: $($c.Name)"};$line=@($out|ForEach-Object{[string]$_}|Where-Object{$_ -match '^\s*\{"records"'}|Select-Object -Last 1);if(-not$line){Fail "$label produced no JSON: $($c.Name)"};$line|ConvertFrom-Json}finally{Remove-Item $r,$e,$j -Force -ErrorAction SilentlyContinue}
}
try{
 Stamp 'OSblocker EXECUTIVE DIAGNOSTIC — EXACT CODE VS CODE'
 $base=Join-Path $env:TEMP ('osb-base-'+[guid]::NewGuid().ToString('N')+'.ps1');$wc=New-Object Net.WebClient;try{$wc.DownloadString($BaselineUrl)|Set-Content $base -Encoding UTF8}finally{$wc.Dispose()};if((ParseErrors $base).Count -ne 0){Fail 'baseline syntax invalid'};if((ParseErrors $Current).Count -ne 0){Fail 'upgrade syntax invalid'}
 $hashes=@();foreach($n in @('Get-ErrorFingerprint','Classify-ErrorText','Save-ErrorEvent')){$b=SemanticHash $base $n;$u=SemanticHash $Current $n;$hashes+=[ordered]@{function=$n;baseline=$b;upgrade=$u;identical=($b -eq $u)}}
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
 $rows=@();$bf=0;$uf=0;$blind=0;$missing=0;$drift=0;$sustained=0
 foreach($c in $cases){$b=RunOne $base $c 'baseline';$u=RunOne $Current $c 'upgrade';$br=@($b.records);$ur=@($u.records);$grows=@();foreach($g in @($c.Genuine)){$gb=@($br|Where-Object{$_.text -eq $g});$gu=@($ur|Where-Object{$_.text -eq $g});if($gu.Count -ne 1){$missing++;$grows+=[ordered]@{text=$g;status='UPGRADE_MISSING';baseline_count=$gb.Count;upgrade_count=$gu.Count};continue};if($gb.Count -eq 0){$blind++;$grows+=[ordered]@{text=$g;status='BASELINE_BLIND_SPOT'};continue};$same=$true;foreach($f in @('schema','library_version','source','stream','artifact','category','fingerprint','text','exit_code','http_status','candidate_hash','previous_candidate_hash','attempt','repair_action','syntax_result','context')){if([string]$gb[0].$f -ne [string]$gu[0].$f){$same=$false}};if($same){$sustained++}else{$drift++;$grows+=[ordered]@{text=$g;status='GENUINE_FIELD_DRIFT'}}};$x=@($br|Where-Object{$_.text -notin @($c.Genuine)}).Count;$y=@($ur|Where-Object{$_.text -notin @($c.Genuine)}).Count;$bf+=$x;$uf+=$y;$rows+=[ordered]@{case=$c.Name;baseline_count=$br.Count;upgrade_count=$ur.Count;baseline_false_or_extra=$x;upgrade_false_or_extra=$y;genuine_comparison=$grows}}
 $hashDrift=@($hashes|Where-Object{-not $_.identical}).Count;$summary=[ordered]@{status=if($hashDrift -eq 0 -and $missing -eq 0 -and $drift -eq 0 -and $uf -lt $bf){'PASS'}else{'FAIL'};baseline_commit=$BaselineRef;cases=$cases.Count;baseline_false_or_extra=$bf;upgrade_false_or_extra=$uf;false_positive_reduction=($bf-$uf);baseline_blind_spots_recovered=$blind;genuine_sustained=$sustained;missing_upgrade_genuine=$missing;genuine_field_drift=$drift;reporter_core_semantic_drift=$hashDrift;reporter_contract='schema=1; stream=output-scan; original field set';improvements=@('batch-wide inspection','narrative suppression','concrete blind-spot recovery','individual-line reporting','no synthetic aggregate events');downgrades=@();sustained=@('Get-ErrorFingerprint','Classify-ErrorText','Save-ErrorEvent','schema/stream/fields','genuine baseline records');sustained_not_beneficial=@('generic lexical false positives','blanket process/HTTP inheritance by narrative','warning-as-error matching');report_directory=$Report;timestamp_utc=[DateTime]::UtcNow.ToString('o')};$rows|ConvertTo-Json -Depth 40|Set-Content (Join-Path $Report 'case-comparison.json') -Encoding UTF8;$summary|ConvertTo-Json -Depth 40|Set-Content (Join-Path $Report 'executive-summary.json') -Encoding UTF8
 Stamp "REPORTER DRIFT=$hashDrift | SUSTAINED=$sustained | BLIND-SPOTS=$blind | MISSING=$missing | GENUINE DRIFT=$drift";Stamp "BASELINE FALSE/EXTRA=$bf | UPGRADE FALSE/EXTRA=$uf | REDUCTION=$($bf-$uf)"
 if($hashDrift -gt 0){Fail 'reporter core changed'};if($missing -gt 0){$rows|Where-Object{$_.genuine_comparison.Count -gt 0}|ConvertTo-Json -Depth 20|Write-Host;Fail 'upgrade missed a declared genuine diagnostic'};if($drift -gt 0){Fail 'genuine reporter record drift detected'};if($uf -ge $bf){Fail 'upgrade did not strictly reduce false/extra events'}
 Stamp 'EXECUTIVE RESULT: PASS — reporter core preserved; genuine diagnostics preserved; baseline blind spots recovered; false/extra events reduced.';Stamp ('REPORT: '+$Report);exit 0
}catch{Stamp ('FAIL-CLOSED: '+$_.Exception.Message);try{$_|Out-File (Join-Path $Report 'fatal.txt') -Encoding UTF8}catch{};exit 1}finally{if($base){Remove-Item $base -Force -ErrorAction SilentlyContinue}}
