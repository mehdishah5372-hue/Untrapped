# Untrapped Ultra Mode packet filter
# Uses WinDivert NETWORK layer to block configured YouTube destination IPs.
# Brave itself remains usable. Requires WinDivert 2.2.2-A and Administrator privileges.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$config=Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$dll=Join-Path $root 'WinDivert.dll'
if(-not(Test-Path $dll)){throw 'WinDivert.dll is missing. Run INSTALL-PACKET-FILTER.ps1 as Administrator.'}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UD {
 [DllImport("WinDivert.dll",CallingConvention=CallingConvention.Cdecl,CharSet=CharSet.Ansi)] public static extern IntPtr WinDivertOpen(string f,uint l,short p,ulong flags);
 [DllImport("WinDivert.dll",CallingConvention=CallingConvention.Cdecl)] public static extern bool WinDivertRecv(IntPtr h,byte[] p,uint n,out uint r,IntPtr a);
 [DllImport("WinDivert.dll",CallingConvention=CallingConvention.Cdecl)] public static extern bool WinDivertClose(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint GetLastError();
}
'@
function Active { $s=[TimeSpan]::Parse($config.start);$e=[TimeSpan]::Parse($config.end);$t=(Get-Date).TimeOfDay;if($s -eq $e){return $true};if($s -lt $e){return $t -ge $s -and $t -lt $e};return $t -ge $s -or $t -lt $e }
function Resolve-IPs { $set=New-Object 'System.Collections.Generic.HashSet[string]';foreach($d in @('youtube.com','www.youtube.com','m.youtube.com','music.youtube.com','youtube-nocookie.com')){try{Resolve-DnsName $d -Type A -ErrorAction Stop|%{if($_.IPAddress){[void]$set.Add($_.IPAddress)}}}catch{};try{Resolve-DnsName $d -Type AAAA -ErrorAction Stop|%{if($_.IPAddress){[void]$set.Add($_.IPAddress)}}}catch{}};return @($set) }
$handle=[IntPtr]::Zero
try { while($true) { if($config.enabled -and (Active)) { if($handle -eq [IntPtr]::Zero) { $ips=Resolve-IPs;if($ips.Count -eq 0){throw 'No YouTube IPs resolved.'};$parts=@();foreach($ip in $ips){$parts += "ip.DstAddr == $ip"};$filter='outbound and ('+($parts -join ' or ')+')';$handle=[UD]::WinDivertOpen($filter,0,0,0);if($handle -eq [IntPtr]::Zero){throw "WinDivertOpen failed: $([UD]::GetLastError())"};Write-Host "Ultra Mode destination block ACTIVE ($($ips.Count) IPs)." };$packet=New-Object byte[] 65535;$addr=[Runtime.InteropServices.Marshal]::AllocHGlobal(128);try{[uint32]$readLen=0;$ok=[UD]::WinDivertRecv($handle,$packet,[uint32]$packet.Length,[ref]$readLen,$addr);if(-not $ok){$err=[UD]::GetLastError();if($err -ne 997){throw "WinDivertRecv failed: $err"}}}finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($addr)} } else {if($handle -ne [IntPtr]::Zero){[UD]::WinDivertClose($handle)|Out-Null;$handle=[IntPtr]::Zero;Write-Host 'Ultra Mode destination block INACTIVE.'};Start-Sleep -Milliseconds 500} } } finally {if($handle -ne [IntPtr]::Zero){[UD]::WinDivertClose($handle)|Out-Null}}
