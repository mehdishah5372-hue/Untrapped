# Untrapped Ultra Mode — continuous static destination firewall backstop
# Resolves all configured blocked domains to IPv4 + IPv6 and blocks outbound
# HTTPS (TCP/443) and QUIC (UDP/443). Refreshes frequently for CDN/IP churn.
# This is a backstop to the FQDN rules in ultra-mode.ps1.
# Run from an elevated PowerShell window or through the SYSTEM scheduled task.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$rulePrefix = 'Untrapped Ultra Mode Static - '
$refreshSeconds = 60

function Get-BlockedIPs {
  $set = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($domain in @($config.domains | Where-Object { $_ -and $_ -notmatch '^\*\.' })) {
    foreach ($type in @('A','AAAA')) {
      try {
        Resolve-DnsName -Name $domain -Type $type -DNSOnly -ErrorAction Stop |
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
  if ($ips.Count -eq 0) { throw 'Could not resolve any configured blocked destinations.' }

  $i = 0
  foreach ($ip in $ips) {
    $i++
    New-NetFirewallRule -DisplayName ($rulePrefix + $i + ' TCP') `
      -Direction Outbound -Action Block -Profile Any -Protocol TCP `
      -RemoteAddress $ip -RemotePort 443 | Out-Null
    New-NetFirewallRule -DisplayName ($rulePrefix + $i + ' UDP') `
      -Direction Outbound -Action Block -Profile Any -Protocol UDP `
      -RemoteAddress $ip -RemotePort 443 | Out-Null
  }
  Write-Host "Static backstop refreshed: $($ips.Count) destination IPs; TCP/443 + UDP/443 blocked."
}

while ($true) {
  try {
    if ([bool]$config.enabled) { Install-UltraRules }
    else { Remove-UltraRules }
  } catch {
    Write-Warning "Static backstop refresh failed: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds $refreshSeconds
}
