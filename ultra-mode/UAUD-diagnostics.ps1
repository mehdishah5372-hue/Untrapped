# UAUD Diagnostics 1.3.0 — independent, non-installing verification
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$PSExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Middleman='https://untrapped-update-middleman-000-999-production.up.railway.app'
$ExpectedVersion='3.2.0';$ExpectedProtocol=3;$ExpectedBaseline='1.0.0';$MaxBytes=8388608
$RunId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$Run=Join-Path (Join-Path $Root 'uaud-diagnostics') $RunId
New-Item -ItemType Directory -Force -Path $Run|Out-Null
$EL=Join-Path $Root 'ErrorLibrary.ps1';if(Test-Path -LiteralPath $EL){. $EL}
function Stamp([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function HashBytes([byte[]]$b){$x=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($x.ComputeHash($b))).Replace('-','').ToLowerInvariant()}finally{$x.Dispose()}}
function HashFile([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function WriteJson([string]$n,[object]$o){$o|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $Run $n) -Encoding UTF8}
function ParseFile([string]$p){$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);[pscustomobject]@{ast=$a;errors=@($e)}}
function RunChild([string]$file,[string[]]$args){$psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$PSExe;$psi.WorkingDirectory=$Root;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$quoted=@($args|ForEach-Object{'"'+($_ -replace '"','\"')+'"'});$psi.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$file+'" '+($quoted -join ' ');$p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$o=$p.StandardOutput.ReadToEnd();$e=$p.StandardError.ReadToEnd();$p.WaitForExit();return [pscustomobject]@{exit_code=$p.ExitCode;stdout=$o;stderr=$e;lines=@($o -split "`r?`n")+@($e -split "`r?`n")}}
function FetchPinned([string]$name){$q=[Net.HttpWebRequest]::Create($Middleman+'/v1/artifact/'+$name+'?diagnostic='+$RunId);$q.Method='GET';$q.Timeout=30000;$q.ReadWriteTimeout=30000;$q.AllowAutoRedirect=$false;$q.UserAgent='UAUD-Diagnostics/1.3.0';$r=$q.GetResponse();try{$v=[string]$r.Headers['X-Untrapped-Version'];$p=[int]$r.Headers['X-Untrapped-Protocol'];$b=[string]$r.Headers['X-Untrapped-Baseline'];if($v-ne$ExpectedVersion-or$p-ne$ExpectedProtocol-or$b-ne$ExpectedBaseline){throw "MIDDLEMAN_IDENTITY_MISMATCH version=$v protocol=$p baseline=$b"};if($r.ContentLength -gt $MaxBytes){throw 'RESPONSE_TOO_LARGE'};$stream=$r.GetResponseStream();$m=New-Object IO.MemoryStream;$buf=New-Object byte[] 65536;$n=0;try{while(($z=$stream.Read($buf,0,$buf.Length))-gt 0){$n+=$z;if($n-gt$MaxBytes){throw 'RESPONSE_TOO_LARGE'};$m.Write($buf,0,$z)};$bytes=$m.ToArray()}finally{$stream.Dispose();$m.Dispose()};$hs=[string]$r.Headers['X-Untrapped-SHA256'];if($hs-and$hs-ne(HashBytes $bytes)){throw 'SHA256_MISMATCH'};return $bytes}finally{$r.Dispose()}}

Stamp 'UAUD DIAGNOSTICS 1.3.0 — INDEPENDENT NON-INSTALLING GATES'
Stamp 'UAUD.ps1 and self-repair.ps1 are NOT executed by this diagnostic.'
WriteJson 'run.json' ([ordered]@{schema=1;version='1.3.0';run_id=$RunId;install_performed=$false;installer_invoked=$false;middleman=$Middleman;expected_version=$ExpectedVersion;expected_protocol=$ExpectedProtocol;expected_baseline=$ExpectedBaseline})

Stamp 'GATE 1 — required files + PowerShell parser'
$required=@('UAUD.ps1','UAUD-regression-tests.ps1','self-repair.ps1','UAUD-validate.ps1','sandbox-behaviour.ps1','evidence.ps1','ErrorLibrary.ps1','packet-filter.ps1','artifact-schema.json','config.json')
$checks=@();foreach($f in $required){$p=Join-Path $Root $f;if(-not(Test-Path -LiteralPath $p)){$checks+=[ordered]@{file=$f;pass=$false;error='FILE_MISSING'};continue};if($f.EndsWith('.ps1')){$r=ParseFile $p;$checks+=[ordered]@{file=$f;pass=(@($r.errors).Count-eq0);errors=@($r.errors|ForEach-Object{[ordered]@{message=$_.Message;line=$_.Extent.StartLineNumber;column=$_.Extent.StartColumnNumber}});sha256=HashFile $p}}else{$checks+=[ordered]@{file=$f;pass=$true;sha256=HashFile $p}}};WriteJson 'file-check.json' $checks;if(@($checks|Where-Object{-not$_.pass}).Count){Stamp 'FAIL — file/parser gate';exit 1};Stamp 'PASS — all required files parse'

