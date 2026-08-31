# Untrapped Ultra Mode installer for Windows
# Run PowerShell as Administrator from the repository root.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Runner = Join-Path $Root 'ultra-mode.ps1'
$TaskName = 'Untrapped Ultra Mode'
$TaskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Runner`""

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Runner`""
$logon = New-ScheduledTaskTrigger -AtLogOn
$startup = New-ScheduledTaskTrigger -AtStartup
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $startup, $repeat) -Principal $principal -Force | Out-Null
Write-Host "Installed: $TaskName"
Write-Host "Schedule is controlled by ultra-mode/config.json"
Write-Host "Default: 22:00-07:00"
