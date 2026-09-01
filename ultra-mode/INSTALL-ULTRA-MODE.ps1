# Untrapped Ultra Mode installer for Windows.
# Run PowerShell as Administrator from the repository's ultra-mode directory.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Runner = Join-Path $Root 'ultra-mode.ps1'
$PacketRunner = Join-Path $Root 'packet-filter.ps1'
$TaskName = 'Untrapped Ultra Mode'
$PacketTaskName = 'Untrapped Ultra Mode - Packet Filter'
$KeySource = Join-Path $env:USERPROFILE 'Untrapped-Ultra-Key\ultra-public.json'
$KeyDir = Join-Path $env:ProgramData 'Untrapped-Ultra'
$KeyDest = Join-Path $KeyDir 'ultra-public.json'
$WinDivertDll = Join-Path $Root 'WinDivert.dll'
$WinDivertSys = Join-Path $Root 'WinDivert64.sys'
$WinDivertZip = Join-Path $Root 'WinDivert-2.2.2-A.zip'
$WinDivertUrl = 'https://github.com/basil00/WinDivert/releases/download/v2.2.2/WinDivert-2.2.2-A.zip'

if (-not (Test-Path $KeySource)) { throw "Public key not found at $KeySource. Generate/copy your public key there first." }
if (-not (Test-Path $Runner)) { throw "Missing $Runner" }
if (-not (Test-Path $PacketRunner)) { throw "Missing $PacketRunner" }

# Install the x64 WinDivert runtime automatically so Ultra Mode does not depend
# on a separate manual packet-filter installation step.
if (-not (Test-Path $WinDivertDll) -or -not (Test-Path $WinDivertSys)) {
    if (-not (Test-Path $WinDivertZip)) {
        Invoke-WebRequest -Uri $WinDivertUrl -OutFile $WinDivertZip
    }
    $tmp = Join-Path $env:TEMP ('Untrapped-WinDivert-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Expand-Archive -Path $WinDivertZip -DestinationPath $tmp -Force
        $dll = Get-ChildItem $tmp -Recurse -Filter 'WinDivert.dll' |
            Where-Object { $_.FullName -match '\\x64\\' } |
            Select-Object -First 1
        $sys = Get-ChildItem $tmp -Recurse -Filter 'WinDivert64.sys' |
            Select-Object -First 1
        if (-not $dll -or -not $sys) { throw 'Could not locate x64 WinDivert binaries.' }
        Copy-Item $dll.FullName $WinDivertDll -Force
        Copy-Item $sys.FullName $WinDivertSys -Force
    }
    finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null
Copy-Item $KeySource $KeyDest -Force

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Runner`""
$packetAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PacketRunner`""
$logon = New-ScheduledTaskTrigger -AtLogOn
$startup = New-ScheduledTaskTrigger -AtStartup
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $startup, $repeat) -Principal $principal -Force | Out-Null
Register-ScheduledTask -TaskName $PacketTaskName -Action $packetAction -Trigger @($logon, $startup, $repeat) -Principal $principal -Force | Out-Null

# Start both immediately instead of waiting for the next trigger.
Start-ScheduledTask -TaskName $TaskName
Start-ScheduledTask -TaskName $PacketTaskName

Write-Host "Installed: $TaskName"
Write-Host "Installed: $PacketTaskName"
Write-Host "WinDivert runtime installed in: $Root"
Write-Host "Public verification key installed at: $KeyDest"
Write-Host "Schedule is controlled by ultra-mode/config.json"
Write-Host "Continuous mode is enabled when config.enabled is true."
