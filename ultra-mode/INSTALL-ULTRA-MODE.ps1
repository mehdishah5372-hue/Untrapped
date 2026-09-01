# Untrapped Ultra Mode installer for Windows.
# Run PowerShell as Administrator from the repository's ultra-mode directory.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Runner = Join-Path $Root 'ultra-mode.ps1'
$TaskName = 'Untrapped Ultra Mode'
$KeySource = Join-Path $env:USERPROFILE 'Untrapped-Ultra-Key\ultra-public.json'
$KeyDir = Join-Path $env:ProgramData 'Untrapped-Ultra'
$KeyDest = Join-Path $KeyDir 'ultra-public.json'
if (-not (Test-Path $KeySource)) { throw "Public key not found at $KeySource. Generate/copy your public key there first." }
New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null
Copy-Item $KeySource $KeyDest -Force
$TaskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Runner`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Runner`""
$logon = New-ScheduledTaskTrigger -AtLogOn
$startup = New-ScheduledTaskTrigger -AtStartup
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $startup, $repeat) -Principal $principal -Force | Out-Null
Write-Host "Installed: $TaskName"
Write-Host "Public verification key installed at: $KeyDest"
Write-Host "Schedule is controlled by ultra-mode/config.json"
Write-Host "Default: 05:00-23:00"
