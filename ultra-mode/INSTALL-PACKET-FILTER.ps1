# Install the WinDivert packet-filter dependency for Ultra Mode.
# Run this script as Administrator.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$zip=Join-Path $root 'WinDivert-2.2.2-A.zip'
$url='https://github.com/basil00/WinDivert/releases/download/v2.2.2/WinDivert-2.2.2-A.zip'
if(-not (Test-Path $zip)){Invoke-WebRequest -Uri $url -OutFile $zip}
$tmp=Join-Path $env:TEMP ('Untrapped-WinDivert-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$dll=Get-ChildItem $tmp -Recurse -Filter 'WinDivert.dll' | Where-Object {$_.FullName -match '\\x64\\'} | Select-Object -First 1
$sys=Get-ChildItem $tmp -Recurse -Filter 'WinDivert64.sys' | Select-Object -First 1
if(-not $dll -or -not $sys){throw 'Could not locate the x64 WinDivert binaries in the downloaded package.'}
Copy-Item $dll.FullName (Join-Path $root 'WinDivert.dll') -Force
Copy-Item $sys.FullName (Join-Path $root 'WinDivert64.sys') -Force
Remove-Item $tmp -Recurse -Force
Write-Host 'WinDivert x64 installed into ultra-mode.'
Write-Host 'Next run packet-filter.ps1 as Administrator.'
