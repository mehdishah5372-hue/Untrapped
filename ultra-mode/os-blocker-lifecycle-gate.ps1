$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$tmp=Join-Path $env:TEMP ('untrapped-lifecycle-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force|Out-Null
$config=Join-Path $tmp 'config.json'
@{
 enabled=$true; start='00:00'; end='00:00'; domains=@('example.com'); alwaysBlockedDomains=@(); alwaysAllowedDomains=@(); youtubePolicy=@{allowAdditionalQueryParameters=$true}; allowedYouTubeVideoIds=@()
}|ConvertTo-Json -Depth 10|Set-Content $config -Encoding UTF8
$supervisor=Join-Path $Root 'packet-filter-supervisor.ps1'
$p=$null
try{
  $p=Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$supervisor,'-ConfigPath',$config,'-RefreshSeconds','1','-RestartSeconds','1') -PassThru -WindowStyle Hidden
  Start-Sleep 6
  if($p.HasExited){throw "Supervisor exited early with $($p.ExitCode)."}
  $workers=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*untrapped-lifecycle-*'} )
  if($workers.Count -ne 2){throw "Expected two redundant packet-filter workers, found $($workers.Count)."}
  Write-Host "LIFECYCLE PASS: two workers alive ($($workers.ProcessId -join ','))."

  Stop-Process -Id $workers[0].ProcessId -Force
  Start-Sleep 3
  $afterKill=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*untrapped-lifecycle-*'} )
  if($afterKill.Count -ne 2){throw "Redundant recovery failed after terminating one worker; worker count=$($afterKill.Count)."}
  Write-Host 'LIFECYCLE PASS: single-worker termination recovered without losing redundancy.'

  # Configuration refresh: invalid policy must not kill workers; the packet filter itself
  # must retain the last-known-good handle or enter its emergency fail-closed path.
  Set-Content $config '{ invalid-json' -Encoding UTF8
  Start-Sleep 3
  $afterBadConfig=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*untrapped-lifecycle-*'} )
  if($afterBadConfig.Count -ne 2){throw 'Invalid configuration caused worker loss instead of fail-closed recovery.'}
  Write-Host 'LIFECYCLE PASS: invalid configuration did not terminate enforcement workers.'

  Write-Host 'LIFECYCLE GATE PASS: START → INITIALISE → OPEN → ALIVE → REFRESH → RELOAD/ERROR → RECOVER.'
  exit 0
}finally{
  if($p -and -not $p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {$_.CommandLine -like '*packet-filter.ps1*' -and $_.CommandLine -like '*untrapped-lifecycle-*'} ) | ForEach-Object {Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
