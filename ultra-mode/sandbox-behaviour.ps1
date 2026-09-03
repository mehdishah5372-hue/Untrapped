# Disposable Windows behavioural stage for Untrapped policy code.
# Executes only policy/helper functions extracted from packet-filter.ps1.
# Does NOT open WinDivert, alter networking, change firewall/WFP/DNS/Hosts/VPN, or install anything.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path;$scriptPath=Join-Path $Root 'packet-filter.ps1';$configPath=Join-Path $Root 'config.json'
$tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('packet-filter.ps1 syntax failed: '+(($errors|ForEach-Object{$_.Message}) -join ' | '))}
$functions=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
if($functions.Count -lt 6){throw 'Expected packet-filter policy functions were not found.'}
$functionText=($functions|ForEach-Object{$_.Extent.Text}) -join "`n`n";$ConfigPath=$configPath
. ([scriptblock]::Create($functionText))
$config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json;Test-Config $config
if(Test-UltraActive $config ([TimeSpan]::Parse('04:59'))){throw 'Schedule boundary bug: 04:59 unexpectedly active'}
if(-not(Test-UltraActive $config ([TimeSpan]::Parse('05:00')))){throw 'Schedule boundary bug: 05:00 should be active'}
if(-not(Test-UltraActive $config ([TimeSpan]::Parse('21:59')))){throw 'Schedule boundary bug: 21:59 should be active'}
if(Test-UltraActive $config ([TimeSpan]::Parse('22:00'))){throw 'Schedule boundary bug: 22:00 should be inactive'}
if(Test-UltraActive $config ([TimeSpan]::Parse('23:30'))){throw 'Schedule boundary bug: 23:30 unexpectedly active'}
$f=New-WinDivertFilter @('1.2.3.4','2001:db8::1')
if($f -notmatch 'ip\.DstAddr == 1\.2\.3\.4'){throw 'IPv4 filter clause missing'}
if($f -notmatch 'ipv6\.DstAddr == 2001:db8::1'){throw 'IPv6 filter clause missing'}
if($f -notmatch 'tcp\.DstPort == 443' -or $f -notmatch 'udp\.DstPort == 443'){throw 'TLS/QUIC destination ports missing'}
if($null -ne (New-WinDivertFilter @())){throw 'Empty IP set must not create a DROP filter'}
Write-Host 'SANDBOX BEHAVIOUR PASS: config validation, schedule boundaries, IPv4/IPv6 filter construction.'
Write-Host 'SANDBOX SAFETY PASS: WinDivertOpen was not invoked; no network policy was changed.'
