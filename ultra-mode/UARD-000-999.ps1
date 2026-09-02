# UARD-000-999 bridge
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$UARD=Join-Path $Root 'self-repair.ps1'
$Middleman='https://untrapped-update-middleman-000-999-production.up.railway.app'
if(-not(Test-Path -LiteralPath $UARD)){throw "UARD not found: $UARD"}
$source=[IO.File]::ReadAllText($UARD)
$source=$source.Replace('https://untrapped-update-middleman-310-production.up.railway.app',$Middleman)
$source=$source.Replace('https://untrapped-update-middleman-production.up.railway.app',$Middleman)
$tmp=Join-Path $env:TEMP ('Untrapped-UARD-000-999-'+[Guid]::NewGuid().ToString('N')+'.ps1')
try{[IO.File]::WriteAllText($tmp,$source,(New-Object Text.UTF8Encoding($false)));& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp;exit $LASTEXITCODE}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
