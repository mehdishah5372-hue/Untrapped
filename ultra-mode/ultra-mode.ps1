# Untrapped Ultra Mode — continuous Windows domain enforcement
# Layers: hosts, Brave managed URL/DoH/QUIC policy, Defender Network Protection,
# Windows Firewall Dynamic Keyword Addresses, and static IP firewall fallback.
# Requires an elevated PowerShell session. Intended for self-control on a machine
# whose administrator has explicitly chosen to enforce these blocks.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath=Join-Path $Root 'config.json'
$HostsPath="$env:SystemRoot\System32\drivers\etc\hosts"
$PolicyPath='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$StartMarker='# >>> UNTRAPPED ULTRA MODE >>>'
$EndMarker='# <<< UNTRAPPED ULTRA MODE <<<'
$RulePrefix='Untrapped Ultra Mode FQDN - '
$StaticPrefix='Untrapped Ultra Mode Static - '

function Get-Config { if(-not(Test-Path $ConfigPath)){throw 'Missing config.json'}; Get-Content $ConfigPath -Raw | ConvertFrom-Json }
function In-Window([datetime]$Now,[string]$Start,[string]$End){$s=[TimeSpan]::Parse($Start);$e=[TimeSpan]::Parse($End);$t=$Now.TimeOfDay;if($s -eq $e){return $true};if($s -lt $e){return $t -ge $s -and $t -lt $e};return $t -ge $s -or $t -lt $e}
function Get-Domains($c){@($c.domains|Where-Object{$_ -and $_ -notmatch '[\s#]'}|ForEach-Object{$_.ToString().ToLowerInvariant().TrimEnd('.')})}
function Remove-HostBlock($lines){$out=[Collections.Generic.List[string]]::new();$inside=$false;foreach($line in $lines){if($line.Trim() -eq $StartMarker){$inside=$true;continue};if($line.Trim() -eq $EndMarker){$inside=$false;continue};if(-not $inside){[void]$out.Add($line)}};return $out.ToArray()}
function Apply-Hosts($domains){$lines=if(Test-Path $HostsPath){Get-Content $HostsPath}else{@()};$clean=Remove-HostBlock $lines;$block=[Collections.Generic.List[string]]::new();[void]$block.Add($StartMarker);[void]$block.Add('# Managed by Untrapped Ultra Mode; do not edit manually.');foreach($d in $domains|Where-Object{$_ -notmatch '^\*\.'}){[void]$block.Add("0.0.0.0`t$d");[void]$block.Add("::1`t$d")};[void]$block.Add($EndMarker);Set-Content $HostsPath -Value @($clean+''+$block.ToArray()) -Encoding ascii;ipconfig /flushdns|Out-Null}
function Set-BravePolicy($domains){New-Item $PolicyPath -Force|Out-Null;$blockKey=Join-Path $PolicyPath 'URLBlocklist';New-Item $blockKey -Force|Out-Null;$i=1;foreach($d in $domains){$pattern=if($d.StartsWith('*.')){"[*.]"+$d.Substring(2)}else{"[*.]$d"};New-ItemProperty $blockKey -Name ([string]$i) -PropertyType String -Value $pattern -Force|Out-Null;$i++};New-ItemProperty $PolicyPath -Name DnsOverHttpsMode -PropertyType String -Value 'off' -Force|Out-Null;New-ItemProperty $PolicyPath -Name QuicAllowed -PropertyType DWord -Value 0 -Force|Out-Null}
function Set-NetworkProtection { try { if(Get-Command Set-MpPreference -ErrorAction SilentlyContinue){ Set-MpPreference -EnableNetworkProtection Enabled -ErrorAction Stop } } catch { Write-Warning "Could not enable Defender Network Protection: $($_.Exception.Message)" } }
function Remove-FqdnRules($domains){foreach($d in $domains){Get-NetFirewallRule -DisplayName ($RulePrefix+$d) -ErrorAction SilentlyContinue|Remove-NetFirewallRule -ErrorAction SilentlyContinue;Get-NetFirewallDynamicKeywordAddress -AllAutoResolve -ErrorAction SilentlyContinue|Where-Object{$_.Keyword -eq $d}|ForEach-Object{Remove-NetFirewallDynamicKeywordAddress -Id $_.Id -ErrorAction SilentlyContinue}}}
function Set-FqdnRules($domains){if(-not (Get-Command New-NetFirewallDynamicKeywordAddress -ErrorAction SilentlyContinue)){throw 'Windows Firewall Dynamic Keyword support is unavailable on this Windows installation.'};Remove-FqdnRules $domains;foreach($d in $domains){$id='{'+(New-Guid).Guid+'}';New-NetFirewallDynamicKeywordAddress -Id $id -Keyword $d -AutoResolve $true|Out-Null;New-NetFirewallRule -DisplayName ($RulePrefix+$d) -Direction Outbound -Action Block -Profile Any -Protocol Any -RemoteDynamicKeywordAddresses $id|Out-Null}
  # Hydrate exact names immediately so the first real connection is not the one
  # that populates the dynamic keyword cache.
  foreach($d in $domains|Where-Object{$_ -notmatch '^\*\.'}){try{$ips=@(Resolve-DnsName -Name $d -Type A,AAAA -DNSOnly -ErrorAction Stop|Where-Object{$_.IPAddress}|Select-Object -ExpandProperty IPAddress -Unique);if($ips.Count -gt 0){$kw=Get-NetFirewallDynamicKeywordAddress -AllAutoResolve|Where-Object{$_.Keyword -eq $d};if($kw){Update-NetFirewallDynamicKeywordAddress -Id $kw.Id -Addresses ($ips -join ',') -Append $false|Out-Null}}}catch{}}
}
function Remove-StaticRules { Get-NetFirewallRule -DisplayName "$StaticPrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
function Set-StaticRules($domains){
  Remove-StaticRules
  $ips=New-Object System.Collections.Generic.HashSet[string]
  foreach($d in $domains|Where-Object{$_ -notmatch '^\*\.'}){foreach($type in @('A','AAAA')){try{Resolve-DnsName -Name $d -Type $type -DNSOnly -ErrorAction Stop|ForEach-Object{if($_.IPAddress){[void]$ips.Add($_.IPAddress)}}}catch{}}}
  $i=0;foreach($ip in $ips){$i++;New-NetFirewallRule -DisplayName ($StaticPrefix+$i+' TCP') -Direction Outbound -Action Block -Profile Any -Protocol TCP -RemoteAddress $ip -RemotePort 443|Out-Null;New-NetFirewallRule -DisplayName ($StaticPrefix+$i+' UDP') -Direction Outbound -Action Block -Profile Any -Protocol UDP -RemoteAddress $ip -RemotePort 443|Out-Null}
}
$config=Get-Config;$domains=Get-Domains $config;$active=$config.enabled -and (In-Window (Get-Date) $config.start $config.end)
if($active){Apply-Hosts $domains;Set-BravePolicy $domains;Set-NetworkProtection;Set-FqdnRules $domains;Set-StaticRules $domains;Write-Host "Ultra Mode ACTIVE: hosts + Brave policy + Defender Network Protection + dynamic FQDN + static TCP/UDP 443 fallback."}else{Remove-FqdnRules $domains;Remove-StaticRules;Write-Host "Ultra Mode INACTIVE."}
