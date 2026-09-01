# Untrapped Ultra Mode — Windows local enforcement
# Uses the local OS clock and Windows Firewall destination-IP rules.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$RuleName = 'Untrapped Ultra Mode - Destinations'
$StartMarker = '# >>> UNTRAPPED ULTRA MODE >>>'
$EndMarker = '# <<< UNTRAPPED ULTRA MODE <<<'
function Get-Config { if (-not (Test-Path $ConfigPath)) { throw 'Missing config.json' }; Get-Content $ConfigPath -Raw | ConvertFrom-Json }
function In-Window([datetime]$Now,[string]$Start,[string]$End) { $s=[TimeSpan]::Parse($Start);$e=[TimeSpan]::Parse($End);$t=$Now.TimeOfDay; if($s -eq $e){return $true}; if($s -lt $e){return $t -ge $s -and $t -lt $e}; return $t -ge $s -or $t -lt $e }
function Get-Domains($Config) { @($Config.domains | Where-Object {$_ -and $_ -notmatch '[\s#]'} | ForEach-Object {$_.ToString().ToLowerInvariant().TrimEnd('.')}) }
function Remove-HostBlock([string[]]$Lines) { $out=New-Object System.Collections.Generic.List[string];$inside=$false; foreach($line in $Lines){if($line.Trim() -eq $StartMarker){$inside=$true;continue};if($line.Trim() -eq $EndMarker){$inside=$false;continue};if(-not $inside){[void]$out.Add($line)}}; $out.ToArray() }
function Apply-Hosts($domains) { $lines=if(Test-Path $HostsPath){Get-Content $HostsPath}else{@()};$clean=Remove-HostBlock $lines;$block=New-Object System.Collections.Generic.List[string];[void]$block.Add($StartMarker);[void]$block.Add('# Managed by Untrapped Ultra Mode; do not edit this section manually.');foreach($d in $domains){[void]$block.Add("0.0.0.0`t$d");[void]$block.Add("::1`t$d")};[void]$block.Add($EndMarker);Set-Content $HostsPath -Value @($clean + '' + $block.ToArray()) -Encoding ascii;ipconfig /flushdns | Out-Null }
function Remove-Hosts { if(Test-Path $HostsPath){Set-Content $HostsPath -Value (Remove-HostBlock (Get-Content $HostsPath)) -Encoding ascii;ipconfig /flushdns | Out-Null} }
function Remove-Firewall { Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
function Resolve-BlockedIPs($domains) { $ips=New-Object System.Collections.Generic.HashSet[string];foreach($d in $domains){foreach($type in @('A','AAAA')){try{foreach($a in (Resolve-DnsName -Name $d -Type $type -ErrorAction Stop)){if($a.IPAddress){[void]$ips.Add($a.IPAddress)}}}catch{Write-Warning "Could not resolve $type for $d"}}};@($ips) }
function Apply-Firewall($domains) { Remove-Firewall;$ips=Resolve-BlockedIPs $domains;if($ips.Count -eq 0){Write-Warning 'No destination IPs resolved; firewall rule not installed.';return};try{New-NetFirewallRule -DisplayName $RuleName -Direction Outbound -Action Block -Profile Any -RemoteAddress $ips -ErrorAction Stop | Out-Null;Write-Host "Ultra Mode firewall destination IPs blocked: $($ips.Count)"}catch{Write-Warning "Could not create firewall IP rule: $($_.Exception.Message)"} }
$config=Get-Config;$domains=Get-Domains $config;$active=$config.enabled -and (In-Window (Get-Date) $config.start $config.end);if($active){Apply-Hosts $domains;Apply-Firewall $domains}else{Remove-Hosts;Remove-Firewall};Write-Host "Ultra Mode active: $active; schedule $($config.start)-$($config.end)"
