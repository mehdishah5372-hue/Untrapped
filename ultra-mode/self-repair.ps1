# Untrapped Ultra Mode - bounded self-repair engine
# Repairs the Untrapped installation itself from the official repository when files are
# missing, malformed, or fail PowerShell syntax validation. It never changes the
# override, Hosts, Windows Firewall, WFP, Winsock, DNS, routes, adapters, or VPN.
# It uses the GitHub main branch as the canonical source of truth for Untrapped code.

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoBase = 'https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/ultra-mode/'
$BackupRoot = Join-Path $Root 'repair-backups'
$Targets = @(
    @{ Name='packet-filter.ps1'; Url=$RepoBase+'packet-filter.ps1'; Type='script'; Required=$true },
    @{ Name='ultra-mode.ps1'; Url=$RepoBase+'ultra-mode.ps1'; Type='script'; Required=$true },
    @{ Name='status-untrapped.ps1'; Url=$RepoBase+'status-untrapped.ps1'; Type='script'; Required=$true },
    @{ Name='config.json'; Url=$RepoBase+'config.json'; Type='json'; Required=$true }
)

function Say([string]$s) { Write-Host $s }
function Is-ValidScript([string]$text) {
    try { [void][scriptblock]::Create($text); return $true } catch { return $false }
}
function Is-ValidJson([string]$text) {
    try { $null = $text | ConvertFrom-Json; return $true } catch { return $false }
}
function Is-ValidTarget([hashtable]$target, [string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($target.Type -eq 'script') { return Is-ValidScript $text }
    if ($target.Type -eq 'json') { return Is-ValidJson $text }
    return $true
}

try {
    if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $changed = $false
    $failed = $false

    foreach ($target in $Targets) {
        $path = Join-Path $Root $target.Name
        $needsRepair = $false
        $reason = ''
        if (-not (Test-Path $path)) {
            $needsRepair = $true; $reason = 'missing'
        } else {
            try {
                $current = [IO.File]::ReadAllText($path)
                if (-not (Is-ValidTarget $target $current)) { $needsRepair = $true; $reason = 'invalid syntax/content' }
            } catch { $needsRepair = $true; $reason = 'unreadable' }
        }

        if (-not $needsRepair) {
            Say ('[OK SELF-REPAIR] ' + $target.Name + ' is present and syntactically valid.')
            continue
        }

        Say ('[REPAIR NEEDED] ' + $target.Name + ' is ' + $reason + '; fetching canonical copy from GitHub.')
        $temp = Join-Path $env:TEMP ('untrapped-repair-' + [guid]::NewGuid().ToString('N') + '-' + $target.Name)
        try {
            Invoke-WebRequest -Uri $target.Url -OutFile $temp -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $remote = [IO.File]::ReadAllText($temp)
            if ($remote.Length -lt 20 -or -not (Is-ValidTarget $target $remote)) { throw 'Downloaded canonical copy failed validation.' }

            if (Test-Path $path) {
                $backup = Join-Path $BackupRoot ($timestamp + '-' + $target.Name)
                Copy-Item -LiteralPath $path -Destination $backup -Force
                Say ('[OK BACKUP] Saved old ' + $target.Name + ' to ' + $backup)
            }
            Copy-Item -LiteralPath $temp -Destination $path -Force
            Say ('[OK REPAIRED] Restored ' + $target.Name + ' from the validated canonical GitHub copy.')
            $changed = $true
        } catch {
            Say ('[FAIL REPAIR] Could not repair ' + $target.Name + ': ' + $_.Exception.Message)
            $failed = $true
        } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }

    # Validate required native WinDivert files. These are never modified by this engine.
    foreach ($native in @('WinDivert.dll','WinDivert64.sys')) {
        if (Test-Path (Join-Path $Root $native)) { Say ('[OK SELF-REPAIR] ' + $native + ' present.') }
        else { Say ('[FAIL SELF-REPAIR] ' + $native + ' missing; native binaries require manual restoration from the trusted package.'); $failed = $true }
    }

    if ($changed) {
        Say '[REPAIR] Restarting Untrapped control processes so repaired code/config is loaded.'
        foreach ($pattern in @('*packet-filter.ps1*','*ultra-mode.ps1*')) {
            @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like $pattern }) | ForEach-Object {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        Start-Sleep -Milliseconds 700
        $packet = Join-Path $Root 'packet-filter.ps1'
        $control = Join-Path $Root 'ultra-mode.ps1'
        if (Test-Path $packet) { Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$packet) -WorkingDirectory $Root -Verb RunAs -WindowStyle Hidden -ErrorAction SilentlyContinue }
        if (Test-Path $control) { Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$control) -WorkingDirectory $Root -Verb RunAs -WindowStyle Hidden -ErrorAction SilentlyContinue }
    }

    if ($failed) { Say '[FAIL SELF-REPAIR] One or more repairs could not be completed.'; exit 1 }
    if ($changed) { Say '[HEALTHY] Self-repair completed; Untrapped processes were restarted.' }
    else { Say '[HEALTHY] No code/config repair was required.' }
    exit 0
} catch {
    Say ('[FAIL SELF-REPAIR] Fatal repair-engine error: ' + $_.Exception.Message)
    exit 1
}
