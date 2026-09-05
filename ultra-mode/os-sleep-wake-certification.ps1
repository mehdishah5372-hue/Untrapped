param(
  [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json'),
  [int]$WarmupSeconds = 8,
  [int]$ResumeTimeoutSeconds = 120
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$report=[ordered]@{status='NOT_CERTIFIED';started_utc=[DateTime]::UtcNow.ToString('o');events=@()}
function Event([string]$Name,[string]$Status,[string]$Detail){$report.events+=,[ordered]@{name=$Name;status=$Status;detail=$Detail;utc=[DateTime]::UtcNow.ToString('o')};Write-Host "$Status — $Name — $Detail"}
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator privileges are required.'}
if(-not (Test-Path $ConfigPath)){throw "Missing config: $ConfigPath"}
$supervisor=Join-Path $Root 'packet-filter-supervisor.ps1'
$stamp=Join-Path $env:TEMP ('osblocker-sleepwake-'+[guid]::NewGuid().ToString('N'))
New-Item $stamp -ItemType Directory -Force|Out-Null
$p=$null
try{
  $p=Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$supervisor,'-ConfigPath',$ConfigPath,'-RefreshSeconds','1','-RestartSeconds','1') -PassThru -WindowStyle Hidden
  Start-Sleep $WarmupSeconds
  if($p.HasExited){throw 'Supervisor exited before suspend.'}
  $workers=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object{$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*-ConfigOverride*'})
  if($workers.Count -lt 2){throw "Expected redundant workers before suspend; found $($workers.Count)."}
  Event 'pre-sleep-supervisor' 'PASS' "Supervisor alive with $($workers.Count) workers."
  $beforeAdapters=@(Get-NetAdapter|Where-Object Status -ne 'Unknown'|ForEach-Object{"$($_.Name)|$($_.Status)|$($_.ifIndex)"})
  $beforeBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  Event 'pre-sleep-state' 'PASS' "Adapters=$($beforeAdapters -join ';')"
  $watch=Start-Job -ScriptBlock { Start-Sleep -Seconds 5; while($true){try{Get-Date -Format o; break}catch{};Start-Sleep 2} }
  Event 'suspend-request' 'STARTED' 'Requesting genuine Windows suspend; this test must run on a disposable self-hosted Windows VM, never a hosted CI runner.'
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class UntrappedPower { [DllImport("PowrProf.dll", SetLastError=true)] public static extern uint SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent); }
"@
  [void][UntrappedPower]::SetSuspendState($false,$false,$false)
  $deadline=(Get-Date).AddSeconds($ResumeTimeoutSeconds)
  while((Get-Date)-lt $deadline){Start-Sleep 2;if(-not $p.HasExited){break}}
  if($p.HasExited){throw 'Supervisor exited after resume.'}
  $workersAfter=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object{$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*-ConfigOverride*'})
  if($workersAfter.Count -lt 2){throw "Redundant workers were not restored after resume; found $($workersAfter.Count)."}
  $afterAdapters=@(Get-NetAdapter|Where-Object Status -ne 'Unknown'|ForEach-Object{"$($_.Name)|$($_.Status)|$($_.ifIndex)"})
  if($afterAdapters.Count -ne $beforeAdapters.Count){throw 'Adapter topology changed after resume.'}
  Event 'post-sleep-supervisor' 'PASS' "Supervisor and redundancy survived resume; workers=$($workersAfter.Count)."
  Event 'post-sleep-adapter-integrity' 'PASS' 'Network adapter topology remained intact after resume.'
  $report.status='PASS'
}finally{
  if($p -and -not $p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object{$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*-ConfigOverride*'})|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  Remove-Item $stamp -Recurse -Force -ErrorAction SilentlyContinue
}
$report.finished_utc=[DateTime]::UtcNow.ToString('o')
$report|ConvertTo-Json -Depth 20|Set-Content (Join-Path $Root 'os-sleep-wake-report.json') -Encoding UTF8
if($report.status -ne 'PASS'){exit 1}
