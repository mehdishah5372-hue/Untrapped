# UAUD Diagnostics 1.4.0 — force-first, independent, non-installing verification
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$PSExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Middleman='https://untrapped-update-middleman-000-999-production.up.railway.app'
$ExpectedVersion='3.2.0';$ExpectedProtocol=3;$ExpectedBaseline='1.0.0';$MaxBytes=8388608
$RunId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$Run=Join-Path (Join-Path $Root 'uaud-diagnostics') $RunId
New-Item -ItemType Directory -Force -Path $Run|Out-Null
$EL=Join-Path $Root 'ErrorLibrary.ps1';if(Test-Path -LiteralPath $EL){. $EL}
$OldLibraryPath=$ErrorLibraryPath
$ErrorLibraryPath=Join-Path $env:TEMP ('uaud-diagnostic-errorlib-'+$RunId+'.jsonl')

function Stamp([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function HashBytes([byte[]]$b){$x=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($x.ComputeHash($b))).Replace('-','').ToLowerInvariant()}finally{$x.Dispose()}}
function HashFile([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function WriteJson([string]$n,[object]$o){$o|ConvertTo-Json -Depth 40|Set-Content -LiteralPath (Join-Path $Run $n) -Encoding UTF8}
function ParseFile([string]$p){$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);[pscustomobject]@{ast=$a;errors=@($e)}}
function RunChild([string]$file,[string[]]$args){
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$PSExe;$psi.WorkingDirectory=$Root;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $argText=@($args|ForEach-Object{'"'+($_ -replace '"','\"')+'"'})
    $psi.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$file+'" '+($argText -join ' ')
    $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start()
    $stdout=$p.StandardOutput.ReadToEnd();$stderr=$p.StandardError.ReadToEnd();$p.WaitForExit()
    [pscustomobject]@{exit_code=$p.ExitCode;stdout=$stdout;stderr=$stderr;lines=@($stdout -split "`r?`n")+@($stderr -split "`r?`n")}
}
function FetchPinned([string]$name){
    $q=[Net.HttpWebRequest]::Create($Middleman+'/v1/artifact/'+$name+'?diagnostic='+$RunId)
    $q.Method='GET';$q.Timeout=30000;$q.ReadWriteTimeout=30000;$q.AllowAutoRedirect=$false;$q.UserAgent='UAUD-Diagnostics/1.4.0'
    $r=$q.GetResponse()
    try{
        $v=[string]$r.Headers['X-Untrapped-Version'];$p=[int]$r.Headers['X-Untrapped-Protocol'];$b=[string]$r.Headers['X-Untrapped-Baseline']
        if($v-ne$ExpectedVersion-or$p-ne$ExpectedProtocol-or$b-ne$ExpectedBaseline){throw ('MIDDLEMAN_IDENTITY_MISMATCH version='+$v+' protocol='+$p+' baseline='+$b)}
        if($r.ContentLength -gt $MaxBytes){throw 'RESPONSE_TOO_LARGE'}
        $stream=$r.GetResponseStream();$m=New-Object IO.MemoryStream;$buf=New-Object byte[] 65536;$n=0
        try{while(($z=$stream.Read($buf,0,$buf.Length))-gt 0){$n+=$z;if($n-gt$MaxBytes){throw 'RESPONSE_TOO_LARGE'};$m.Write($buf,0,$z)};$bytes=$m.ToArray()}finally{$stream.Dispose();$m.Dispose()}
        $hs=[string]$r.Headers['X-Untrapped-SHA256'];if($hs-and$hs-ne(HashBytes $bytes)){throw 'SHA256_MISMATCH'}
        return $bytes
    }finally{$r.Dispose()}
}
function ReportChild([string]$Artifact,[string]$Stage,$Result){
    WriteJson ($Stage+'.json') ([ordered]@{exit_code=$Result.exit_code;stdout=$Result.stdout;stderr=$Result.stderr})
    $diagnosed=@(Force-DiagnosticScan -Source 'UAUD-Diagnostics' -Artifact $Artifact -Lines $Result.lines -ExitCode $Result.exit_code -Stage $Stage -Context 'complete stdout/stderr batch collected before classification')
    WriteJson ($Stage+'-diagnostic.json') $diagnosed
    return $diagnosed
}

try {
    Stamp 'UAUD DIAGNOSTICS 1.4.0 — FORCE-FIRST INDEPENDENT NON-INSTALLING GATES'
    Stamp 'No UARD installation is performed by this diagnostic.'
    WriteJson 'run.json' ([ordered]@{schema=2;version='1.4.0';run_id=$RunId;baseline='OSblocker 1.0.0';install_performed=$false;installer_invoked=$false;middleman=$Middleman;expected_version=$ExpectedVersion;expected_protocol=$ExpectedProtocol;expected_baseline=$ExpectedBaseline})

    Stamp 'GATE 1 — required files + PowerShell parser'
    $required=@('UAUD.ps1','UAUD-regression-tests.ps1','self-repair.ps1','UAUD-validate.ps1','sandbox-behaviour.ps1','evidence.ps1','ErrorLibrary.ps1','packet-filter.ps1','artifact-schema.json','config.json','diagnostic-force-sandbox.ps1')
    $checks=@()
    foreach($f in $required){
        $p=Join-Path $Root $f
        if(-not(Test-Path -LiteralPath $p)){$checks+=[ordered]@{file=$f;pass=$false;error='FILE_MISSING'};continue}
        if($f.EndsWith('.ps1')){
            $r=ParseFile $p
            $checks+=[ordered]@{file=$f;pass=(@($r.errors).Count-eq0);errors=@($r.errors|ForEach-Object{[ordered]@{message=$_.Message;line=$_.Extent.StartLineNumber;column=$_.Extent.StartColumnNumber}});sha256=HashFile $p}
        }else{$checks+=[ordered]@{file=$f;pass=$true;sha256=HashFile $p}}
    }
    WriteJson 'file-check.json' $checks
    $bad=@($checks|Where-Object{-not$_.pass})
    if($bad.Count){Stamp 'FAIL — file/parser gate';exit 1}
    Stamp 'PASS — all required files parse'

    Stamp 'GATE 2 — ErrorLibrary force-first contract'
    $names=@('Get-ErrorFingerprint','Classify-ErrorText','Test-ErrorLike','Save-ErrorEvent','Force-DiagnosticScan','Scan-ErrorOutput')
    $fc=@($names|ForEach-Object{[ordered]@{name=$_;present=([bool](Get-Command $_ -ErrorAction SilentlyContinue))}})
    WriteJson 'error-library-check.json' ([ordered]@{pass=(@($fc|Where-Object{-not$_.present}).Count-eq0);functions=$fc;library_version=$ErrorLibraryVersion})
    if(@($fc|Where-Object{-not$_.present}).Count){Stamp 'FAIL — ErrorLibrary force-first contract';exit 1}
    Stamp 'PASS — force-first diagnostic checker available'

    Stamp 'GATE 3 — force-first diagnostic sandbox benchmark against OSblocker 1.0.0'
    $dr=RunChild (Join-Path $Root 'diagnostic-force-sandbox.ps1') @()
    $diag=ReportChild 'diagnostic-force-sandbox.ps1' 'diagnostic-benchmark' $dr
    if($dr.exit_code-ne0){Stamp ('FAIL — diagnostic benchmark exit='+$dr.exit_code);exit 1}
    Stamp 'PASS — force-first detector outperforms lexical baseline'

    Stamp 'GATE 4 — pinned 000-999 middleman + exact artifacts'
    try{$cb=FetchPinned 'ultra-mode/config.json';$pb=FetchPinned 'ultra-mode/packet-filter.ps1';WriteJson 'middleman-health.json' ([ordered]@{pass=$true;version=$ExpectedVersion;protocol=$ExpectedProtocol;baseline=$ExpectedBaseline;config_sha256=(HashBytes $cb);packet_filter_sha256=(HashBytes $pb)});Stamp 'PASS — pinned artifacts fetched with redirect rejection and byte-accurate SHA validation'}catch{WriteJson 'middleman-health.json' ([ordered]@{pass=$false;error=$_.Exception.Message});Stamp ('FAIL — middleman: '+$_.Exception.Message);exit 1}

    Stamp 'GATE 5 — canonical config sanity'
    try{$cfg=Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw|ConvertFrom-Json;$ok=($cfg.enabled-eq$true-and[string]$cfg.start-eq'05:00'-and[string]$cfg.end-eq'22:00'-and@($cfg.domains)-contains'youtube.com'-and@($cfg.domains)-contains'chatgpt.com'-and@($cfg.alwaysBlockedDomains)-contains'crushon.ai'-and@($cfg.alwaysAllowedDomains)-contains'windowsmcp.io')}catch{$ok=$false}
    WriteJson 'canonical-config-check.json' ([ordered]@{pass=$ok})
    if(-not$ok){Stamp 'FAIL — canonical config';exit 1};Stamp 'PASS — canonical policy shape'

    Stamp 'GATE 6 — validator child process'
    $tmp=Join-Path $env:TEMP ('uaud-diagnostic-'+$RunId+'.ps1');Set-Content -LiteralPath $tmp -Value '$x = @{ Enabled = $true; Start = ''05:00''; End = ''22:00'' }' -Encoding UTF8
    try{$vr=RunChild (Join-Path $Root 'UAUD-validate.ps1') @('-Candidate',$tmp,'-Artifact','diagnostic-candidate.ps1');$null=ReportChild 'UAUD-validate.ps1' 'validator' $vr}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
    if($vr.exit_code-ne0){Stamp ('FAIL — validator exit='+$vr.exit_code);exit 1};Stamp 'PASS — validator'

    Stamp 'GATE 7 — behavioural helper sandbox'
    $br=RunChild (Join-Path $Root 'sandbox-behaviour.ps1') @();$null=ReportChild 'sandbox-behaviour.ps1' 'behavioural' $br
    if($br.exit_code-ne0){Stamp ('FAIL — behavioural sandbox exit='+$br.exit_code);exit 1};Stamp 'PASS — behavioural sandbox'

    Stamp 'GATE 8 — historical + diagnostic regression suite'
    $rr=RunChild (Join-Path $Root 'UAUD-regression-tests.ps1') @();$null=ReportChild 'UAUD-regression-tests.ps1' 'regression' $rr
    if($rr.exit_code-ne0){Stamp ('FAIL — regression suite exit='+$rr.exit_code);exit 1};Stamp 'PASS — historical parser and force-first diagnostic regressions protected'

    Stamp 'GATE 9 — protected Windows boundary audit'
    $badKeywords=@('Set-NetFirewallRule','New-NetFirewallRule','Remove-NetFirewallRule','Set-DnsClientServerAddress','route.exe','netsh.exe')
    $viol=@()
    foreach($f in @('UAUD.ps1','UAUD-regression-tests.ps1','UAUD-validate.ps1','sandbox-behaviour.ps1','self-repair.ps1','ErrorLibrary.ps1','UAUD-diagnostics.ps1')){
        $text=Get-Content -LiteralPath (Join-Path $Root $f) -Raw
        foreach($k in $badKeywords){if($text -match [regex]::Escape($k)){$viol+=[ordered]@{file=$f;keyword=$k}}}
    }
    WriteJson 'boundary-audit.json' ([ordered]@{pass=(@($viol).Count-eq0);violations=$viol})
    if(@($viol).Count){Stamp 'FAIL — forbidden Windows configuration mutation reference found';exit 1};Stamp 'PASS — protected boundaries clean'

    WriteJson 'result.json' ([ordered]@{schema=2;status='PASS';diagnostic_mode='force-first';baseline='OSblocker 1.0.0';install_performed=$false;uaud_executed=$false;self_repair_executed=$false;timestamp_utc=[DateTime]::UtcNow.ToString('o');report=$Run})
    Stamp 'RESULT: PASS — force-first independent diagnostics complete; nothing was installed.'
    Stamp ('REPORT: '+$Run)
    exit 0
} catch {
    $fatal=[string]$_.Exception.Message
    Stamp ('FAIL-CLOSED: '+$fatal)
    try{if(Get-Command Force-DiagnosticScan -ErrorAction SilentlyContinue){$null=Force-DiagnosticScan -Source 'UAUD-Diagnostics' -Artifact 'UAUD-diagnostics.ps1' -Lines @($fatal) -ExitCode 1 -Stage 'fatal' -Context 'complete fatal message classified after collection'}}catch{}
    try{WriteJson 'fatal.json' ([ordered]@{status='FAIL';message=$fatal})}catch{}
    exit 1
} finally {
    Remove-Item -LiteralPath $ErrorLibraryPath -Force -ErrorAction SilentlyContinue
    $ErrorLibraryPath=$OldLibraryPath
}
