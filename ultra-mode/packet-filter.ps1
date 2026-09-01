# Untrapped Ultra Mode packet filter
# Blocks configured YouTube destinations at the Windows packet layer without blocking Brave itself.
# Requires WinDivert 2.2.2-A and Administrator privileges.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$config=Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$dll=Join-Path $root 'WinDivert.dll'
if(-not (Test-Path $dll)){throw 'WinDivert.dll is missing. Run INSTALL-PACKET-FILTER.ps1 as Administrator.'}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UD {
 [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)] public static extern IntPtr WinDivertOpen(string filter,uint layer,short priority,ulong flags);
 [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl)] public static extern bool WinDivertRecv(IntPtr h,byte[] packet,uint packetLen,out uint readLen,IntPtr addr);
 [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl)] public static extern bool WinDivertSend(IntPtr h,byte[] packet,uint packetLen,out uint writeLen,IntPtr addr);
 [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl)] public static extern bool WinDivertClose(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint GetLastError();
}
'@
function Active { $s=[TimeSpan]::Parse($config.start);$e=[TimeSpan]::Parse($config.end);$t=(Get-Date).TimeOfDay;if($s -eq $e){return $true};if($s -lt $e){return $t -ge $s -and $t -lt $e};return $t -ge $s -or $t -lt $e }
# WinDivert filter catches new outbound TCP/UDP web connections. We block the YouTube
# IP ranges used by the hostnames resolved from DNS; the hosts file remains a second layer.
$domains=@('youtube.com','www.youtube.com','m.youtube.com','music.youtube.com','youtube-nocookie.com')
function Resolve-IPs { $set=New-Object 'System.Collections.Generic.HashSet[string]';foreach($d in $domains){foreach($type in @('A','AAAA')){try{foreach($x in Resolve-DnsName -Name $d -Type $type -ErrorAction Stop){if($x.IPAddress){[void]$set.Add($x.IPAddress)}}}catch{}}};@($set) }
$handle=[IntPtr]::Zero
try {
 while($true){
  if($config.enabled -and (Active)){
   if($handle -eq [IntPtr]::Zero){
    $ips=Resolve-IPs
    if($ips.Count -eq 0){throw 'No YouTube destination IPs could be resolved.'}
    $ipExpr=($ips | ForEach-Object { "ip.DstAddr == $_" }) -join ' or '
    $filter="outbound and ($ipExpr) and (tcp or udp)"
    $handle=[UD]::WinDivertOpen($filter,0,0,0)
    if($handle -eq [IntPtr]::Zero){throw "WinDivertOpen failed. Win32 error $([UD]::GetLastError())"}
    Write-Host "Ultra Mode YouTube packet block ACTIVE; $($ips.Count) destination IPs." 
   }
   $packet=New-Object byte[] 65535;$addr=[Runtime.InteropServices.Marshal]::AllocHGlobal(128)
   try {[uint32]$readLen=0;[uint32]$written=0;$ok=[UD]::WinDivertRecv($handle,$packet,[uint32]$packet.Length,[ref]$readLen,$addr);if($ok -and $readLen -gt 0){# Intentionally do not reinject matched packets: this is the block.
   }} finally {[Runtime.InteropServices.Marshal]::FreeHGlobal($addr)}
  } else {
   if($handle -ne [IntPtr]::Zero){[UD]::WinDivertClose($handle)|Out-Null;$handle=[IntPtr]::Zero;Write-Host 'Ultra Mode YouTube packet block INACTIVE.'}
   Start-Sleep -Milliseconds 500
  }
 }
} finally {if($handle -ne [IntPtr]::Zero){[UD]::WinDivertClose($handle)|Out-Null}}
