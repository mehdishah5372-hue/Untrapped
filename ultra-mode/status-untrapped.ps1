# UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE
# UAUD uses the UARD pinned to the 000-999 audit middleman.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$Bridge=Join-Path $Root 'UARD-000-999.ps1'
Write-Host 'UAUD (Untrapped Auto-Update & Diagnostics) ver 1.0.0 - TRUE BASELINE'
Write-Host 'Using UARD pinned to the 000-999 audit middleman.'
if(-not(Test-Path -LiteralPath $Bridge)){throw "UARD-000-999 bridge not found: $Bridge"}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Bridge
exit $LASTEXITCODE
