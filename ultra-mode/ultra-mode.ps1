# Untrapped Ultra Mode — Windows local enforcement
# Runs as SYSTEM and enforces configured domain blocks independently of the browser extension.
# Uses the Windows Defender Firewall FQDN rules so browser DNS-over-HTTPS cannot simply bypass hosts.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$RulePrefix = 'Untrapped Ultra Mode - '
$StartMarker = '# >>> UNTRAPPED ULTRA MODE >>>'
$EndMarker = '# <<< UNTRAPPED ULTRA MODE <<<'

function Get-Config { if (-not (Test-Path $ConfigPath)) { throw 'Missing config.json' }; Get-Content $ConfigPath -Raw | ConvertFrom-Json }
function In-Window([datetime]$Now,[string]$Start,[string]$End) {
  $s=[TimeSpan]::Parse($Start);$e=[TimeSpan]::Parse($End);$t=$Now.TimeOfDay
  if($s -eq $e){return $true};if($s -lt $e){return $t -ge $s -and $t -lt $e};return $t -ge $s -or $t -lt $e
}
function Get-Domains($Config) { @($Config.domains | Where-Object {$_ -and $_ -notmatch '[\s#]'} | ForEach-Object {$_.ToString().ToLowerInvariant().TrimEnd('.')}) }
function Remove-HostBlock([string[]]$Lines) {
  $out=New-Object System.Collections.Generic.List[string];$inside=$false
  foreach($line in $Lines){if($line -eq $StartMarker){$inside=$true;continue};if($line -eq $EndMarker){$inside=$false;continue};if(-not $inside){[void]$out.Add($line)}}
  $out.ToArray()
}
function Apply-Hosts($domains) {
  $lines=if(Test-Path $HostsPath){Get-Content $HostsPath}else{@()};$clean=Remove-HostBlock $lines
  $block=New-Object System.Collections.Generic.List[string];[void]$block.Add($StartMarker);[void]$block.Add('# Managed by Untrapped Ultra Mode; do not edit this section manually.')
  foreach($d in $domains){[void]$block.Add("0.0.0.0 $d")}
  [void]$block.Add($EndMarker);Set-Content $HostsPath -Value @($clean + '' + $block.ToArray()) -Encoding ascii
  ipconfig /flushdns | Out-Null
}
function Remove-Hosts { if(Test-Path $HostsPath){Set-Content $HostsPath -Value (Remove-HostBlock (Get-Content $HostsPath)) -Encoding ascii;ipconfig /flushdns | Out-Null} }
function Apply-Firewall($domains) {
  foreach($d in $domains){
    $name=$RulePrefix+$d
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    try {
      New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block -Profile Any -RemoteFqdn $d -ErrorAction Stop | Out-Null
    } catch {
      # Older Windows builds may not expose RemoteFqdn; hosts blocking remains active.
    }
  }
}
function Remove-Firewall($domains) { foreach($d in $domains){Get-NetFirewallRule -DisplayName ($RulePrefix+$d) -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue} }
$config=Get-Config;$domains=Get-Domains $config;$active=$config.enabled -and (In-Window (Get-Date) $config.start $config.end)
# Ultra Mode is deliberately based on the local OS clock. No override/password is consulted here yet.
if($active){Apply-Hosts $domains;Apply-Firewall $domains}else{Remove-Hosts;Remove-Firewall $domains}
