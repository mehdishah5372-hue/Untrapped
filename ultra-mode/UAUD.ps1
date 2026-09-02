# UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE
# Canonical visible launcher for UARD.
# The diagnostic is deliberately run in a separate NORMAL PowerShell window so
# live [UPDATE]/[POLICY]/[CORE]/[BRAVE]/[NETWORK]/[VERIFY] output is always visible.
# This launcher does not alter override policy or Windows networking infrastructure.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$UARD = Join-Path $Root 'self-repair.ps1'

if (-not (Test-Path -LiteralPath $UARD)) {
    throw "UARD not found: $UARD"
}

Write-Host 'UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE'
Write-Host 'Launching UARD in a visible PowerShell window...'
Write-Host ''

$argList = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-NoExit',
    '-File', $UARD
)

$p = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList $argList `
    -WorkingDirectory $Root `
    -WindowStyle Normal `
    -PassThru

Write-Host ('UARD PID: ' + $p.Id)
Write-Host 'The UARD window is intentionally left open after completion.'
Write-Host 'Close that window when you have finished reading the report.'

# Wait so UAUD itself remains a useful parent/status process, without hiding UARD.
$p.WaitForExit()
Write-Host ''
Write-Host ('UARD exit code: ' + $p.ExitCode)
Write-Host 'UAUD complete.'