Stamp 'GATE 2 — ErrorLibrary contract'
$names=@('Get-ErrorFingerprint','Classify-ErrorText','Test-ErrorLike','Save-ErrorEvent','Scan-ErrorOutput');$fc=@($names|ForEach-Object{[ordered]@{name=$_;present=([bool](Get-Command $_ -ErrorAction SilentlyContinue))}});WriteJson 'error-library-check.json' ([ordered]@{pass=(@($fc|Where-Object{-not$_.present}).Count-eq0);functions=$fc});if(@($fc|Where-Object{-not$_.present}).Count){Stamp 'FAIL — ErrorLibrary contract';exit 1};Stamp 'PASS — ErrorLibrary available'

Stamp 'GATE 3 — pinned 000-999 middleman + exact artifacts'
try{$cb=FetchPinned 'ultra-mode/config.json';$pb=FetchPinned 'ultra-mode/packet-filter.ps1';WriteJson 'middleman-health.json' ([ordered]@{pass=$true;version=$ExpectedVersion;protocol=$ExpectedProtocol;baseline=$ExpectedBaseline;config_sha256=(HashBytes $cb);packet_filter_sha256=(HashBytes $pb)});Stamp 'PASS — pinned artifacts fetched with redirect rejection and byte-accurate SHA validation'}catch{WriteJson 'middleman-health.json' ([ordered]@{pass=$false;error=$_.Exception.Message});Stamp "FAIL — middleman: $($_.Exception.Message)";exit 1}

Stamp 'GATE 4 — canonical config sanity'
try{$cfg=Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw|ConvertFrom-Json;$ok=($cfg.enabled-eq$true-and[string]$cfg.start-eq'05:00'-and[string]$cfg.end-eq'22:00'-and@($cfg.domains)-contains'youtube.com'-and@($cfg.domains)-contains'chatgpt.com'-and@($cfg.alwaysBlockedDomains)-contains'crushon.ai'-and@($cfg.alwaysAllowedDomains)-contains'windowsmcp.io')}catch{$ok=$false};WriteJson 'canonical-config-check.json' ([ordered]@{pass=$ok});if(-not$ok){Stamp 'FAIL — canonical config';exit 1};Stamp 'PASS — canonical policy shape'

Stamp 'GATE 5 — validator child process'
$tmp=Join-Path $env:TEMP ('uaud-diagnostic-'+$RunId+'.ps1');Set-Content -LiteralPath $tmp -Value '$x = @{ Enabled = $true; Start = ''05:00''; End = ''22:00'' }' -Encoding UTF8;try{$vr=RunChild (Join-Path $Root 'UAUD-validate.ps1') @('-Candidate',$tmp,'-Artifact','diagnostic-candidate.ps1');WriteJson 'validator-output.json' ([ordered]@{exit_code=$vr.exit_code;stdout=$vr.stdout;stderr=$vr.stderr})}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue};if($vr.exit_code-ne0){Stamp "FAIL — validator exit=$($vr.exit_code)";exit 1};Stamp 'PASS — validator'

Stamp 'GATE 6 — behavioural helper sandbox'
$br=RunChild (Join-Path $Root 'sandbox-behaviour.ps1') @();WriteJson 'sandbox-output.json' ([ordered]@{exit_code=$br.exit_code;stdout=$br.stdout;stderr=$br.stderr});if($br.exit_code-ne0){Stamp "FAIL — behavioural sandbox exit=$($br.exit_code)";exit 1};Stamp 'PASS — behavioural sandbox'

Stamp 'GATE 7 — historical UAUD parser regression'
$rr=RunChild (Join-Path $Root 'UAUD-regression-tests.ps1') @();WriteJson 'uaud-regression.json' ([ordered]@{exit_code=$rr.exit_code;stdout=$rr.stdout;stderr=$rr.stderr});if($rr.exit_code-ne0){Stamp 'FAIL — historical UAUD parser regression';exit 1};Stamp 'PASS — historical $code: and malformed-catch regression protected'

Stamp 'GATE 8 — protected Windows boundary audit'
$bad=@('Set-NetFirewallRule','New-NetFirewallRule','Remove-NetFirewallRule','Set-DnsClientServerAddress','route.exe','netsh.exe');$viol=@();foreach($f in @('UAUD.ps1','UAUD-regression-tests.ps1','UAUD-validate.ps1','sandbox-behaviour.ps1','self-repair.ps1')){$text=Get-Content -LiteralPath (Join-Path $Root $f) -Raw;foreach($k in $bad){if($text -match [regex]::Escape($k)){$viol+=[ordered]@{file=$f;keyword=$k}}}};WriteJson 'boundary-audit.json' ([ordered]@{pass=(@($viol).Count-eq0);violations=$viol});if(@($viol).Count){Stamp 'FAIL — forbidden Windows configuration mutation reference found';exit 1};Stamp 'PASS — protected boundaries clean'

WriteJson 'result.json' ([ordered]@{schema=1;status='PASS';install_performed=$false;uaud_executed=$false;self_repair_executed=$false;timestamp_utc=[DateTime]::UtcNow.ToString('o');report=$Run})
Stamp 'RESULT: PASS — independent diagnostics complete; nothing was installed.'
Stamp "REPORT: $Run"
exit 0
