# UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE
# Canonical visible launcher for UARD. Explicitly creates a visible console window.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$UARD = Join-Path $Root 'self-repair.ps1'
if (-not (Test-Path -LiteralPath $UARD)) { throw "UARD not found: $UARD" }
Write-Host 'UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE'
Write-Host 'Launching UARD in a dedicated visible PowerShell console...'
Write-Host ''
$escaped = $UARD.Replace("'", "''")
$cmd = "& '$escaped'"
$p = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',$cmd) `
    -WorkingDirectory $Root `
    -WindowStyle Normal `
    -PassThru
Write-Host ('UARD PID: ' + $p.Id)
Write-Host 'The UARD console is deliberately kept open.'
$p.WaitForExit()
Write-Host ('UARD exit code: ' + $p.ExitCode)
Write-Host 'UAUD complete.'
