# Untrapped Ultra Mode — Windows local enforcement
# Keeps Brave usable normally, while applying URL blocking through Brave's managed policy during Ultra Mode.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$PolicyPath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$StartMarker = '# >>> UNTRAPPED ULTRA MODE >>>'
$EndMarker = '# <<< UNTRAPPED ULTRA MODE <<<'
function Get-Config { if (-not (Test-Path $ConfigPath)) { throw 'Missing config.json' }; Get-Content $ConfigPath -Raw | ConvertFrom-Json }
function In-Window([datetime]$Now,[string]$Start,[string]$End) { $s=[TimeSpan]::Parse($Start);$e=[TimeSpan]::Parse($End);$t=$Now.TimeOfDay;if($s -eq $e){return $true};if($s -lt $e){return $t -ge $s -and $t -lt $e};return $t -ge $s -or $t -lt $e }
function Get-Domains($Config) { @($Config.domains | Where-Object {$_ -and $_ -notmatch '[\s#]'} | ForEach-Object {$_.ToString().ToLowerInvariant().TrimEnd('.')}) }
function Remove-HostBlock([string[]]$Lines) { $out=New-Object System.Collections.Generic.List[string];$inside=$false;foreach($line in $Lines){if($line.Trim() -eq $StartMarker){$inside=$true;continue};if($line.Trim() -eq $EndMarker){$inside=$false;continue};if(-not $inside){[void]$out.Add($line)}};$out.ToArray() }
function Apply-Hosts($domains) { $lines=if(Test-Path $HostsPath){Get-Content $HostsPath}else{@()};$clean=Remove-HostBlock $lines;$block=New-Object System.Collections.Generic.List[string];[void]$block.Add($StartMarker);[void]$block.Add('# Managed by Untrapped Ultra Mode; do not edit this section manually.');foreach($d in $domains){[void]$block.Add("0.0.0.0`t$d");[void]$block.Add("::1`t$d")};[void]$block.Add($EndMarker);Set-Content $HostsPath -Value @($clean + '' + $block.ToArray()) -Encoding ascii;ipconfig /flushdns | Out-Null }
function Remove-Hosts { if(Test-Path $HostsPath){Set-Content $HostsPath -Value (Remove-HostBlock (Get-Content $HostsPath)) -Encoding ascii;ipconfig /flushdns | Out-Null} }
function Set-BravePolicy($domains) { New-Item -Path $PolicyPath -Force | Out-Null;$urls=New-Object System.Collections.Generic.List[string];foreach($d in $domains){[void]$urls.Add("*$d/*");[void]$urls.Add("*://$d/*")};$json=$urls | ConvertTo-Json -Compress;New-ItemProperty -Path $PolicyPath -Name 'URLBlocklist' -PropertyType String -Value $json -Force | Out-Null;Write-Host "Ultra Mode Brave URL policy installed for $($domains.Count) domains." }
function Remove-BravePolicy { if(Test-Path $PolicyPath){Remove-ItemProperty -Path $PolicyPath -Name 'URLBlocklist' -ErrorAction SilentlyContinue} }
$config=Get-Config;$domains=Get-Domains $config;$active=$config.enabled -and (In-Window (Get-Date) $config.start $config.end)
if($active){Apply-Hosts $domains;Set-BravePolicy $domains}else{Remove-Hosts;Remove-BravePolicy}
Write-Host "Ultra Mode active: $active; schedule $($config.start)-$($config.end); Brave remains usable for non-blocked sites."
