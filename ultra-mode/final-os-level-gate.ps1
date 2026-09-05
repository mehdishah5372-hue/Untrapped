$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$results=@()
function Check($name,[scriptblock]$action){
  try{$v=& $action;$results += [pscustomobject]@{Check=$name;Status='PASS';Detail=[string]$v}}
  catch{$results += [pscustomobject]@{Check=$name;Status='FAIL';Detail=$_.Exception.Message}}
}
Check 'Administrator context' {
  if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Runner is not elevated'}
  'elevated'
}
foreach($f in @('WinDivert.dll','WinDivert64.sys','config.json')){
  Check "Required artifact $f" {if(-not(Test-Path (Join-Path $root $f))){throw "$f missing"};'present'}
}
Check 'PowerShell version' {[System.Environment]::OSVersion.Version.ToString()}
Check 'Execution policy visibility' {(Get-ExecutionPolicy -List | Out-String).Trim()}
Check 'WinDivert driver load/open/close' {
  if(-not ('OSBlockerNative.Test' -as [type])){
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace OSBlockerNative {
 public static class Test {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetDllDirectory(string p);
  [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr WinDivertOpen(string filter,int layer,short priority,ulong flags);
  [DllImport("WinDivert.dll",CallingConvention=CallingConvention.Cdecl,SetLastError=true)] public static extern bool WinDivertClose(IntPtr h);
 }
}
'@
  }
  if(-not [OSBlockerNative.Test]::SetDllDirectory($root)){throw 'SetDllDirectory failed'}
  $h=[OSBlockerNative.Test]::WinDivertOpen('false',0,1000,[UInt64]0)
  if($h -eq [IntPtr](-1) -or $h -eq [IntPtr]::Zero){throw "WinDivertOpen failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
  if(-not [OSBlockerNative.Test]::WinDivertClose($h)){throw 'WinDivertClose failed'}
  'driver responded to open/close'
}
Check 'Packet-filter syntax and protected startup boundary' {
  $p=Join-Path $root 'packet-filter.ps1'
  $e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$e)
  if($e.Count){throw (($e|% Message)-join '; ')}
  $s=Get-Content -Raw $p
  if($s -notmatch 'Administrator privileges are required'){throw 'Admin guard missing'}
  'syntax/admin guard present'
}
Check 'Policy config can be consumed by OS layer' {
  $rules=Get-Content (Join-Path $root '..\youtube-allowlist.json') -Raw | ConvertFrom-Json
  if([int]$rules.version -ne 1){throw 'Unsupported policy version'}
  if(-not $rules.policy.allowOnlyListedWatchVideos){throw 'Fail-closed YouTube policy disabled'}
  if(@($rules.allowedYouTubeUrls).Count -lt 1){throw 'No allowed URL'}
  'policy consumed'
}
$failed=@($results|? Status -eq 'FAIL')
$results|Format-Table -AutoSize|Out-String|Write-Host
if($failed.Count){throw "FINAL OS-LEVEL GATE FAILED: $($failed.Count) check(s)"}
Write-Host 'FINAL OS-LEVEL GATE: PASS'
