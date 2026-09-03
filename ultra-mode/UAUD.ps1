# UAUD 3.0.0 — complete fail-closed launch pipeline
# CANON -> 3.2.0/000-999 MIDDLEMAN -> JSON/PS -> PARSER -> ADAPTIVE REPAIR -> AST/CANON -> EQUIVALENCE -> WINDOWS SANDBOX -> UARD -> INSTALL
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$Middleman='https://untrapped-update-middleman-000-999-production.up.railway.app'
$ArtifactBase=$Middleman+'/v1/artifact/'
$ExpectedVersion='3.2.0';$ExpectedProtocol=3;$ExpectedBaseline='1.0.0'
$MaxBytes=8388608;$EmergencyCeiling=200;$RepeatThreshold=5
$UARD=Join-Path $Root 'self-repair.ps1';$Schema=Join-Path $Root 'artifact-schema.json';$Sandbox=Join-Path $Root 'sandbox-behaviour.ps1';$Evidence=Join-Path $Root 'evidence.ps1';$ErrorLibrary=Join-Path $Root 'ErrorLibrary.ps1';$LocalConfig=Join-Path $Root 'config.json'
foreach($p in @($UARD,$Schema,$Sandbox,$Evidence,$LocalConfig)){if(-not(Test-Path -LiteralPath $p)){throw "Required pipeline file missing: $p"}}
. $Evidence
if(Test-Path -LiteralPath $ErrorLibrary){. $ErrorLibrary}
$RunId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8);$Run=Initialize-EvidenceRun $RunId
$failed=$false
function Out([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function HashBytes([byte[]]$b){$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash($b))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function HashText([string]$s){HashBytes ([Text.Encoding]::UTF8.GetBytes($s))}
function ReadLimited([IO.Stream]$st){$m=New-Object IO.MemoryStream;$b=New-Object byte[] 65536;$n=0;try{while(($r=$st.Read($b,0,$b.Length)) -gt 0){$n+=$r;if($n -gt $MaxBytes){throw "response exceeds $MaxBytes byte limit"};$m.Write($b,0,$r)};return $m.ToArray()}finally{$m.Dispose()}}
function Fetch([string]$name,[string]$kind){
  for($a=1;$a -le 5;$a++){
    try{
      Out "STAGE 0 FETCH $name attempt $a/5"
      $q=[Net.HttpWebRequest]::Create($ArtifactBase+$name+'?uaud='+$RunId);$q.Method='GET';$q.Timeout=30000;$q.ReadWriteTimeout=30000;$q.AllowAutoRedirect=$false;$q.UserAgent='UAUD/3.0.0'
      $r=$q.GetResponse();try{
        $v=[string]$r.Headers['X-Untrapped-Version'];$pr=[int]$r.Headers['X-Untrapped-Protocol'];$bl=[string]$r.Headers['X-Untrapped-Baseline']
        if($v -ne $ExpectedVersion -or $pr -ne $ExpectedProtocol -or $bl -ne $ExpectedBaseline){throw "middleman identity mismatch: version=$v protocol=$pr baseline=$bl"}
        if($r.ContentLength -gt $MaxBytes){throw "response exceeds $MaxBytes byte limit"}
        $bytes=ReadLimited $r.GetResponseStream();$hs=[string]$r.Headers['X-Untrapped-SHA256'];if($hs -and $hs -ne (HashBytes $bytes)){throw 'middleman SHA256 header mismatch'}
        return $bytes
      }finally{$r.Dispose()}
    }catch{
      $code=0;try{$code=[int]$_.Exception.Response.StatusCode}catch{}
      if(Get-Command Save-ErrorEvent -ErrorAction SilentlyContinue){[void](Save-ErrorEvent -Source 'UAUD' -Stream 'Fetch' -Text $_.Exception.Message -Artifact $name -HttpStatus $code -Attempt $a -Context 'pipeline fetch')}
      if($code -in @(301,302,303,307,308,400,401,403,404,409,422)){throw "DETERMINISTIC FETCH FAILURE $name HTTP $code: $($_.Exception.Message)"}
      if($a -lt 5 -and ($code -eq 0 -or $code -eq 408 -or $code -eq 425 -or $code -eq 429 -or $code -ge 500)){Out "TRANSIENT FETCH ERROR HTTP $code; retrying";Start-Sleep -Seconds ([Math]::Min(2*$a,8));continue}
      throw "FETCH FAILURE $name HTTP $code: $($_.Exception.Message)"
    }
  }
}
function ParsePS([string]$source){$t=$null;$e=$null;$ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$t,[ref]$e);[pscustomobject]@{ast=$ast;tokens=@($t);errors=@($e)}}
function Repair([string]$source,[object]$parse){$x=$source;foreach($e in @($parse.errors)){$m=[string]$e.Message;if($m -match '(?i)missing.*closing.*brace'){$x=$x.TrimEnd()+"`n}"}elseif($m -match '(?i)missing.*closing.*parenthesis'){$x=$x.TrimEnd()+"`n)"}elseif($m -match '(?i)missing.*closing.*bracket'){$x=$x.TrimEnd()+"`n]"}else{return $null}};if($x -eq $source){return $null};return $x}
function StageResult([string]$stage,[string]$result,[hashtable]$data=@{}){Write-EvidenceJson $stage 'result.json' ([ordered]@{stage=$stage;result=$result;timestamp_utc=[DateTime]::UtcNow.ToString('o')}+$data)}
try{
  Out 'UAUD 3.0.0 — FAIL-CLOSED OBSERVABLE PIPELINE'
  Out "EVIDENCE: $Run"
  Write-EvidenceJson 'run' 'input.json' ([ordered]@{run_id=$RunId;orchestrator_version='3.0.0';middleman=$Middleman;expected_version=$ExpectedVersion;expected_protocol=$ExpectedProtocol;expected_baseline=$ExpectedBaseline})

  # CANONICAL SOURCE: local file is checked against the pinned middleman copy before anything can proceed.
  Out 'STAGE 0A — canonical config from 000-999 middleman'
  $remoteConfigBytes=Fetch 'ultra-mode/config.json' 'json';$remoteConfig=[Text.Encoding]::UTF8.GetString($remoteConfigBytes).TrimStart([char]0xFEFF)|ConvertFrom-Json
  $localConfig=Get-Content -LiteralPath $LocalConfig -Raw|ConvertFrom-Json
  $remoteCanonical=($remoteConfig|ConvertTo-Json -Depth 20 -Compress);$localCanonical=($localConfig|ConvertTo-Json -Depth 20 -Compress)
  if($remoteCanonical -ne $localCanonical){throw 'CANONICAL_MISMATCH: local config.json differs from 000-999 canonical config'}
  StageResult 'stage-0-canonical' 'PASS' @{canonical_hash=HashText $remoteCanonical}
  Out 'PASS — canonical config matches middleman'

  # STAGE 1: actual JSON -> PowerShell data transformation in a disposable in-memory candidate.
  Out 'STAGE 1 — JSON -> PS sandbox'
  $domains=@($remoteConfig.domains);$blocked=@($remoteConfig.alwaysBlockedDomains);$allowed=@($remoteConfig.alwaysAllowedDomains)
  $generated=@"
`$Policy = [ordered]@{
 enabled = $($remoteConfig.enabled.ToString().ToLowerInvariant())
 start = '$($remoteConfig.start)'
 end = '$($remoteConfig.end)'
 domains = @($(($domains|ForEach-Object{"'$($_.ToString().Replace("'","''"))'"}) -join ', '))
 alwaysBlockedDomains = @($(($blocked|ForEach-Object{"'$($_.ToString().Replace("'","''"))'"}) -join ', '))
 alwaysAllowedDomains = @($(($allowed|ForEach-Object{"'$($_.ToString().Replace("'","''"))'"}) -join ', '))
}
"@
  $s1=ParsePS $generated;if(@($s1.errors).Count){throw 'STAGE1_FAILURE: generated PowerShell from canonical JSON did not parse'}
  Write-EvidenceText 'stage-1-json-ps' 'candidate.ps1' $generated;StageResult 'stage-1-json-ps' 'PASS' @{candidate_hash=HashText $generated};Out 'PASS — JSON transformed into parseable PS'

  # STAGE 2: parser sandbox only; no invocation of candidate.
  Out 'STAGE 2 — PowerShell parser sandbox'
  $candidate=$generated;$history=@();$counts=@{};$previousHash=''
  $repaired=$false
  for($attempt=1;$attempt -le $EmergencyCeiling;$attempt++){
    $h=HashText $candidate;$p=ParsePS $candidate;Out "PARSER attempt=$attempt hash=$h errors=$(@($p.errors).Count)"
    if(@($p.errors).Count -eq 0){StageResult 'stage-2-parser' 'PASS' @{attempt=$attempt;candidate_hash=$h};break}
    $progress=$false;$repeat=$false
    foreach($e in @($p.errors)){
      $fp=if(Get-Command Get-ErrorFingerprint -ErrorAction SilentlyContinue){Get-ErrorFingerprint ([string]$e.Message) 'PARSER'}else{HashText ('PARSER|'+$e.Message)}
      if(-not $counts.ContainsKey($fp)){$counts[$fp]=0};$counts[$fp]++
      $history+=([ordered]@{attempt=$attempt;fingerprint=$fp;message=$e.Message;line=$e.Extent.StartLineNumber;column=$e.Extent.StartColumnNumber})
      if($counts[$fp] -ge $RepeatThreshold){$repeat=$true}
    }
    if($repeat){throw 'COOKED_REPEATED_ERROR: parser error fingerprint repeated beyond repair threshold'}
    $next=Repair $candidate $p;if($null -eq $next){throw 'UNKNOWN_ERROR: no safe adaptive syntax repair exists'}
    if((@((ParsePS $next).errors).Count) -ge @($p.errors).Count){throw 'NON_PROGRESSING_REPAIR: repair did not reduce parser errors'}
    $previousHash=$h;$candidate=$next;$repaired=$true
    if(Get-Command Save-ErrorEvent -ErrorAction SilentlyContinue){foreach($x in @($p.errors)){[void](Save-ErrorEvent -Source 'UAUD' -Stream 'Repair' -Text $x.Message -Artifact 'generated-policy.ps1' -CandidateHash $h -PreviousCandidateHash $previousHash -Attempt $attempt -SyntaxResult 'FAIL' -Context 'adaptive repair')}}
    if($attempt -eq $EmergencyCeiling){throw 'EMERGENCY_CEILING: adaptive repair ceiling reached without a valid candidate'}
  }
  Write-EvidenceJson 'stage-2-parser' 'repair-history.json' @($history)|Out-Null
  Out 'PASS — parser gate complete'

  # STAGE 3: repair sandbox is deliberately separate from installation/UARD. The candidate is still data only.
  Out 'STAGE 3 — adaptive repair sandbox'
  $repairCandidate=Join-Path $env:TEMP ('UAUD-repair-'+$RunId+'.ps1');[IO.File]::WriteAllText($repairCandidate,$candidate,(New-Object Text.UTF8Encoding($false)))
  $validator=Join-Path $Root 'UAUD-validate.ps1';if(-not(Test-Path -LiteralPath $validator)){throw 'STAGE3_FAILURE: UAUD-validate.ps1 missing'}
  $vp=Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$validator,'-Candidate',$repairCandidate,'-Artifact','generated-policy.ps1') -Wait -PassThru -NoNewWindow
  if($vp.ExitCode -ne 0){throw "STAGE3_FAILURE: adaptive repair validator rejected candidate with exit code $($vp.ExitCode)"}
  StageResult 'stage-3-repair' 'PASS' @{validator_exit_code=$vp.ExitCode;candidate_hash=HashText $candidate;repaired=$repaired};Out 'PASS — adaptive repair sandbox accepted candidate'
  Remove-Item -LiteralPath $repairCandidate -Force -ErrorAction SilentlyContinue

  # STAGE 4/5: explicit AST -> policy representation, then compare to canonical JSON. No generic AST signature is treated as proof.
  Out 'STAGE 4 — PS/AST -> canonical representation'
  $packetBytes=Fetch 'ultra-mode/packet-filter.ps1' 'ps1';$packet=[Text.Encoding]::UTF8.GetString($packetBytes)
  $pp=ParsePS $packet;if(@($pp.errors).Count){throw 'STAGE4_FAILURE: canonical packet-filter.ps1 is syntactically invalid'}
  $fn=@($pp.ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object{$_.Name})
  $schema=Get-Content -LiteralPath $Schema -Raw|ConvertFrom-Json
  foreach($name in @($schema.required_functions)){if($fn -notcontains $name){throw "STAGE4_FAILURE: required function missing: $name"}}
  $rep=[ordered]@{
    schema_version=1;artifact='packet-filter.ps1';canonical='config.json';
    scheduled_window=[ordered]@{start=[string]$remoteConfig.start;end=[string]$remoteConfig.end};
    scheduled_domains=@($remoteConfig.domains|ForEach-Object{[string]$_});always_blocked=@($remoteConfig.alwaysBlockedDomains|ForEach-Object{[string]$_});always_allowed=@($remoteConfig.alwaysAllowedDomains|ForEach-Object{[string]$_});
    required_functions=@($fn);tcp_port_443=($packet -match 'tcp\.DstPort\s*==\s*443');udp_port_443=($packet -match 'udp\.DstPort\s*==\s*443');outbound=($packet -match 'outbound');loopback_excluded=($packet -match '!loopback');drop_flag=($packet -match '\$FlagDrop\s*=\s*0x0002');override_source=($packet -match 'override-until\.txt');
    forbidden_mutation_keywords=@('Set-NetFirewallRule','New-NetFirewallRule','Set-DnsClientServerAddress','route.exe','netsh.exe')|ForEach-Object{[ordered]@{keyword=$_;present=($packet -match [regex]::Escape($_))}}
  }
  Write-EvidenceJson 'stage-4-ast-canonical' 'representation.json' $rep;Out 'PASS — explicit packet-filter AST representation built'

  Out 'STAGE 5 — canonical equivalence'
  if([string]$rep.scheduled_window.start -ne [string]$remoteConfig.start -or [string]$rep.scheduled_window.end -ne [string]$remoteConfig.end){throw 'CANONICAL_MISMATCH: schedule differs'}
  if((@($rep.scheduled_domains)-join '|') -ne (@($remoteConfig.domains|ForEach-Object{[string]$_})-join '|')){throw 'CANONICAL_MISMATCH: scheduled domains differ'}
  if((@($rep.always_blocked)-join '|') -ne (@($remoteConfig.alwaysBlockedDomains|ForEach-Object{[string]$_})-join '|')){throw 'CANONICAL_MISMATCH: always-blocked domains differ'}
  if((@($rep.always_allowed)-join '|') -ne (@($remoteConfig.alwaysAllowedDomains|ForEach-Object{[string]$_})-join '|')){throw 'CANONICAL_MISMATCH: always-allowed domains differ'}
  if(-not $rep.tcp_port_443 -or -not $rep.udp_port_443 -or -not $rep.outbound -or -not $rep.loopback_excluded -or -not $rep.drop_flag -or -not $rep.override_source){throw 'CANONICAL_MISMATCH: packet policy primitives do not match schema'}
  if(@($rep.forbidden_mutation_keywords|Where-Object{$_.present}).Count){throw 'CANONICAL_MISMATCH: forbidden mutation keyword found'}
  StageResult 'stage-5-equivalence' 'PASS' @{canonical_hash=HashText $remoteCanonical;artifact_hash=HashBytes $packetBytes};Out 'PASS — canonical equivalence gate complete'

  # STAGE 6: disposable Windows process sandbox. It executes only extracted helper functions, never packet-filter.ps1 itself.
  Out 'STAGE 6 — disposable Windows behavioural sandbox'
  $sb=Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$Sandbox) -Wait -PassThru -NoNewWindow
  if($sb.ExitCode -ne 0){throw "STAGE6_FAILURE: behavioural sandbox exited $($sb.ExitCode)"}
  StageResult 'stage-6-windows' 'PASS' @{exit_code=$sb.ExitCode};Out 'PASS — disposable Windows behavioural sandbox'

  # Final hand-off. UARD is the only component allowed to install. UAUD never installs candidate code itself.
  Out 'UARD HAND-OFF — all UAUD gates passed; UARD may now perform its own fail-closed verification/install gate'
  $up=Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$UARD) -Wait -PassThru -NoNewWindow
  StageResult 'uard' $(if($up.ExitCode -eq 0){'PASS'}else{'FAIL'}) @{exit_code=$up.ExitCode}
  if($up.ExitCode -ne 0){throw "UARD_FAILURE: UARD refused installation (exit $($up.ExitCode))"}
  Out 'RESULT: SUCCESS — complete UAUD chain passed and UARD completed.'
  Write-EvidenceJson 'run' 'final.json' ([ordered]@{result='SUCCESS';run_id=$RunId;timestamp_utc=[DateTime]::UtcNow.ToString('o');gates=@('CANONICAL','MIDDLEMAN','JSON_PS','PARSER','ADAPTIVE_REPAIR','AST_CANONICAL','EQUIVALENCE','WINDOWS_BEHAVIOURAL','UARD_INSTALL')})
  exit 0
}catch{
  $msg=$_.Exception.Message;Out "RESULT: FAIL — $msg";Write-EvidenceText 'run' 'failure.txt' ($_|Out-String);Write-EvidenceJson 'run' 'final.json' ([ordered]@{result='FAIL';run_id=$RunId;error=$msg;timestamp_utc=[DateTime]::UtcNow.ToString('o')})
  if(Get-Command Save-ErrorEvent -ErrorAction SilentlyContinue){[void](Save-ErrorEvent -Source 'UAUD' -Stream 'Pipeline' -Text $msg -Artifact 'UAUD' -Attempt 0 -Context 'top-level pipeline failure')}
  Out "EVIDENCE_ROOT: $Run";exit 1
}
