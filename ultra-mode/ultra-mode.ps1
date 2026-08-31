# Untrapped Ultra Mode — Windows local enforcement
# Run this script as Administrator. It reads ultra-mode/config.json and uses
# the Windows hosts file to block configured domains during the scheduled window.
# It is intentionally removable/reconfigurable by the computer owner.

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$StartMarker = '# >>> UNTRAPPED ULTRA MODE >>>'
$EndMarker = '# <<< UNTRAPPED ULTRA MODE <<<'

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Missing config.json" }
    return Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function In-Window([datetime]$Now, [string]$Start, [string]$End) {
    $s = [TimeSpan]::Parse($Start)
    $e = [TimeSpan]::Parse($End)
    $t = $Now.TimeOfDay
    if ($s -eq $e) { return $true }
    if ($s -lt $e) { return $t -ge $s -and $t -lt $e }
    return $t -ge $s -or $t -lt $e
}

function Read-Hosts {
    if (Test-Path $HostsPath) { return Get-Content $HostsPath } else { return @() }
}

function Remove-UltraBlock([string[]]$Lines) {
    $out = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -eq $StartMarker) { $inside = $true; continue }
        if ($line -eq $EndMarker) { $inside = $false; continue }
        if (-not $inside) { [void]$out.Add($line) }
    }
    return $out.ToArray()
}

function Apply-UltraBlock($Config) {
    $lines = Remove-UltraBlock (Read-Hosts)
    $block = New-Object System.Collections.Generic.List[string]
    [void]$block.Add($StartMarker)
    [void]$block.Add('# Managed by Untrapped Ultra Mode; do not edit this section manually.')
    foreach ($domain in $Config.domains) {
        if ($domain -and $domain -notmatch '[\s#]') {
            [void]$block.Add("0.0.0.0 $domain")
            [void]$block.Add(":: $domain")
        }
    }
    [void]$block.Add($EndMarker)
    $newLines = @($lines + '' + $block.ToArray())
    Set-Content -Path $HostsPath -Value $newLines -Encoding ascii
    ipconfig /flushdns | Out-Null
}

$config = Get-Config
$active = $config.enabled -and (In-Window (Get-Date) $config.start $config.end)
$current = Read-Hosts
$hasBlock = [bool]($current | Where-Object { $_ -eq $StartMarker })

if ($active -and -not $hasBlock) {
    Apply-UltraBlock $config
} elseif (-not $active -and $hasBlock) {
    Set-Content -Path $HostsPath -Value (Remove-UltraBlock $current) -Encoding ascii
    ipconfig /flushdns | Out-Null
}
