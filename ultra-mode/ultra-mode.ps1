# Untrapped Ultra Mode — layered Windows enforcement
# Requires an elevated PowerShell session.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath=Join-Path $Root 'config.json'
$HostsPath="$env:SystemRoot\System32\drivers\etc\hosts"
$PolicyPath='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$StartMarker='# >>> UNTRAPPED ULTRA MODE >>>'
$EndMarker='# <<< UNTRAPPED ULTRA MODE <<<'
$FqdnPrefix='Untrapped Ultra Mode FQDN - '
$IpPrefix='Untrapped Ultra Mode IP - '

function Get-Config { if(-not(Test-Path $ConfigPath)){throw 'Missing config.json'};Get-Content $ConfigPath -Raw|ConvertFrom-Json }
function Get-Domains($c){@($c.domains|Where-Object{$_ -and $_ -notmatch '[\s#]'}|ForEach-Object{$_.ToString().ToLowerInvariant().TrimEnd('.')})}
function Remove-HostBlock($lines){$out=[Collections.Generic.List[string]]::new();$inside=$false;foreach($line in $lines){if($line.Trim() -eq $StartMarker){$inside=$true;continue};if($line.Trim() -eq $EndMarker){$inside=$false;continue};if(-not $inside){[void]$out.Add($line)}};$out.ToArray()}
function Apply-Hosts($domains){$lines=if(Test-Path $HostsPath){Get-Content $HostsPath}else{@()};$clean=Remove-HostBlock $lines;$block=[Collections.Generic.List[string]]::new();[void]$block.Add($StartMarker);[void]$block.Add('# Managed by Untrapped Ultra Mode.');foreach($d in $domains|Where-Object{$_ -notmatch '^\*\.'}){[void]$block.Add("0.0.0.0`t$d");[void]$block.Add("::1`t$d")};[void]$block.Add($EndMarker);Set-Content $HostsPath -Value @($clean+''+$block.ToArray()) -Encoding ascii;ipconfig /flushdns|Out-Null}
function Remove-Hosts{if(Test-Path $HostsPath){Set-Content $HostsPath -Value (Remove-HostBlock (Get-Content $HostsPath)) -Encoding ascii;ipconfig /flushdns|Out-Null}}
function Set-BravePolicy($domains){New-Item $PolicyPath -Force|Out-Null;$k=Join-Path $PolicyPath 'URLBlocklist';New-Item $k -Force|Out-Null;$i=1;foreach($d in $domains){$base=if($d.StartsWith('*.')){$d.Substring(2)}else{$d};New-ItemProperty $k -Name ([string]$i) -PropertyType String -Value "[*.]$base" -Force|Out-Null;$i++};New-ItemProperty $PolicyPath -Name DnsOverHttpsMode -PropertyType String -Value 'off' -Force|Out-Null;New-ItemProperty $PolicyPath -Name QuicAllowed -PropertyType DWord -Value 0 -Force|Out-Null}
function Remove-BravePolicy{$k=Join-Path $PolicyPath 'URLBlocklist';if(Test-Path $k){Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue};if(Test-Path $PolicyPath){Remove-ItemProperty $PolicyPath -Name DnsOverHttpsMode -ErrorAction SilentlyContinue;Remove-ItemProperty $PolicyPath -Name QuicAllowed -ErrorAction SilentlyContinue}}
function Remove-FqdnRules($domains){Get-NetFirewallRule -DisplayName "$FqdnPrefix*" -ErrorAction SilentlyContinue|Remove-NetFirewallRule -ErrorAction SilentlyContinue;Get-NetFirewallDynamicKeywordAddress -AllAutoResolve -ErrorAction SilentlyContinue|Where-Object{$_.Keyword -in $domains}|ForEach-Object{Remove-NetFirewallDynamicKeywordAddress -Id $_.Id -ErrorAction SilentlyContinue}}
function Set-FqdnRules($domains){if(-not(Get-Command New-NetFirewallDynamicKeywordAddress -ErrorAction SilentlyContinue)){Write-Warning 'Dynamic FQDN firewall support unavailable; static IP layer remains active.';return};Remove-FqdnRules $domains;foreach($d in $domains){$id='{'+(New-Guid).Guid+'}';New-NetFirewallDynamicKeywordAddress -Id $id -Keyword $d -AutoResolve $true|Out-Null;New-NetFirewallRule -DisplayName ($FqdnPrefix+$d) -Direction Outbound -Action Block -Profile Any -Protocol Any -RemoteDynamicKeywordAddresses $id|Out-Null};foreach($d in $domains|Where-Object{$_ -notmatch '^\*\.'}){try{$ips=@(Resolve-DnsName -Name $d -Type A,AAAA -DnsOnly -ErrorAction Stop|Where-Object{$_.IPAddress}|Select-Object -ExpandProperty IPAddress -Unique);$kw=Get-NetFirewallDynamicKeywordAddress -AllAutoResolve|Where-Object{$_.Keyword -eq $d};if($kw -and $ips.Count){Update-NetFirewallDynamicKeywordAddress -Id $kw.Id -Addresses ($ips -join ',') -Append $false|Out-Null}}catch{}}}
function Get-ResolvedIPs($domains){$set=[System.Collections.Generic.HashSet[string]]::new();foreach($d in $domains|Where-Object{$_ -notmatch '^\*\.'}){foreach($type in @('A','AAAA')){try{Resolve-DnsName -Name $d -Type $type -DnsOnly -ErrorAction Stop|ForEach-Object{if($_.IPAddress){[void]$set.Add($_.IPAddress)}}}catch{}}};@($set)}
function Remove-IpRules{Get-NetFirewallRule -DisplayName "$IpPrefix*" -ErrorAction SilentlyContinue|Remove-NetFirewallRule -ErrorAction SilentlyContinue}
function Set-IpRules($domains){Remove-IpRules;$ips=Get-ResolvedIPs $domains;if($ips.Count -eq 0){throw 'Could not resolve configured blocked destinations.'};$i=0;foreach($ip in $ips){$i++;New-NetFirewallRule -DisplayName ($IpPrefix+$i) -Direction Outbound -Action Block -Profile Any -Protocol Any -RemoteAddress $ip -Description "Untrapped Ultra Mode destination block: $ip"|Out-Null};Write-Host "Static destination fallback: $($ips.Count) IPs."}

$config=Get-Config;$domains=Get-Domains $config
if(-not [bool]$config.enabled){Remove-FqdnRules $domains;Remove-IpRules;Remove-Hosts;Remove-BravePolicy;Write-Host 'Ultra Mode INACTIVE.';exit 0}
# Continuous mode: start/end are intentionally ignored when enabled is true.
Apply-Hosts $domains
Set-BravePolicy $domains
Set-FqdnRules $domains
Set-IpRules $domains
Write-Host "Ultra Mode ACTIVE: hosts + Brave policy + FQDN firewall + static IPv4/IPv6 fallback."
