# UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE
# UAUD uses the UARD pinned to the 000-999 audit middleman.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$UARD=Join-Path $Root 'self-repair.ps1'
Write-Host 'UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE'
Write-Host 'Using UARD pinned to the 000-999 audit middleman.'
if(-not(Test-Path -LiteralPath $UARD)){throw "UARD not found: $UARD"}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UARD
exit $LASTEXITCODE
