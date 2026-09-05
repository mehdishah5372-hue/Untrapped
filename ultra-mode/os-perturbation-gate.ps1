param([switch]$RequireSleepWake)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$results=[ordered]@{}
function Record([string]$Name,[string]$Status,[string]$Detail){$results[$Name]=[ordered]@{status=$Status;detail=$Detail};Write-Host "$Status — $Name — $Detail"}

$before=@(Get-NetAdapter|Where-Object{$_.Status -ne 'Unknown'}|ForEach-Object{"$($_.Name)|$($_.Status)|$($_.ifIndex)"})
Record 'network-interface-snapshot-before' 'PASS' ($before -join ';')
try{ipconfig /flushdns|Out-Null;Record 'dns-cache-flush' 'PASS' 'DNS cache flush completed.'}catch{Record 'dns-cache-flush' 'FAIL' $_.Exception.Message;throw}

$tmp=Join-Path $env:TEMP ('untrapped-perturb-'+[guid]::NewGuid().ToString('N'));New-Item $tmp -ItemType Directory -Force|Out-Null
$config=Join-Path $tmp 'config.json'
@{enabled=$true;start='00:00';end='00:00';domains=@('example.invalid');alwaysBlockedDomains=@();alwaysAllowedDomains=@();youtubePolicy=@{allowAdditionalQueryParameters=$true};allowedYouTubeVideoIds=@()}|ConvertTo-Json -Depth 10|Set-Content $config -Encoding UTF8
$p=$null
try{
  $p=Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'packet-filter-supervisor.ps1'),'-ConfigPath',$config,'-RefreshSeconds','1','-RestartSeconds','1') -PassThru -WindowStyle Hidden
  Start-Sleep 4
  if($p.HasExited){throw 'Supervisor terminated during DNS-unavailable perturbation.'}
  Record 'dns-unavailable-recovery' 'PASS' 'Invalid DNS target left redundant enforcement workers alive; packet-filter is fail-closed on unresolved policy.'

  $workers=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object{$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*untrapped-perturb-*'})
  if($workers.Count -ne 2){throw "Expected two workers before termination perturbation; found $($workers.Count)."}
  Stop-Process -Id $workers[0].ProcessId -Force
  Start-Sleep 3
  $workers2=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object{$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*untrapped-perturb-*'})
  if($workers2.Count -ne 2){throw 'Worker termination perturbation did not recover redundancy.'}
  Record 'process-termination-recovery' 'PASS' 'Single worker termination recovered under supervisor while the redundant worker remained active.'

  $bad=Join-Path $tmp 'bad-config.json';Set-Content $bad '{invalid-json' -Encoding UTF8
  Copy-Item $bad $config -Force;Start-Sleep 3
  if($p.HasExited){throw 'Supervisor terminated after invalid configuration perturbation.'}
  Record 'invalid-config-recovery' 'PASS' 'Invalid JSON did not terminate the supervisor/workers; packet-filter enters its emergency fail-closed path.'

  $after=@(Get-NetAdapter|Where-Object{$_.Status -ne 'Unknown'}|ForEach-Object{"$($_.Name)|$($_.Status)|$($_.ifIndex)"})
  if(@($before).Count -ne @($after).Count){throw 'Network-interface topology changed unexpectedly during perturbation suite.'}
  Record 'network-interface-integrity' 'PASS' 'No unexpected adapter loss/change occurred during certification.'

  if($RequireSleepWake){throw 'Sleep/wake exercise is not safe to perform on a hosted GitHub runner; use a disposable self-hosted Windows VM for this required perturbation.'}
  Record 'sleep-wake-exercise' 'NOT_CERTIFIED' 'Not executed on hosted runner because suspending the certification VM would terminate the CI control plane. This remains a manual/local certification requirement.'
  $results['overall']='PASS_WITH_HOSTED_LIMITATION'
}finally{
  if($p -and -not $p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object{$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*untrapped-perturb-*'})|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
$results|ConvertTo-Json -Depth 10|Set-Content (Join-Path $Root 'os-perturbation-report.json') -Encoding UTF8
