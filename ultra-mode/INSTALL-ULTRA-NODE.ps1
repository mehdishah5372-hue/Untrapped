# Untrapped Ultra Node installer — 3.2.0 baseline.
# Run as Administrator from the ultra-mode directory.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$Runner=Join-Path $Root 'ultra-mode.ps1'
if(-not(Test-Path -LiteralPath $Runner)){throw "Missing $Runner"}
Write-Host 'Untrapped Ultra Node 3.2.0 baseline ready.'
Write-Host 'Use INSTALL-ULTRA-MODE.ps1 to install the scheduled packet-filter runner.'
