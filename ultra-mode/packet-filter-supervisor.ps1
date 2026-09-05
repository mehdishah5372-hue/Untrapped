param(
  [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json'),
  [int]$RefreshSeconds = 2,
  [int]$RestartSeconds = 1
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$workers=@($null,$null)
function Start-Worker([int]$Priority){
  $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'packet-filter.ps1'),'-Priority',$Priority,'-RefreshSeconds',$RefreshSeconds,'-ConfigOverride',$ConfigPath)
  Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
}
function Worker-IsAlive($w){
  if($null -eq $w){return $false}
  try { return -not [bool]$w.HasExited } catch { return $false }
}
try {
  for($i=0;$i -lt 2;$i++){$workers[$i]=Start-Worker (if($i -eq 0){1000}else{999})}
  Write-Host "SUPERVISOR STARTED workers=$($workers.Id -join ',')"
  while($true){
    for($i=0;$i -lt 2;$i++){
      if(-not (Worker-IsAlive $workers[$i])){
        $oldId=if($workers[$i]){$workers[$i].Id}else{'none'}
        $priority=if($i -eq 0){1000}else{999}
        try {
          $replacement=Start-Worker $priority
          $workers[$i]=$replacement
          Write-Host "SUPERVISOR RECOVERY worker=$oldId slot=$i replacement=$($replacement.Id)"
        } catch {
          Write-Host "SUPERVISOR RECOVERY ERROR slot=$i priority=$priority error=$($_.Exception.Message)"
          $workers[$i]=$null
        }
      }
    }
    Start-Sleep -Seconds $RestartSeconds
  }
} finally {
  foreach($w in @($workers)){if($w -and (Worker-IsAlive $w)){Stop-Process -Id $w.Id -Force -ErrorAction SilentlyContinue}}
}
