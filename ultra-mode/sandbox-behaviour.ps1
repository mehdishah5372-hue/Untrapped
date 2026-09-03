# STAGE 6 — disposable Windows behavioural sandbox
# Fetches the exact pinned artifact from the 3.2.0/000-999 middleman when no explicit paths are supplied.
# Only policy/helper functions are executed. The full packet-filter candidate is never executed.
# No WinDivert, firewall, WFP, DNS, Hosts, routes, VPN, proxy, adapter or override-policy changes.
param(
 [string]$ScriptPath,
 [string]$ConfigPath
)
$ErrorActionPreference='Stop'
$Middleman='https://untrapped-update-middleman-000-999-production.up.railway.app';$ArtifactBase=$Middleman+'/v1/artifact/';$ExpectedVersion='3.2.0';$ExpectedProtocol=3;$ExpectedBaseline='1.0.0';$MaxBytes=8388608
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$cleanup=$false;$TempRoot=$null
function HashBytes([byte[]]$b){$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash($b))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function ReadLimited([IO.Stream]$st){$m=New-Object IO.MemoryStream;$b=New-Object byte[] 65536;$n=0;try{while(($r=$st.Read($b,0,$b.Length)) -gt 0){$n+=$r;if($n -gt $MaxBytes){throw "response exceeds $MaxBytes byte limit"};$m.Write($b,0,$r)};return $m.ToArray()}finally{$m.Dispose()}}
function FetchRemote([string]$name){$q=[Net.HttpWebRequest]::Create($ArtifactBase+$name+'?sandbox='+[Guid]::NewGuid().ToString('N'));$q.Method='GET';$q.Timeout=30000;$q.ReadWriteTimeout=30000;$q.AllowAutoRedirect=$false;$q.UserAgent='UAUD-Stage6/3.0.0';$r=$q.GetResponse();try{$v=[string]$r.Headers['X-Untrapped-Version'];$p=[int]$r.Headers['X-Untrapped-Protocol'];$b=[string]$r.Headers['X-Untrapped-Baseline'];if($v -ne $ExpectedVersion -or $p -ne $ExpectedProtocol -or $b -ne $ExpectedBaseline){throw "middleman identity mismatch: version=$v protocol=$p baseline=$b"};$raw=ReadLimited $r.GetResponseStream();$h=[string]$r.Headers['X-Untrapped-SHA256'];if($h -and $h -ne (HashBytes $raw)){throw 'middleman SHA256 header mismatch'};return $raw}finally{$r.Dispose()}}
try{
  if(-not $ScriptPath -or -not $ConfigPath){$TempRoot=Join-Path $env:TEMP ('UAUD-stage6-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $TempRoot -Force|Out-Null;$ScriptPath=Join-Path $TempRoot 'packet-filter.ps1';$ConfigPath=Join-Path $TempRoot 'config.json';[IO.File]::WriteAllBytes($ScriptPath,(FetchRemote 'ultra-mode/packet-filter.ps1'));[IO.File]::WriteAllBytes($ConfigPath,(FetchRemote 'ultra-mode/config.json'));$cleanup=$true}
  if(-not(Test-Path -LiteralPath $ScriptPath)){throw "Behavioural candidate not found: $ScriptPath"};if(-not(Test-Path -LiteralPath $ConfigPath)){throw "Behavioural config not found: $ConfigPath"}
  $tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$tokens,[ref]$errors)
  if(@($errors).Count){throw ('packet-filter.ps1 syntax failed: '+(($errors|ForEach-Object{$_.Message}) -join ' | '))}
  $functions=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true));$wanted=@('Get-Config','Normalize-Domains','Test-Config','Test-UltraActive','New-WinDivertFilter')
  foreach($name in $wanted){if(-not(@($functions|Where-Object{$_.Name -eq $name}).Count)){throw "Required policy function missing: $name"}}
  $functionText=($functions|Where-Object{$wanted -contains $_.Name}|ForEach-Object{$_.Extent.Text}) -join "`n`n"
  $ht=$null;$he=$null;$helperAst=[System.Management.Automation.Language.Parser]::ParseInput($functionText,[ref]$ht,[ref]$he);if(@($he).Count){throw 'Extracted policy syntax failed'}
  $forbidden=@('WinDivertOpen','WinDivertClose','SetDllDirectory','Start-Process','Set-NetFirewallRule','New-NetFirewallRule','Set-DnsClientServerAddress','route.exe','netsh.exe','Set-Content','Add-Content','Out-File','Move-Item','Copy-Item','Remove-Item')
  $hits=@($helperAst.FindAll({param($n)if($n -is [System.Management.Automation.Language.CommandAst]){$forbidden -contains $n.GetCommandName()}},$true));if($hits.Count){throw ('Unsafe command present in executable sandbox AST: '+(($hits|ForEach-Object{$_.GetCommandName()}) -join ', '))}
  . ([scriptblock]::Create($functionText))
  $config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json;Test-Config $config
  if(Test-UltraActive $config ([TimeSpan]::Parse('04:59'))){throw 'Schedule boundary bug: 04:59 unexpectedly active'}
  if(-not(Test-UltraActive $config ([TimeSpan]::Parse('05:00')))){throw 'Schedule boundary bug: 05:00 should be active'}
  if(-not(Test-UltraActive $config ([TimeSpan]::Parse('21:59')))){throw 'Schedule boundary bug: 21:59 should be active'}
  if(Test-UltraActive $config ([TimeSpan]::Parse('22:00'))){throw 'Schedule boundary bug: 22:00 should be inactive'}
  if(Test-UltraActive $config ([TimeSpan]::Parse('23:30'))){throw 'Schedule boundary bug: 23:30 unexpectedly active'}
  $f=New-WinDivertFilter @('1.2.3.4','2001:db8::1');if($f -notmatch 'ip\.DstAddr == 1\.2\.3\.4'){throw 'IPv4 filter clause missing'};if($f -notmatch 'ipv6\.DstAddr == 2001:db8::1'){throw 'IPv6 filter clause missing'};if($f -notmatch 'tcp\.DstPort == 443' -or $f -notmatch 'udp\.DstPort == 443'){throw 'TLS/QUIC destination ports missing'};if($null -ne (New-WinDivertFilter @())){throw 'Empty IP set must not create a DROP filter'}
  Write-Host 'STAGE 6 PASS: exact pinned middleman candidate/config behaviourally validated in disposable process sandbox.'
  Write-Host 'STAGE 6 SAFETY PASS: full packet-filter.ps1 was never executed; no network policy was changed.'
  exit 0
}finally{if($cleanup -and $TempRoot){Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue}}
