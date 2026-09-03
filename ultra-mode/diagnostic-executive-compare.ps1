# Exact OSblocker 1.0.0 vs current ErrorLibrary executive diagnostic.
# Non-installing. Each implementation is executed in a separate PowerShell process.
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
function SemanticFunctionHash([string]$p,[string]$n){$raw=Get-Content -Raw -LiteralPath $p;$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseInput($raw,[ref]$t,[ref]$e);$f=$a.FindAll({param($x)$x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n},$true)|Select-Object -First 1;if(-not $f){return ''};$s=$f.Extent.Text -replace '(?m)^\s*#.*$','' -replace '\s+','';$h=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function Invoke-Isolated([string]$Library,[object]$Case,[string]$Label){
 $runner=Join-Path $env:TEMP ('osb-run-'+[guid]::NewGuid().ToString('N')+'.ps1');$events=Join-Path $env:TEMP ('osb-ev-'+[guid]::NewGuid().ToString('N')+'.jsonl');$cf=Join-Path $env:TEMP ('osb-cf-'+[guid]::NewGuid().ToString('N')+'.json')
 $Case|ConvertTo-Json -Depth 12 -Compress|Set-Content -LiteralPath $cf -Encoding UTF8
 $lib=$Library.Replace("'","''");$ev=$events.Replace("'","''");$case=$cf.Replace("'","''")
 @"
`$ErrorActionPreference='Stop'
. '$lib'
`$ErrorLibraryPath='$ev'
`$c=Get-Content -Raw -LiteralPath '$case'|ConvertFrom-Json
`$r=@(Scan-ErrorOutput -Source 'executive' -Artifact `$c.Name -Lines @(`$c.Lines) -ExitCode ([int]`$c.Exit) -HttpStatus ([int]`$c.Http) -Stage 'comparison')
`$records=@(Get-ErrorLibraryRecords|ForEach-Object{[ordered]@{schema=[int]`$_.schema;library_version=[string]`$_.library_version;source=[string]`$_.source;stream=[string]`$_.stream;artifact=[string]`$_.artifact;category=[string]`$_.category;fingerprint=[string]`$_.fingerprint;text=[string]`$_.text;exit_code=[int]`$_.exit_code;http_status=[int]`$_.http_status;candidate_hash=[string]`$_.candidate_hash;previous_candidate_hash=[string]`$_.previous_candidate_hash;attempt=[int]`$_.attempt;repair_action=[string]`$_.repair_action;syntax_result=[string]`$_.syntax_result;context=[string]`$_.context}})
[pscustomobject]@{selected=@(`$r|ForEach-Object{[string]`$_.fingerprint});records=`$records}|ConvertTo-Json -Depth 20 -Compress
"@|Set-Content -LiteralPath $runner -Encoding UTF8
 try{$out=& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1;if($LASTEXITCODE -ne 0){Fail "$Label process failed for $($Case.Name)"};$line=@($out|ForEach-Object{[string]$_}|Where-Object{$_ -match '^\s*\{"selected"'}|Select-Object -Last 1);if(-not $line){Fail "$Label produced no JSON for $($Case.Name)"};return ($line|ConvertFrom-Json)}finally{Remove-Item $runner,$events,$cf -Force -ErrorAction SilentlyContinue}
}
try{
 Stamp 'OSblocker EXECUTIVE DIAGNOSTIC — EXACT CODE VS CODE'
 Stamp "Baseline=$BaselineRef; upgrade=current branch; isolated processes; non-installing."
 $base=Join-Path $env:TEMP ('osb-base-'+[guid]::NewGuid().ToString('N')+'.ps1');$wc=New-Object Net.WebClient;try{$wc.DownloadString($BaselineUrl)|Set-Content -LiteralPath $base -Encoding UTF8}finally{$wc.Dispose()}
 if((ParseErrors $base).Count -ne 0){Fail 'baseline ErrorLibrary syntax invalid'};if((ParseErrors $Current).Count -ne 0){Fail 'upgrade ErrorLibrary syntax invalid'}
 $fn=@('Get-ErrorFingerprint','Classify-ErrorText','Save-ErrorEvent');$hashes=@();foreach($n in $fn){$b=SemanticFunctionHash $base $n;$u=SemanticFunctionHash $Current $n;$hashes+=[ordered]@{function=$n;baseline=$b;upgrade=$u;identical=($b -eq $u)}}
 $cases=@(
  [pscustomobject]@{Name='pass';Lines=@('PASS — parser/repair gate complete');Exit=0;Http=0;Genuine=@()},
  [pscustomobject]@{Name='regression-pass';Lines=@('[REGRESSION PASS] historical parser failure was reproduced');Exit=0;Http=0;Genuine=@()},
  [pscustomobject]@{Name='malformed-narrative';Lines=@('This test verifies that the script fails safely when given malformed input.');Exit=0;Http=0;Genuine=@()},
  [pscustomobject]@{Name='warning-narrative';Lines=@('WARNING: expected test narrative, not an emitted warning');Exit=0;Http=0;Genuine=@()},
  [pscustomobject]@{Name='error-narrative';Lines=@('Error handling regression coverage complete');Exit=0;Http=0;Genuine=@()},
  [pscustomobject]@{Name='failure-narrative';Lines=@('The previous failure is intentionally reproduced here.');Exit=0;Http=0;Genuine=@()},
  [pscustomobject]@{Name='http-fixture';Lines=@('HTTP 422 deterministic rejection is a regression fixture.');Exit=0;Http=0;Genuine=@()},
  [pscustomobject]@{Name='zero-exit';Lines=@('Exit code: 0');Exit=0;Http=0;Genuine=@()},
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
  [pscustomobject]@{Name='multiple-errors';Lines=@('Access is denied','ParserError: Missing closing }');Exit=0;Http=0;Genuine=@('Access is denied','ParserError: Missing closing }')},
  [pscustomobject]@{Name='duplicate';Lines=@('Access is denied','Access is denied');Exit=0;Http=0;Genuine=@('Access is denied')},
  [pscustomobject]@{Name='long-noise';Lines=@('INFO: build started','INFO: checking parser fixtures','ERROR: UARD could not start','INFO: recovery complete','PASS: test complete');Exit=0;Http=0;Genuine=@('ERROR: UARD could not start')},
  [pscustomobject]@{Name='negative-error-word';Lines=@('No error occurred; the regression test passed.');Exit=0;Http=0;Genuine=@()},
  [pscustomobject]@{Name='negative-failed-word';Lines=@('The test failed previously and is now fixed.');Exit=0;Http=0;Genuine=@()}
 )
 $rows=@();$bf=0;$uf=0;$gm=0;$be=0;$ue=0
 foreach($c in $cases){$b=Invoke-Isolated $base $c 'baseline';$u=Invoke-Isolated $Current $c 'upgrade';$br=@($b.records);$ur=@($u.records);$be+=$br.Count;$ue+=$ur.Count;$grows=@();foreach($g in @($c.Genuine)){$gb=@($br|Where-Object{$_.text -eq $g});$gu=@($ur|Where-Object{$_.text -eq $g});if($gb.Count -ne 1 -or $gu.Count -ne 1){$gm++;$grows+=[ordered]@{text=$g;status='MISSING_OR_DUPLICATE';baseline_count=$gb.Count;upgrade_count=$gu.Count}}else{$same=$true;foreach($f in @('schema','library_version','source','stream','artifact','category','fingerprint','text','exit_code','http_status','candidate_hash','previous_candidate_hash','attempt','repair_action','syntax_result','context')){if([string]$gb[0].$f -ne [string]$gu[0].$f){$same=$false}};if(-not $same){$gm++;$grows+=[ordered]@{text=$g;status='FIELD_MISMATCH';baseline=$gb[0];upgrade=$gu[0]}}}};$x=@($br|Where-Object{$_.text -notin @($c.Genuine)}).Count;$y=@($ur|Where-Object{$_.text -notin @($c.Genuine)}).Count;$bf+=$x;$uf+=$y;$rows+=[ordered]@{case=$c.Name;genuine=@($c.Genuine);baseline_count=$br.Count;upgrade_count=$ur.Count;baseline_extra=$x;upgrade_extra=$y;genuine_comparison=$grows}}
 $rows|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $Report 'case-comparison.json') -Encoding UTF8
 $hashDrift=@($hashes|Where-Object{-not $_.identical})
 $summary=[ordered]@{status=if($gm -eq 0 -and $uf -lt $bf -and $hashDrift.Count -eq 0){'PASS'}else{'FAIL'};baseline=[ordered]@{product='OSblocker';version='1.0.0';commit=$BaselineRef};cases=$cases.Count;baseline_events=$be;upgrade_events=$ue;baseline_extra_or_false=$bf;upgrade_extra_or_false=$uf;false_positive_reduction=($bf-$uf);genuine_mismatches=$gm;reporter_core_hashes=$hashes;reporter_contract='schema=1; stream=output-scan; field set unchanged';improvements=@('batch-wide inspection before emission','narrative suppression','concrete error recognition','individual-line reporting','no synthetic aggregate events');downgrades=@();sustained=@('Get-ErrorFingerprint','Classify-ErrorText','Save-ErrorEvent','schema 1','output-scan','reporter fields','genuine line text and metadata');sustained_not_beneficial=@('generic lexical words such as failure/error when used only as test prose','blanket inheritance of process/HTTP status by narrative lines','WARNING-as-error candidate matching');remaining_risks=@('checker regexes must remain covered by adversarial regression cases','baseline semantics are preserved only for genuine evidence, not known narrative false positives')};$summary|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $Report 'executive-summary.json') -Encoding UTF8
 Stamp "Reporter core semantic drift=$($hashDrift.Count); genuine mismatches=$gm; baseline extra/false=$bf; upgrade extra/false=$uf; reduction=$($bf-$uf)"
 if($hashDrift.Count -gt 0){$hashes|ConvertTo-Json -Depth 10|Write-Host;Fail 'reporter core semantic drift detected'}
 if($gm -gt 0){$rows|Where-Object{$_.genuine_comparison.Count -gt 0}|ConvertTo-Json -Depth 20|Write-Host;Fail 'genuine baseline diagnosis drift detected'}
 if($uf -ge $bf){Fail 'upgrade did not strictly reduce false/extra events'}
 Stamp 'EXECUTIVE RESULT: PASS — reporter core and genuine baseline records preserved; checker strictly reduces false/extra events.';Stamp ('REPORT: '+$Report);exit 0
}catch{Stamp ('FAIL-CLOSED: '+$_.Exception.Message);try{$_|Out-File -LiteralPath (Join-Path $Report 'fatal.txt') -Encoding UTF8}catch{};exit 1}finally{if($base){Remove-Item $base -Force -ErrorAction SilentlyContinue}}
