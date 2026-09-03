# STAGE 6 — disposable Windows behavioural sandbox
# Safety boundary: only helper/policy functions are extracted from packet-filter.ps1.
# WinDivertOpen/Close, firewall/WFP/DNS/Hosts/routes/VPN/proxy/adapter changes are forbidden.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath=Join-Path $Root 'packet-filter.ps1';$configPath=Join-Path $Root 'config.json'
$tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('packet-filter.ps1 syntax failed: '+(($errors|ForEach-Object{$_.Message}) -join ' | '))}
$forbidden=@('WinDivertOpen','WinDivertClose','SetDllDirectory','Resolve-DnsName','Start-Process','New-Item','Copy-Item','Move-Item','Remove-Item','Set-NetFirewallRule','New-NetFirewallRule','Set-DnsClientServerAddress','route.exe','netsh.exe')
$hits=@($ast.FindAll({param($n) if($n -is [System.Management.Automation.Language.CommandAst]){$name=$n.GetCommandName();$forbidden -contains $name}},$true))
if($hits.Count){throw ('Unsafe command present in behavioural AST: '+(($hits|ForEach-Object{$_.GetCommandName()}) -join ', '))}
$functions=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
$wanted=@('Get-Config','Normalize-Domains','Test-Config','Test-UltraActive','New-WinDivertFilter')
foreach($name in $wanted){if(-not(@($functions|Where-Object{$_.Name -eq $name}).Count)){throw "Required policy function missing: $name"}}
$functionText=($functions|Where-Object{$wanted -contains $_.Name}|ForEach-Object{$_.Extent.Text}) -join "`n`n"
$ConfigPath=$configPath
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
Write-Host 'STAGE 6 PASS: policy configuration, schedule boundaries, and filter construction.'
Write-Host 'STAGE 6 SAFETY PASS: candidate was not installed and networking was not changed.'
