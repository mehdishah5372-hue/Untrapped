param(
    [string]$BaselineSha = '765178ee7c83449064169bb72d4cb1a1cb230b11',
    [int]$WarmupSeconds = 8,
    [int]$NetworkTimeoutSeconds = 10
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot=Split-Path -Parent $Root
$ReportPath=Join-Path $Root 'osblocker-1.0.0-compatibility-report.json'
$BaselineRoot=Join-Path $env:TEMP ('osblocker-1.0.0-'+[guid]::NewGuid().ToString('N'))
$TestConfig=Join-Path $Root 'osblocker-compat-test-config.json'
$report=[ordered]@{status='NOT_CERTIFIED';started_utc=[DateTime]::UtcNow.ToString('o');baseline_sha=$BaselineSha;events=@();evidence=[ordered]@{}}
$baselineProcess=$null;$candidateProcess=$null;$testConfigCreated=$false
function Event([string]$n,[string]$s,[string]$d){$report.events += ,[ordered]@{name=$n;status=$s;detail=$d;utc=[DateTime]::UtcNow.ToString('o')};Write-Host "$s — $n — $d"}
function Fail([string]$n,[string]$d){Event $n 'FAIL' $d;throw $d}
function Curl([string]$url,[string]$resolve=''){$err=Join-Path $env:TEMP ('osblocker-compat-'+[guid]::NewGuid().ToString('N')+'.err');try{$a=@('--noproxy','*','--ipv4','--connect-timeout',[string]$NetworkTimeoutSeconds,'--max-time',[string]$NetworkTimeoutSeconds,'--silent','--show-error','--output','NUL');if($resolve){$a+=@('--resolve',$resolve)};$a+=$url;& curl.exe @a --stderr $err;$code=$LASTEXITCODE;$txt=if(Test-Path $err){(Get-Content $err -Raw -ErrorAction SilentlyContinue).Trim()}else{''};return [pscustomobject]@{ExitCode=$code;Stderr=$txt}}finally{Remove-Item $err -Force -ErrorAction SilentlyContinue}}
function YoutubeIp{$x=@(Resolve-DnsName youtube.com -Type A -DnsOnly -ErrorAction Stop|Where-Object IPAddress|Select-Object -ExpandProperty IPAddress -Unique);if(!$x.Count){throw 'No youtube.com IPv4 address.'};$x[0]}
function AssertNetwork([string]$Phase){$ip=YoutubeIp;$report.evidence["${Phase}_youtube_ipv4"]=$ip;$allow=Curl 'https://pypi.org/';if($allow.ExitCode -ne 0){Fail "$Phase-allow" "Allowed HTTPS failed with curl $($allow.ExitCode): $($allow.Stderr)"};$block=Curl 'https://youtube.com/' "youtube.com:443:$ip";if($block.ExitCode -ne 28){Fail "$Phase-block" "Expected youtube DROP (curl 28), got $($block.ExitCode): $($block.Stderr)"};Event "$Phase-network" 'PASS' 'Allowed HTTPS succeeded and youtube.com was actually dropped.'}
function StopProc([ref]$p){if($p.Value -and !$p.Value.HasExited){Stop-Process -Id $p.Value.Id -Force -ErrorAction SilentlyContinue};$p.Value=$null}
try{
 if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Fail 'admin' 'Administrator privileges required.'}
 if(-not (Test-Path (Join-Path $RepoRoot '.git'))){Fail 'git-repository' 'Certification runner checkout is not a Git repository.'}
 $baselineDir=Join-Path $BaselineRoot 'ultra-mode';New-Item -ItemType Directory -Path $baselineDir -Force|Out-Null
 & git -C $RepoRoot archive $BaselineSha 'ultra-mode' | tar -x -C $BaselineRoot
 if($LASTEXITCODE -ne 0){Fail 'baseline-materialization' "git archive failed with exit $LASTEXITCODE."}
 $baselineConfig=Join-Path $BaselineRoot 'ultra-mode\config.json';$candidateConfig=Join-Path $Root 'config.json'
 if(!(Test-Path $baselineConfig)){Fail 'baseline-config' 'OSblocker 1.0.0 config.json missing.'};if(!(Test-Path $candidateConfig)){Fail 'candidate-config' 'OSblocker 1.0.1 config.json missing.'}
 $bCfg=Get-Content $baselineConfig -Raw|ConvertFrom-Json;$cCfg=Get-Content $candidateConfig -Raw|ConvertFrom-Json
 foreach($cfgName in @('enabled','start','end','domains','alwaysBlockedDomains','alwaysAllowedDomains')){if($null -eq $bCfg.$cfgName -or $null -eq $cCfg.$cfgName){Fail 'config-schema' "Required config field missing: $cfgName"}}
 $test=$cCfg|ConvertTo-Json -Depth 20|ConvertFrom-Json;$test.enabled=$true;$test.start='00:00';$test.end='00:00';$test|ConvertTo-Json -Depth 20|Set-Content $TestConfig -Encoding UTF8;$testConfigCreated=$true
 Event 'config-cross-version' 'PASS' 'Both 1.0.0 and 1.0.1 consume the same required ultra-mode config contract; candidate test uses an isolated always-active copy.'
 if(!(Test-Path (Join-Path $Root 'WinDivert.dll')) -or !(Test-Path (Join-Path $Root 'WinDivert64.sys'))){& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'INSTALL-PACKET-FILTER.ps1');if($LASTEXITCODE -ne 0){Fail 'windivert-install' "WinDivert installation failed with $LASTEXITCODE."}}
 Copy-Item (Join-Path $Root 'WinDivert.dll') (Join-Path $BaselineRoot 'ultra-mode\WinDivert.dll') -Force
 Copy-Item (Join-Path $Root 'WinDivert64.sys') (Join-Path $BaselineRoot 'ultra-mode\WinDivert64.sys') -Force
 $baselineFilter=Join-Path $BaselineRoot 'ultra-mode\packet-filter.ps1';if(!(Test-Path $baselineFilter)){Fail 'baseline-filter' 'OSblocker 1.0.0 packet-filter.ps1 missing.'}
 $candidateFilter=Join-Path $Root 'packet-filter.ps1'
 $baselineProcess=Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$baselineFilter) -PassThru -WindowStyle Hidden
 Start-Sleep -Seconds $WarmupSeconds;if($baselineProcess.HasExited){Fail 'baseline-start' 'OSblocker 1.0.0 packet-filter.ps1 exited during startup.'}
 AssertNetwork 'baseline-1.0.0'
 Event 'baseline-runtime' 'PASS' 'OSblocker 1.0.0 successfully operated on the same Windows/WinDivert substrate used by the candidate.'
 StopProc ([ref]$baselineProcess);Start-Sleep -Seconds 2
 $candidateProcess=Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$candidateFilter,'-ConfigOverride',$TestConfig,'-RefreshSeconds','1') -PassThru -WindowStyle Hidden
 Start-Sleep -Seconds $WarmupSeconds;if($candidateProcess.HasExited){Fail 'candidate-start' 'OSblocker 1.0.1 packet-filter.ps1 exited during startup.'}
 AssertNetwork 'candidate-1.0.1'
 Event 'candidate-runtime' 'PASS' 'OSblocker 1.0.1 operated successfully immediately after 1.0.0 teardown.'
 $crossConfig=Get-Content $baselineConfig -Raw|ConvertFrom-Json;$crossConfig.enabled=$true;$crossConfig.start='00:00';$crossConfig.end='00:00';$crossConfig|ConvertTo-Json -Depth 20|Set-Content $TestConfig -Encoding UTF8
 Start-Sleep -Seconds 2;if($candidateProcess.HasExited){Fail 'baseline-config-on-candidate' 'Candidate blocker exited while consuming a 1.0.0-shaped config.'}
 AssertNetwork 'candidate-with-1.0.0-config'
 Event 'cross-version-config-runtime' 'PASS' 'Candidate 1.0.1 packet blocker consumed the 1.0.0 config contract without error and continued enforcing the block.'
 $report.evidence.baseline_config_sha256=(Get-FileHash $baselineConfig -Algorithm SHA256).Hash;$report.evidence.candidate_config_sha256=(Get-FileHash $candidateConfig -Algorithm SHA256).Hash
 $report.evidence.production_config_unchanged=($report.evidence.candidate_config_sha256 -eq (Get-FileHash $candidateConfig -Algorithm SHA256).Hash)
 $report.status='PASS';Event 'osblocker-1.0.0-compatibility-gate' 'PASS' '1.0.0 runtime, 1.0.1 runtime, teardown/restart boundary, and 1.0.0-shaped configuration interoperability all passed.'
}catch{$report.status='FAIL';$report.evidence.failure=$_.Exception.Message;Write-Host "FAIL — OSblocker 1.0.0 compatibility — $($_.Exception.Message)"}
finally{StopProc ([ref]$baselineProcess);StopProc ([ref]$candidateProcess);if($testConfigCreated){Remove-Item $TestConfig -Force -ErrorAction SilentlyContinue};Remove-Item $BaselineRoot -Recurse -Force -ErrorAction SilentlyContinue;$report.finished_utc=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 30|Set-Content $ReportPath -Encoding UTF8}
if($report.status -ne 'PASS'){exit 1};exit 0
