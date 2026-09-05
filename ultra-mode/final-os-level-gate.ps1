# FINAL OS-LEVEL RESPONSE — hard certification gate.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$report = Join-Path $Root 'final-os-level-report.json'
$results = [ordered]@{}
function Pass([string]$Name,[object]$Value=$true) {
    $results[$Name] = [ordered]@{ status='PASS'; value=$Value }
    Write-Host ('OS PASS: ' + $Name)
}
function Fail([string]$Name,[string]$Message) {
    $results[$Name] = [ordered]@{ status='FAIL'; message=$Message }
    throw ('FINAL OS-LEVEL GATE FAIL: ' + $Name + ' - ' + $Message)
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){ Fail 'administrator' 'Runner is not elevated.' }
Pass 'administrator'

foreach($required in @('WinDivert.dll','WinDivert64.sys','config.json','packet-filter.ps1','YouTubePolicy.ps1')) {
    if(-not (Test-Path (Join-Path $Root $required))){ Fail 'required-artifacts' ('Missing artifact: ' + $required) }
}
Pass 'required-artifacts'

$psVersion = $PSVersionTable.PSVersion.ToString()
if($PSVersionTable.PSEdition -ne 'Desktop'){ Fail 'windows-powershell' ('Expected Windows PowerShell Desktop, got ' + $PSVersionTable.PSEdition) }
Pass 'windows-powershell' $psVersion

$policyList = @(Get-ExecutionPolicy -List | ForEach-Object { [ordered]@{ scope=[string]$_.Scope; execution_policy=[string]$_.ExecutionPolicy } })
$effective = [string](Get-ExecutionPolicy)
if($effective -eq 'Restricted'){ Fail 'execution-policy-effective' 'Effective execution policy is Restricted.' }
Pass 'execution-policy-effective' ([ordered]@{ effective=$effective; scopes=$policyList })

$packet = Get-Content (Join-Path $Root 'packet-filter.ps1') -Raw
$tokens=$null;$parseErrors=$null
[void][System.Management.Automation.Language.Parser]::ParseInput($packet,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){ Fail 'packet-filter-parse' (($parseErrors|ForEach-Object{$_.Message}) -join ' | ') }
if($packet -notmatch 'IsInRole\(\[Security\.Principal\.WindowsBuiltInRole\]::Administrator\)'){ Fail 'administrator-guard' 'packet-filter.ps1 lacks administrator safety guard.' }
if($packet -notmatch 'WinDivertOpen' -or $packet -notmatch 'WinDivertClose'){ Fail 'windivert-primitives' 'packet-filter.ps1 lacks WinDivertOpen/WinDivertClose.' }
if($packet -notmatch 'EmergencyFilter' -or $packet -notmatch 'FAIL-CLOSED'){ Fail 'fail-closed-path' 'packet-filter.ps1 lacks emergency fail-closed path.' }
Pass 'packet-filter-parse-and-safety'

$config = Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
foreach($n in @('enabled','start','end','domains','alwaysBlockedDomains','alwaysAllowedDomains','youtubePolicy','allowedYouTubeVideoIds')) {
    if($null -eq $config.$n){ Fail 'json-policy-consumption' ('Missing policy property: ' + $n) }
}
if(@($config.domains|Where-Object{$_ -eq 'youtube.com'}).Count -eq 0){ Fail 'json-policy-consumption' 'youtube.com is absent from canonical blocking policy.' }
if($null -eq $config.youtubePolicy.allowAdditionalQueryParameters){ Fail 'json-policy-consumption' 'youtubePolicy is incomplete.' }
Pass 'json-policy-consumption'

if(@($config.allowedYouTubeVideoIds).Count -gt 0) {
    foreach($id in @($config.allowedYouTubeVideoIds)) {
        if([string]$id -cnotmatch '^[A-Za-z0-9_-]{11}$'){ Fail 'fail-closed-youtube-policy' ('Invalid allowlisted video ID: ' + [string]$id) }
    }
}
Pass 'fail-closed-youtube-policy' ([ordered]@{ allowlisted_video_count=@($config.allowedYouTubeVideoIds).Count; default='BLOCK' })

if(-not ('UntrappedOSGate.Native' -as [type])){
  Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace UntrappedOSGate {
 public static class Native {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetDllDirectory(string lpPathName);
  [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr WinDivertOpen(string filter, int layer, short priority, ulong flags);
  [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl, SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool WinDivertClose(IntPtr handle);
 }
}
"@
}
if(-not [UntrappedOSGate.Native]::SetDllDirectory($Root)){ Fail 'dll-directory' 'SetDllDirectory failed.' }
$h=[UntrappedOSGate.Native]::WinDivertOpen('false',0,0,0)
if($h -eq [IntPtr](-1) -or $h -eq [IntPtr]::Zero){ $e=[Runtime.InteropServices.Marshal]::GetLastWin32Error(); Fail 'windivert-open' ('WinDivertOpen(false) failed with Windows error ' + $e) }
Pass 'windivert-dll-load-and-open'
if(-not [UntrappedOSGate.Native]::WinDivertClose($h)){ Fail 'windivert-close' 'WinDivertClose returned false.' }
Pass 'windivert-close'

$tokens=$null;$errs=$null
$funcAst=[System.Management.Automation.Language.Parser]::ParseInput((Get-Content (Join-Path $Root 'packet-filter.ps1') -Raw),[ref]$tokens,[ref]$errs)
$sampleAst=$funcAst.Find({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-WinDivertFilter'},$true)
if($null -eq $sampleAst){ Fail 'packet-filter-function' 'New-WinDivertFilter function not found.' }
. ([scriptblock]::Create($sampleAst.Extent.Text))
$sample=New-WinDivertFilter @('1.2.3.4','2001:db8::1')
if($sample -notmatch 'ip\.DstAddr == 1\.2\.3\.4' -or $sample -notmatch 'ipv6\.DstAddr == 2001:db8::1'){ Fail 'packet-filter-generation' 'Generated IPv4/IPv6 clauses do not match expected policy.' }
if($sample -notmatch 'tcp\.DstPort == 443' -or $sample -notmatch 'udp\.DstPort == 443'){ Fail 'packet-filter-generation' 'Generated HTTPS/QUIC clauses are missing.' }
Pass 'packet-filter-generation'

$results['status']='PASS'
$results['timestamp_utc']=[DateTime]::UtcNow.ToString('o')
$results|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $report -Encoding UTF8
Write-Host 'FINAL OS-LEVEL RESPONSE: PASS'
exit 0
