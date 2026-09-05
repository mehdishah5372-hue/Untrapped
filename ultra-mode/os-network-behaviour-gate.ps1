$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Network behaviour gate requires Administrator.'}
if(-not ('UntrappedBehaviour.Native' -as [type])){
Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace UntrappedBehaviour { public static class Native {
[DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] public static extern bool SetDllDirectory(string p);
[DllImport("WinDivert.dll",CallingConvention=CallingConvention.Cdecl,CharSet=CharSet.Ansi,SetLastError=true)] public static extern IntPtr WinDivertOpen(string f,int l,short p,ulong flags);
[DllImport("WinDivert.dll",CallingConvention=CallingConvention.Cdecl,SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] public static extern bool WinDivertClose(IntPtr h);
}}
"@
}
[UntrappedBehaviour.Native]::SetDllDirectory($Root)|Out-Null
$ip=@(Resolve-DnsName example.com -Type A -DnsOnly -ErrorAction Stop|Where-Object{$_.IPAddress}|Select-Object -ExpandProperty IPAddress|Select-Object -First 1)
if(-not $ip){throw 'Could not resolve example.com IPv4.'}
$target=[string]$ip
$resolve="example.com:443:$target"
function Invoke-Probe([string]$Label){
  # --resolve is mandatory here: DNS may return multiple Cloudflare A records,
  # while the WinDivert filter is intentionally pinned to one concrete IPv4.
  # Without this binding, curl can legitimately connect to a different A
  # record and turn a real DROP test into a false negative.
  $args=@('-4','--noproxy','*','--resolve',$resolve,'-sS','-o','NUL','--connect-timeout','5','--max-time','8','https://example.com/')
  & curl.exe @args 2>$null
  $rc=$LASTEXITCODE
  Write-Host "PROBE $Label target=$target exit=$rc"
  return $rc
}
$baseline=Invoke-Probe 'baseline-allow'
if($baseline -ne 0){throw "Baseline network access to example.com failed; cannot certify OS behaviour. exit=$baseline"}
# Match the exact destination of the probe's TCP connection.  Omitting
# outbound/loopback qualifiers makes the behavioural proof independent of
# filter-direction classification while remaining specific to the target.
$filter="ip.DstAddr == $target and tcp.DstPort == 443"
Write-Host "DROP FILTER: $filter"
$h=[UntrappedBehaviour.Native]::WinDivertOpen($filter,0,30000,[UInt64]0x0002)
if($h -eq [IntPtr](-1) -or $h -eq [IntPtr]::Zero){$e=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "Behaviour DROP WinDivertOpen failed: $e"}
try{
  Start-Sleep -Milliseconds 300
  $blocked=Invoke-Probe 'policy-blocked'
  if($blocked -eq 0){throw 'Network request succeeded while the WinDivert DROP filter was active.'}
  Write-Host 'OS BEHAVIOUR PASS: policy says BLOCK and the real network attempt was blocked.'
}finally{
  if(-not [UntrappedBehaviour.Native]::WinDivertClose($h)){throw 'WinDivertClose failed after DROP behaviour test.'}
}
Start-Sleep -Milliseconds 500
$allowed=Invoke-Probe 'policy-allow-after-close'
if($allowed -ne 0){throw "Network request did not recover after filter removal. exit=$allowed"}
Write-Host 'OS BEHAVIOUR PASS: filter removed and the same real network attempt was allowed.'
Write-Host 'OS NETWORK BEHAVIOUR GATE PASS.'
