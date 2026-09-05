param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json'),
    [int]$WarmupSeconds = 10,
    [int]$ResumeTimeoutSeconds = 120,
    [int]$NetworkTimeoutSeconds = 12
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReportPath = Join-Path $Root 'os-sleep-wake-report.json'
$TestConfigPath = Join-Path $Root 'os-sleep-wake-test-config.json'
$report = [ordered]@{ status='NOT_CERTIFIED'; started_utc=[DateTime]::UtcNow.ToString('o'); events=@(); evidence=[ordered]@{} }
$supervisorProcess=$null; $testConfigCreated=$false
function Event([string]$Name,[string]$Status,[string]$Detail){$report.events += ,[ordered]@{name=$Name;status=$Status;detail=$Detail;utc=[DateTime]::UtcNow.ToString('o')};Write-Host "$Status — $Name — $Detail"}
function Fail([string]$Name,[string]$Detail){Event $Name 'FAIL' $Detail;throw $Detail}
function Get-WorkerProcesses{@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop|Where-Object{$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*-ConfigOverride*'})}
function Get-PowerEvents([datetime]$StartTime){
 $events42=@(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Power';Id=42;StartTime=$StartTime}-ErrorAction SilentlyContinue)
 $events107=@(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Power';Id=107;StartTime=$StartTime}-ErrorAction SilentlyContinue)
 [ordered]@{sleep_events=@($events42|Select-Object -First 10|ForEach-Object{$_.TimeCreated.ToString('o')});resume_events=@($events107|Select-Object -First 10|ForEach-Object{$_.TimeCreated.ToString('o')});sleep_count=$events42.Count;resume_count=$events107.Count;latest_sleep_utc=if($events42.Count){$events42[0].TimeCreated.ToUniversalTime().ToString('o')}else{$null};latest_resume_utc=if($events107.Count){$events107[0].TimeCreated.ToUniversalTime().ToString('o')}else{$null}}
}
function Invoke-Curl([string[]]$Arguments,[string]$Name){$stderr=Join-Path $env:TEMP("osblocker-sleep-$([Guid]::NewGuid().ToString('N')).err");try{& curl.exe @Arguments --stderr $stderr;$exitCode=$LASTEXITCODE;$errorText=if(Test-Path $stderr){(Get-Content $stderr -Raw -ErrorAction SilentlyContinue).Trim()}else{''};return [pscustomobject]@{Name=$Name;ExitCode=$exitCode;Stderr=$errorText}}finally{Remove-Item $stderr -Force -ErrorAction SilentlyContinue}}
function Get-YoutubeIPv4{$ips=@(Resolve-DnsName -Name 'youtube.com' -Type A -DnsOnly -ErrorAction Stop|Where-Object{$_.IPAddress}|Select-Object -ExpandProperty IPAddress -Unique);if($ips.Count -eq 0){throw 'youtube.com returned no IPv4 address.'};$ips[0]}
function Test-NetworkState([string]$Phase){
 $youtubeIp=Get-YoutubeIPv4;$report.evidence["${Phase}_youtube_ipv4"]=$youtubeIp
 $allow=Invoke-Curl @('--noproxy','*','--ipv4','--connect-timeout',[string]$NetworkTimeoutSeconds,'--max-time',[string]$NetworkTimeoutSeconds,'--silent','--show-error','--output','NUL','https://pypi.org/') "${Phase}-allow"
 if($allow.ExitCode -ne 0){Fail "${Phase}-allowed-network" "Independent allowed HTTPS probe failed with curl exit $($allow.ExitCode): $($allow.Stderr)"}
 $block=Invoke-Curl @('--noproxy','*','--ipv4','--connect-timeout',[string]$NetworkTimeoutSeconds,'--max-time',[string]$NetworkTimeoutSeconds,'--silent','--show-error','--output','NUL','--resolve',"youtube.com:443:$youtubeIp",'https://youtube.com/') "${Phase}-block"
 if($block.ExitCode -ne 28){Fail "${Phase}-youtube-block" "Expected real HTTPS DROP to produce curl exit 28; got exit $($block.ExitCode): $($block.Stderr)"}
 Event "${Phase}-network" 'PASS' 'Allowed HTTPS succeeded and exact youtube.com HTTPS attempt was independently dropped (curl 28).'
}
try{
 if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Fail 'admin-state' 'Administrator privileges are required.'}
 if(-not (Test-Path $ConfigPath)){Fail 'config-presence' "Missing config: $ConfigPath"}
 if(-not (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)){Fail 'event-log-api' 'Get-WinEvent is unavailable; cannot prove genuine suspend/resume.'}
 $originalConfigHash=(Get-FileHash $ConfigPath -Algorithm SHA256).Hash
 $cfg=Get-Content $ConfigPath -Raw|ConvertFrom-Json;$cfg.enabled=$true;$cfg.start='00:00';$cfg.end='00:00';$cfg|ConvertTo-Json -Depth 20|Set-Content $TestConfigPath -Encoding UTF8;$testConfigCreated=$true
 $report.evidence.original_config_sha256=$originalConfigHash;$report.evidence.test_config_sha256=(Get-FileHash $TestConfigPath -Algorithm SHA256).Hash
 Event 'test-config-isolation' 'PASS' 'Created an isolated always-active copy; production ultra-mode/config.json was not modified.'
 $powerAvailability=(& powercfg.exe /a 2>&1|Out-String).Trim();$report.evidence.powercfg_a=$powerAvailability;if($LASTEXITCODE -ne 0){Fail 'power-state-capability' "powercfg /a failed with exit $LASTEXITCODE."};Event 'power-state-capability' 'PASS' 'Windows power-state capability was queried before requesting suspend.'
 $supervisor=Join-Path $Root 'packet-filter-supervisor.ps1';if(-not (Test-Path $supervisor)){Fail 'supervisor-presence' "Missing supervisor: $supervisor"}
 $preEventWindow=(Get-Date).AddSeconds(-10)
 $supervisorProcess=Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$supervisor,'-ConfigPath',$TestConfigPath,'-RefreshSeconds','1','-RestartSeconds','1') -PassThru -WindowStyle Hidden
 Start-Sleep -Seconds $WarmupSeconds;if($supervisorProcess.HasExited){Fail 'pre-sleep-supervisor' 'Supervisor exited before suspend.'}
 $beforeWorkers=@(Get-WorkerProcesses);if($beforeWorkers.Count -lt 2){Fail 'pre-sleep-redundancy' "Expected two workers before suspend; found $($beforeWorkers.Count)."}
 $beforeAdapters=@(Get-NetAdapter|Where-Object Status -ne 'Unknown'|ForEach-Object{"$($_.Name)|$($_.Status)|$($_.ifIndex)"});if($beforeAdapters.Count -eq 0){Fail 'pre-sleep-adapters' 'No usable network adapters were present before suspend.'}
 $report.evidence.pre_sleep_supervisor_pid=$supervisorProcess.Id;$report.evidence.pre_sleep_worker_pids=@($beforeWorkers.ProcessId);$report.evidence.pre_sleep_adapters=$beforeAdapters
 Event 'pre-sleep-state' 'PASS' "Supervisor $($supervisorProcess.Id) alive with $($beforeWorkers.Count) workers and $($beforeAdapters.Count) adapters.";Test-NetworkState 'pre-sleep'
 if(-not ('UntrappedPower.Sleep' -as [type])){Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace UntrappedPower { public static class Sleep { [DllImport("PowrProf.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetSuspendState(bool hibernate,bool forceCritical,bool disableWakeEvent); } }
"@}
 $suspendRequestedUtc=[DateTime]::UtcNow;$report.evidence.suspend_requested_utc=$suspendRequestedUtc.ToString('o');Event 'suspend-request' 'STARTED' 'Genuine Windows suspend requested through PowrProf.SetSuspendState(FALSE,...).'
 $suspendOk=[UntrappedPower.Sleep]::SetSuspendState($false,$false,$false);if(-not $suspendOk){$errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error();Fail 'suspend-request' "SetSuspendState failed with Windows error $errorCode."}
 $resumeDeadline=(Get-Date).AddSeconds($ResumeTimeoutSeconds);$powerEvidence=$null
 while((Get-Date)-lt $resumeDeadline){Start-Sleep -Seconds 2;$powerEvidence=Get-PowerEvents $preEventWindow;if($powerEvidence.sleep_count -gt 0 -and $powerEvidence.resume_count -gt 0){$sleepCandidate=[DateTime]::Parse($powerEvidence.latest_sleep_utc).ToUniversalTime();$resumeCandidate=[DateTime]::Parse($powerEvidence.latest_resume_utc).ToUniversalTime();if(($sleepCandidate -ge $suspendRequestedUtc.AddSeconds(-5)) -and ($resumeCandidate -gt $sleepCandidate)){break}}}
 if($null -eq $powerEvidence){$powerEvidence=Get-PowerEvents $preEventWindow};$report.evidence.power_events=$powerEvidence
 if($powerEvidence.sleep_count -lt 1){Fail 'genuine-suspend-proof' 'No Kernel-Power Event ID 42 was recorded; actual entry into sleep was not proven.'}
 if($powerEvidence.resume_count -lt 1){Fail 'genuine-resume-proof' 'No Kernel-Power Event ID 107 was recorded; actual resume from sleep was not proven.'}
 $sleepUtc=[DateTime]::Parse($powerEvidence.latest_sleep_utc).ToUniversalTime();$resumeUtc=[DateTime]::Parse($powerEvidence.latest_resume_utc).ToUniversalTime()
 if($sleepUtc -lt $suspendRequestedUtc.AddSeconds(-5)){Fail 'sleep-request-correlation' "Latest sleep event at $sleepUtc is too early to be correlated with suspend request at $suspendRequestedUtc."}
 if($resumeUtc -le $sleepUtc){Fail 'sleep-resume-order' 'Kernel-Power resume event did not occur after the sleep event.'}
 Event 'genuine-suspend-resume' 'PASS' "Kernel-Power recorded correlated sleep Event 42 at $sleepUtc and resume Event 107 at $resumeUtc."
 if($supervisorProcess.HasExited){Fail 'post-resume-supervisor' 'Supervisor exited across resume.'}
 $afterWorkers=@(Get-WorkerProcesses);if($afterWorkers.Count -lt 2){Fail 'post-resume-redundancy' "Expected two workers after resume; found $($afterWorkers.Count)."}
 $afterAdapters=@(Get-NetAdapter|Where-Object Status -ne 'Unknown'|ForEach-Object{"$($_.Name)|$($_.Status)|$($_.ifIndex)"});if($afterAdapters.Count -ne $beforeAdapters.Count){Fail 'post-resume-adapters' "Adapter topology changed: before=$($beforeAdapters.Count), after=$($afterAdapters.Count)."}
 $missingAdapters=@($beforeAdapters|Where-Object{$_ -notin $afterAdapters});if($missingAdapters.Count -gt 0){Fail 'post-resume-adapter-integrity' "Adapters disappeared or changed identity: $($missingAdapters -join '; ')"}
 $report.evidence.post_resume_worker_pids=@($afterWorkers.ProcessId);$report.evidence.post_resume_adapters=$afterAdapters
 Event 'post-resume-state' 'PASS' "Supervisor $($supervisorProcess.Id) remained alive with $($afterWorkers.Count) workers and unchanged adapter topology.";Test-NetworkState 'post-resume'
 $finalConfigHash=(Get-FileHash $ConfigPath -Algorithm SHA256).Hash;if($finalConfigHash -ne $originalConfigHash){Fail 'production-config-integrity' 'Production ultra-mode/config.json changed during the sleep/resume certification.'}
 Event 'production-config-integrity' 'PASS' 'Production ultra-mode/config.json SHA-256 is unchanged from the pre-test snapshot.'
 $report.status='PASS';Event 'sleep-wake-gate' 'PASS' 'Genuine sleep/resume, blocker lifecycle, redundancy, adapter integrity, and post-resume real network enforcement all passed.'
}catch{$report.status='FAIL';$report.evidence.failure=$_.Exception.Message;Write-Host "FAIL — sleep-wake gate — $($_.Exception.Message)"}
finally{if($supervisorProcess -and -not $supervisorProcess.HasExited){Stop-Process -Id $supervisorProcess.Id -Force -ErrorAction SilentlyContinue};@(Get-WorkerProcesses)|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue};if($testConfigCreated){Remove-Item $TestConfigPath -Force -ErrorAction SilentlyContinue};$report.finished_utc=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 30|Set-Content $ReportPath -Encoding UTF8}
if($report.status -ne 'PASS'){exit 1};exit 0
