# Untrapped Ultra Mode — Windows Firewall destination blocker
# Uses RemoteAddress rules rather than WinDivert. This avoids the previous
# FQDN/packet-inspection problem while leaving Brave itself untouched.
# Run from an elevated PowerShell window.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$rulePrefix = 'Untrapped Ultra Mode - YouTube IP - '
$domains = @(
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
  'youtube-nocookie.com',
  'youtubei.googleapis.com',
  'youtube.googleapis.com',
  'googlevideo.com'
)

function Test-UltraActive {
  $start = [TimeSpan]::Parse($config.start)
  $end   = [TimeSpan]::Parse($config.end)
  $now   = (Get-Date).TimeOfDay
  if ($start -eq $end) { return $true }
  if ($start -lt $end) { return ($now -ge $start -and $now -lt $end) }
  return ($now -ge $start -or $now -lt $end)
}

function Get-BlockedIPs {
  $set = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($domain in $domains) {
    foreach ($type in @('A','AAAA')) {
      try {
        Resolve-DnsName -Name $domain -Type $type -ErrorAction Stop |
          ForEach-Object { if ($_.IPAddress) { [void]$set.Add($_.IPAddress) } }
      } catch { }
    }
  }
  return @($set)
}

function Remove-UltraRules {
  Get-NetFirewallRule -DisplayName "$rulePrefix*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

function Install-UltraRules {
  Remove-UltraRules
  $ips = Get-BlockedIPs
  if ($ips.Count -eq 0) { throw 'Could not resolve any configured YouTube destinations.' }

  $i = 0
  foreach ($ip in $ips) {
    $i++
    New-NetFirewallRule `
      -DisplayName ($rulePrefix + $i) `
      -Direction Outbound `
      -Action Block `
      -Profile Any `
      -Protocol Any `
      -RemoteAddress $ip `
      -Description "Untrapped Ultra Mode: block YouTube destination $ip" |
      Out-Null
  }
  Write-Host "Ultra Mode Windows Firewall block ACTIVE: $($ips.Count) destination IPs."
}

$active = $false
try {
  Write-Host "Untrapped Ultra Mode firewall service. Schedule $($config.start)-$($config.end)."
  while ($true) {
    $shouldBeActive = [bool]($config.enabled) -and (Test-UltraActive)

    if ($shouldBeActive -and -not $active) {
      Install-UltraRules
      $active = $true
    }
    elseif (-not $shouldBeActive -and $active) {
      Remove-UltraRules
      $active = $false
      Write-Host 'Ultra Mode Windows Firewall block INACTIVE.'
    }
    elseif ($shouldBeActive -and $active) {
      # Refresh periodically because Google/CDN destination addresses change.
      Install-UltraRules
    }

    Start-Sleep -Seconds 30
  }
}
finally {
  if (-not (Test-UltraActive)) { Remove-UltraRules }
}
