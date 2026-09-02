# UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE
# Canonical visible launcher. Runs UARD through the dedicated 000-999 audit bridge.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$Bridge=Join-Path $Root 'UARD-000-999.ps1'
if(-not(Test-Path -LiteralPath $Bridge)){throw "UARD-000-999 bridge not found: $Bridge"}
Write-Host 'UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE'
Write-Host 'Launching UARD through the 000-999 audit middleman...'
$escaped=$Bridge.Replace("'","''")
$cmd="& '$escaped'"
$p=Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',$cmd) -WorkingDirectory $Root -WindowStyle Normal -PassThru
Write-Host ('UARD PID: '+$p.Id)
Write-Host 'The UARD console is deliberately kept open.'
$p.WaitForExit()
Write-Host ('UARD exit code: '+$p.ExitCode)
Write-Host 'UAUD complete.'
