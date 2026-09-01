# Install the Ultra Mode static firewall backstop as a SYSTEM task.
# This version intentionally uses Windows Firewall instead of a third-party packet
# interception driver. It covers IPv4/IPv6 and both TCP/443 and UDP/443.
# Run this script as Administrator.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$runner=Join-Path $root 'packet-filter.ps1'
$taskName='Untrapped Ultra Mode Static Backstop'

if(-not(Test-Path $runner)){throw "Missing $runner"}

$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`""
$startup=New-ScheduledTaskTrigger -AtStartup
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $startup -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Host "Installed and started: $taskName"
Write-Host 'The backstop refreshes blocked destination IPs every 60 seconds.'
Write-Host 'It blocks TCP/443 and UDP/443 for all domains in config.json.'
