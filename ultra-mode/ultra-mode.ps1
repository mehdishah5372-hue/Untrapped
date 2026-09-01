# Untrapped Ultra Mode — local domain enforcement
# Uses the Windows hosts file plus Brave managed policy. Brave itself remains usable.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath=Join-Path $Root 'config.json'
$HostsPath="$env:SystemRoot\System32\drivers\etc\hosts"
$PolicyPath='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$StartMarker='# >>> UNTRAPPED ULTRA MODE >>>'
$EndMarker='# <<< UNTRAPPED ULTRA MODE <<<'
function Get-Config { Get-Content $ConfigPath -Raw | ConvertFrom-Json }
function In-Window([datetime]$Now,[string]$Start,[string]$End){$s=[TimeSpan]::Parse($Start);$e=[TimeSpan]::Parse($End);$t=$Now.TimeOfDay;if($s -eq $e){return $true};if($s -lt $e){return $t -ge $s -and $t -lt $e};return $t -ge $s -or $t -lt $e}
function Get-Domains($c){@($c.domains|Where-Object{$_ -and $_ -notmatch '[\s#]'}|%{$_.ToString().ToLowerInvariant().TrimEnd('.')})}
function Remove-HostBlock($lines){$out=[Collections.Generic.List[string]]::new();$inside=$false;foreach($line in $lines){if($line.Trim() -eq $StartMarker){$inside=$true;continue};if($line.Trim() -eq $EndMarker){$inside=$false;continue};if(-not $inside){[void]$out.Add($line)}};return $out.ToArray()}
function Apply-Hosts($domains){$lines=if(Test-Path $HostsPath){Get-Content $HostsPath}else{@()};$clean=Remove-HostBlock $lines;$block=[Collections.Generic.List[string]]::new();[void]$block.Add($StartMarker);[void]$block.Add('# Managed by Untrapped Ultra Mode; do not edit manually.');foreach($d in $domains){[void]$block.Add("0.0.0.0`t$d");[void]$block.Add("::1`t$d")};[void]$block.Add($EndMarker);Set-Content $HostsPath -Value @($clean+''+$block.ToArray()) -Encoding ascii;ipconfig /flushdns|Out-Null}
function Remove-Hosts{if(Test-Path $HostsPath){Set-Content $HostsPath -Value (Remove-HostBlock (Get-Content $HostsPath)) -Encoding ascii;ipconfig /flushdns|Out-Null}}
function Set-BravePolicy($domains){New-Item $PolicyPath -Force|Out-Null;$urls=[Collections.Generic.List[string]]::new();foreach($d in $domains){[void]$urls.Add("*$d/*");[void]$urls.Add("*://$d/*")};New-ItemProperty $PolicyPath -Name URLBlocklist -PropertyType String -Value ($urls|ConvertTo-Json -Compress) -Force|Out-Null;# Prevent Brave from bypassing the hosts layer with DNS-over-HTTPS.
New-ItemProperty $PolicyPath -Name DnsOverHttpsMode -PropertyType String -Value 'off' -Force|Out-Null}
function Remove-BravePolicy{if(Test-Path $PolicyPath){Remove-ItemProperty $PolicyPath -Name URLBlocklist -ErrorAction SilentlyContinue;Remove-ItemProperty $PolicyPath -Name DnsOverHttpsMode -ErrorAction SilentlyContinue}}
$config=Get-Config;$domains=Get-Domains $config;$active=$config.enabled -and (In-Window (Get-Date) $config.start $config.end)
if($active){Apply-Hosts $domains;Set-BravePolicy $domains}else{Remove-Hosts;Remove-BravePolicy}
Write-Host "Ultra Mode active: $active; schedule $($config.start)-$($config.end); domains: $($domains -join ', ')"
