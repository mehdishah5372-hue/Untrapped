# Untrapped Ultra Mode — Windows local enforcement
# Enforces configured domain blocks while the local OS clock is inside the configured window.
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
  foreach($line in $Lines){if($line.Trim() -eq $StartMarker){$inside=$true;continue};if($line.Trim() -eq $EndMarker){$inside=$false;continue};if(-not $inside){[void]$out.Add($line)}}
  $out.ToArray()
}
function Apply-Hosts($domains) {
  $lines=if(Test-Path $HostsPath){Get-Content $HostsPath}else{@()};$clean=Remove-HostBlock $lines
  $block=New-Object System.Collections.Generic.List[string];[void]$block.Add($StartMarker);[void]$block.Add('# Managed by Untrapped Ultra Mode; do not edit this section manually.')
  foreach($d in $domains){[void]$block.Add("0.0.0.0`t$d")}
  [void]$block.Add($EndMarker);Set-Content $HostsPath -Value @($clean + '' + $block.ToArray()) -Encoding ascii
  ipconfig /flushdns | Out-Null
}
function Remove-Hosts { if(Test-Path $HostsPath){Set-Content $HostsPath -Value (Remove-HostBlock (Get-Content $HostsPath)) -Encoding ascii;ipconfig /flushdns | Out-Null} }
function Apply-Firewall($domains) {
  $created=0
  if(-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)){Write-Warning 'Windows Firewall cmdlets are unavailable.';return}
  foreach($d in $domains){
    $name=$RulePrefix+$d
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    try {
      $r=New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block -Profile Any -RemoteFqdn $d -ErrorAction Stop
      if($r){$created++}
    } catch { Write-Warning ("Could not create FQDN firewall rule for {0}: {1}" -f $d,$_.Exception.Message) }
  }
  Write-Host ("Ultra Mode firewall rules created: {0}/{1}" -f $created,$domains.Count)
}
function Remove-Firewall($domains) { foreach($d in $domains){Get-NetFirewallRule -DisplayName ($RulePrefix+$d) -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue} }
$config=Get-Config;$domains=Get-Domains $config;$active=$config.enabled -and (In-Window (Get-Date) $config.start $config.end)
if($active){Apply-Hosts $domains;Apply-Firewall $domains}else{Remove-Hosts;Remove-Firewall $domains}
Write-Host ("Ultra Mode active: {0}; schedule {1}-{2}; domains: {3}" -f $active,$config.start,$config.end,($domains -join ', '))
