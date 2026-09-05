param(
  [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json'),
  [int]$RefreshSeconds = 2,
  [int]$RestartSeconds = 1
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$workers=@()
function Start-Worker([int]$Priority){
  $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'packet-filter.ps1'),'-Priority',$Priority,'-RefreshSeconds',$RefreshSeconds,'-ConfigOverride',$ConfigPath)
  Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
}
try {
  $workers=@((Start-Worker 1000),(Start-Worker 999))
  Write-Host "SUPERVISOR STARTED workers=$($workers.Id -join ',')"
  while($true){
    for($i=0;$i -lt $workers.Count;$i++){
      $w=$workers[$i]
      if($w.HasExited){
        Write-Host "SUPERVISOR RECOVERY worker=$($w.Id) slot=$i exit=$($w.ExitCode)"
        $workers[$i]=Start-Worker (if($i -eq 0){1000}else{999})
      }
    }
    Start-Sleep -Seconds $RestartSeconds
  }
} finally {
  foreach($w in @($workers)){if($w -and -not $w.HasExited){Stop-Process -Id $w.Id -Force -ErrorAction SilentlyContinue}}
}
