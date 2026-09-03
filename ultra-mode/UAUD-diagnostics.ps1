# UAUD Diagnostics 1.1.0 — independent fail-closed preflight
# This is deliberately NOT the installer. It never invokes UAUD.ps1 or self-repair.ps1.
# It validates the components independently, checks the pinned middleman, runs the syntax
# validator and behavioural helper sandbox, scans every captured output line for errors,
# and writes a precise report. A PASS here means the gates exercised by this diagnostic passed;
# it does not claim that an unobserved future failure is impossible.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$PSExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Middleman='https://untrapped-update-middleman-000-999-production.up.railway.app'
$ExpectedVersion='3.2.0';$ExpectedProtocol=3;$ExpectedBaseline='1.0.0';$MaxBytes=8388608
$RunId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$ReportRoot=Join-Path $Root 'uaud-diagnostics';$Run=Join-Path $ReportRoot $RunId
New-Item -ItemType Directory -Force -Path $Run|Out-Null
$ErrorLibrary=Join-Path $Root 'ErrorLibrary.ps1';if(Test-Path -LiteralPath $ErrorLibrary){. $ErrorLibrary}
function Stamp([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function HashFile([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function HashText([string]$s){$h=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function WriteJson([string]$name,[object]$o){$o|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $Run $name) -Encoding UTF8}
function RecordOutput([string]$source,[string]$stream,[string[]]$lines,[int]$exitCode=0){
  foreach($line in @($lines)){
    if([string]::IsNullOrWhiteSpace($line)){continue}
    if(Get-Command Test-ErrorLike -ErrorAction SilentlyContinue){if(Test-ErrorLike $line $exitCode 0){if(Get-Command Save-ErrorEvent -ErrorAction SilentlyContinue){[void](Save-ErrorEvent -Source $source -Stream $stream -Text $line -ExitCode $exitCode -Context 'UAUD independent diagnostics output scan')}}}
  }
}
function ParseFile([string]$path){$t=$null;$e=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e);[pscustomobject]@{ast=$ast;errors=@($e)}}
function RunChild([string]$file,[string[]]$args){
  $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$PSExe;$psi.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$file+'" '+(($args|ForEach-Object{'"'+($_ -replace '"','\"')+'"'}) -join ' ');$psi.WorkingDirectory=$Root;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
  $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$out=$p.StandardOutput.ReadToEnd();$err=$p.StandardError.ReadToEnd();$p.WaitForExit();$lines=@($out -split "`r?`n")+@($err -split "`r?`n");RecordOutput (Split-Path -Leaf $file) 'child-output' $lines $p.ExitCode;return [pscustomobject]@{exit_code=$p.ExitCode;stdout=$out;stderr=$err;lines=$lines}
}
function FetchPinned([string]$name){
  $q=[Net.HttpWebRequest]::Create($Middleman+'/v1/artifact/'+$name+'?diagnostic='+$RunId);$q.Method='GET';$q.Timeout=30000;$q.ReadWriteTimeout=30000;$q.AllowAutoRedirect=$false;$q.UserAgent='UAUD-Diagnostics/1.1.0';
  try{$r=$q.GetResponse();try{$v=[string]$r.Headers['X-Untrapped-Version'];$pr=[int]$r.Headers['X-Untrapped-Protocol'];$bl=[string]$r.Headers['X-Untrapped-Baseline'];if($v-ne$ExpectedVersion-or$pr-ne$ExpectedProtocol-or$bl-ne$ExpectedBaseline){throw "MIDDLEMAN_IDENTITY_MISMATCH version=$v protocol=$pr baseline=$bl"};if($r.ContentLength -gt $MaxBytes){throw 'RESPONSE_TOO_LARGE'};$m=New-Object IO.MemoryStream;$buf=New-Object byte[] 65536;$n=0;try{while(($read=$r.GetResponseStream().Read($buf,0,$buf.Length))-gt 0){$n+=$read;if($n-gt$MaxBytes){throw 'RESPONSE_TOO_LARGE'};$m.Write($buf,0,$read)};$bytes=$m.ToArray()}finally{$m.Dispose()};$sha=[string]$r.Headers['X-Untrapped-SHA256'];if($sha -and $sha-ne(HashText ([Text.Encoding]::UTF8.GetString($bytes)))){throw 'SHA256_MISMATCH'};return $bytes}finally{$r.Dispose()}}catch{throw "PINNED_FETCH_FAILURE $name HTTP=$([int]$(try{[int]$_.Exception.Response.StatusCode}catch{0})) $($_.Exception.Message)"}
}
Stamp 'UAUD DIAGNOSTICS 1.1.0 — INDEPENDENT NON-INSTALLING GATES'
Stamp 'IMPORTANT: UAUD.ps1 and self-repair.ps1 are NOT executed by this diagnostic.'
WriteJson 'run.json' ([ordered]@{schema=1;version='1.1.0';run_id=$RunId;started_utc=[DateTime]::UtcNow.ToString('o');install_performed=$false;installer_invoked=$false;middleman=$Middleman;expected_version=$ExpectedVersion;expected_protocol=$ExpectedProtocol;expected_baseline=$ExpectedBaseline})
$required=@('config.json','packet-filter.ps1','artifact-schema.json','UAUD.ps1','UAUD-validate.ps1','sandbox-behaviour.ps1','self-repair.ps1','evidence.ps1','ErrorLibrary.ps1')
$pre=[ordered]@{powershell=Test-Path $PSExe;files=@{}};foreach($f in $required){$pre.files[$f]=Test-Path (Join-Path $Root $f)};WriteJson 'preflight.json' $pre
$static=@();Stamp 'GATE 1 — PowerShell syntax of every pipeline script'
foreach($f in @('UAUD.ps1','self-repair.ps1','UAUD-validate.ps1','sandbox-behaviour.ps1','evidence.ps1','ErrorLibrary.ps1','packet-filter.ps1')){$p=Join-Path $Root $f;if(-not(Test-Path $p)){$static+=[ordered]@{file=$f;pass=$false;error='FILE_MISSING'};continue};try{$r=ParseFile $p;$static+=[ordered]@{file=$f;pass=(@($r.errors).Count-eq0);errors=@($r.errors|ForEach-Object{[ordered]@{message=$_.Message;line=$_.Extent.StartLineNumber;column=$_.Extent.StartColumnNumber}});sha256=HashFile $p;bytes=(Get-Item $p).Length}}catch{$static+=[ordered]@{file=$f;pass=$false;error=$_.Exception.Message}}};WriteJson 'static-parser-check.json' $static
if(@($static|Where-Object{-not$_.pass}).Count){Stamp 'FAIL — static parser gate';exit 1};Stamp 'PASS — all local PowerShell files parse'
Stamp 'GATE 2 — ErrorLibrary regression and output-scan capability'
$el=[ordered]@{exists=(Test-Path $ErrorLibrary);functions=@('Get-ErrorFingerprint','Classify-ErrorText','Test-ErrorLike','Save-ErrorEvent','Scan-ErrorOutput')|ForEach-Object{[ordered]@{name=$_;present=([bool](Get-Command $_ -ErrorAction SilentlyContinue))}};persistent_file=(Test-Path (Join-Path $Root 'error-library.jsonl'))};WriteJson 'error-library-check.json' $el
if(-not$el.exists-or@($el.functions|Where-Object{-not$_.present}).Count){Stamp 'FAIL — ErrorLibrary contract incomplete';exit 1};Stamp 'PASS — ErrorLibrary contract present'
Stamp 'GATE 3 — pinned 000-999 middleman, redirect rejection, identity and bounded artifact fetch'
try{$h=[Net.HttpWebRequest]::Create($Middleman+'/health');$h.Method='GET';$h.Timeout=20000;$h.AllowAutoRedirect=$false;$hr=$h.GetResponse();$hc=[Text.Encoding]::UTF8.GetString((New-Object IO.StreamReader($hr.GetResponseStream())).ReadToEnd())|ConvertFrom-Json;$hr.Dispose();$health=[ordered]@{pass=($hc.version-eq$ExpectedVersion-and[int]$hc.protocol-eq$ExpectedProtocol-and[string]$hc.baseline-eq$ExpectedBaseline);http_status=200;body=$hc}}catch{$health=[ordered]@{pass=$false;error=$_.Exception.Message}};WriteJson 'middleman-health.json' $health;if(-not$health.pass){Stamp 'FAIL — middleman health/identity';exit 1};Stamp 'PASS — pinned middleman identity is correct'
try{$null=FetchPinned 'ultra-mode/config.json';$null=FetchPinned 'ultra-mode/packet-filter.ps1';$fetchPass=$true}catch{$fetchPass=$false;WriteJson 'pinned-fetch-failure.json' ([ordered]@{error=$_.Exception.Message;fingerprint=(HashText $_.Exception.Message)})};if(-not$fetchPass){Stamp 'FAIL — pinned artifact fetch';exit 1};Stamp 'PASS — pinned artifacts fetched with redirects disabled and size/hash checks'
Stamp 'GATE 4 — canonical config sanity'
try{$cfg=Get-Content (Join-Path $Root 'config.json') -Raw|ConvertFrom-Json;$cfgOk=($cfg.enabled -eq $true -and [string]$cfg.start -eq '05:00' -and [string]$cfg.end -eq '22:00' -and @($cfg.domains)-contains 'youtube.com' -and @($cfg.domains)-contains 'chatgpt.com' -and @($cfg.alwaysBlockedDomains)-contains 'crushon.ai' -and @($cfg.alwaysAllowedDomains)-contains 'windowsmcp.io')}catch{$cfgOk=$false};WriteJson 'canonical-config-check.json' ([ordered]@{pass=$cfgOk});if(-not$cfgOk){Stamp 'FAIL — canonical config sanity';exit 1};Stamp 'PASS — canonical policy shape is present'
Stamp 'GATE 5 — syntax validator executed as a child process with stdout/stderr capture'
$tmp=Join-Path $env:TEMP ('uaud-diagnostic-candidate-'+$RunId+'.ps1');Set-Content -LiteralPath $tmp -Value '$x = @{ Enabled = $true; Start = ''05:00''; End = ''22:00'' }' -Encoding UTF8;try{$vr=RunChild (Join-Path $Root 'UAUD-validate.ps1') @('-Candidate',$tmp,'-Artifact','diagnostic-candidate.ps1');$vrPass=($vr.exit_code-eq0)}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue};if(-not$vrPass){Stamp "FAIL — validator exit code $($vr.exit_code)";exit 1};Stamp 'PASS — validator executed and all output was captured'
Stamp 'GATE 6 — behavioural helper sandbox'
$br=RunChild (Join-Path $Root 'sandbox-behaviour.ps1') @();if($br.exit_code-ne0){Stamp "FAIL — behavioural sandbox exit code $($br.exit_code)";exit 1};Stamp 'PASS — behavioural sandbox'
Stamp 'GATE 7 — protected-boundary static audit'
$boundary=@('Set-NetFirewallRule','New-NetFirewallRule','Remove-NetFirewallRule','Set-DnsClientServerAddress','route.exe','netsh.exe','hosts','WinDivertOpen','WinDivertClose');$violations=@();foreach($f in @('UAUD.ps1','UAUD-validate.ps1','sandbox-behaviour.ps1','self-repair.ps1')){$t=Get-Content (Join-Path $Root $f) -Raw;foreach($k in $boundary){if($t -match [regex]::Escape($k)){$violations+=[ordered]@{file=$f;keyword=$k}}}};WriteJson 'boundary-audit.json' ([ordered]@{pass=(@($violations).Count-eq0);violations=$violations});if(@($violations).Count){Stamp 'FAIL — protected boundary keyword audit';exit 1};Stamp 'PASS — no forbidden boundary mutation keywords found'
Stamp 'GATE 8 — diagnostic verdict'
WriteJson 'result.json' ([ordered]@{schema=1;status='PASS';install_performed=$false;uaud_executed=$false;self_repair_executed=$false;message='Independent non-installing diagnostics passed all implemented gates.';timestamp_utc=[DateTime]::UtcNow.ToString('o');report=$Run})
Stamp 'RESULT: PASS'
Stamp "REPORT: $Run"
Stamp 'This diagnostic cannot install anything because it never invokes UAUD.ps1 or self-repair.ps1.'
exit 0
