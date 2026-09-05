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
$errFile=Join-Path $env:TEMP ("untrapped-curl-"+[guid]::NewGuid().ToString('N')+'.err')
function Invoke-Probe([string]$Label){
  Remove-Item $errFile -Force -ErrorAction SilentlyContinue
  # --resolve binds SNI/hostname to the exact A record used by the WinDivert
  # filter. --noproxy prevents an environment proxy from bypassing the test.
  $args=@('-4','--noproxy','*','--resolve',$resolve,'-sS','-o','NUL','--connect-timeout','5','--max-time','8','https://example.com/')
  & curl.exe @args 2>$errFile
  $rc=$LASTEXITCODE
  $err=''
  if(Test-Path $errFile){$raw=Get-Content $errFile -Raw -ErrorAction SilentlyContinue;if($null -ne $raw){$err=([string]$raw).Trim()}}
  if($err){Write-Host "PROBE $Label target=$target exit=$rc stderr=$err"}else{Write-Host "PROBE $Label target=$target exit=$rc"}
  return $rc
}
try{
  $baseline=Invoke-Probe 'baseline-allow'
  if($baseline -ne 0){throw "Baseline network access to example.com failed; cannot certify OS behaviour. exit=$baseline"}

  $filter="ip.DstAddr == $target and tcp.DstPort == 443"
  Write-Host "DROP FILTER: $filter"
  $h=[UntrappedBehaviour.Native]::WinDivertOpen($filter,0,30000,[UInt64]0x0002)
  if($h -eq [IntPtr](-1) -or $h -eq [IntPtr]::Zero){$e=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "Behaviour DROP WinDivertOpen failed: $e"}
  try{
    Start-Sleep -Milliseconds 300
    $blockedResults=@()
    1..3|ForEach-Object{$blockedResults+=Invoke-Probe ("policy-blocked-$_");Start-Sleep -Milliseconds 200}
    if(@($blockedResults|Where-Object{$_ -eq 0}).Count -ne 0){throw "At least one network request succeeded while the WinDivert DROP filter was active. exits=$($blockedResults -join ',')"}
    if(@($blockedResults|Where-Object{$_ -eq 28}).Count -lt 1){throw "DROP did not produce a curl connection-timeout on any trial. exits=$($blockedResults -join ',')"}
    Write-Host "OS BEHAVIOUR PASS: all 3 real network attempts were blocked; timeout trials=$(@($blockedResults|Where-Object{$_ -eq 28}).Count)."
  }finally{
    if(-not [UntrappedBehaviour.Native]::WinDivertClose($h)){throw 'WinDivertClose failed after DROP behaviour test.'}
  }

  Start-Sleep -Milliseconds 500
  $allowedResults=@()
  1..3|ForEach-Object{$allowedResults+=Invoke-Probe ("policy-allow-after-close-$_");Start-Sleep -Milliseconds 200}
  if(@($allowedResults|Where-Object{$_ -ne 0}).Count -ne 0){throw "Network access did not recover after filter removal. exits=$($allowedResults -join ',')"}
  Write-Host 'OS BEHAVIOUR PASS: all 3 real network attempts recovered after filter removal.'
  Write-Host 'OS NETWORK BEHAVIOUR GATE PASS.'
}finally{
  Remove-Item $errFile -Force -ErrorAction SilentlyContinue
}
