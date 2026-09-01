# Untrapped Ultra Mode packet filter
# Requires WinDivert 2.2.2-A in this directory and Administrator privileges.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$config=Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$dll=Join-Path $root 'WinDivert.dll'
if(-not (Test-Path $dll)){throw 'WinDivert.dll is missing. Run INSTALL-PACKET-FILTER.ps1 as Administrator.'}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UD {
 [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)] public static extern IntPtr WinDivertOpen(string filter, uint layer, short priority, ulong flags);
 [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl)] public static extern bool WinDivertRecv(IntPtr h, byte[] packet, uint packetLen, out uint readLen, IntPtr addr);
 [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl)] public static extern bool WinDivertSend(IntPtr h, byte[] packet, uint packetLen, out uint writeLen, IntPtr addr);
 [DllImport("WinDivert.dll", CallingConvention=CallingConvention.Cdecl)] public static extern bool WinDivertClose(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint GetLastError();
}
'@
function Active { $s=[TimeSpan]::Parse($config.start);$e=[TimeSpan]::Parse($config.end);$t=(Get-Date).TimeOfDay;if($s -eq $e){return $true};if($s -lt $e){return $t -ge $s -and $t -lt $e};return $t -ge $s -or $t -lt $e }
$needles=@('youtube.com','www.youtube.com','m.youtube.com','music.youtube.com','youtube-nocookie.com')
$filter='outbound and (tcp.DstPort == 443 or udp.DstPort == 443)'
$handle=[IntPtr]::Zero
Write-Host "Untrapped packet filter started. Schedule $($config.start)-$($config.end)."
while($true){
  if($config.enabled -and (Active)){
    if($handle -eq [IntPtr]::Zero){$handle=[UD]::WinDivertOpen($filter,0,0,0);if($handle -eq [IntPtr]::Zero){throw "WinDivertOpen failed. Win32 error $([UD]::GetLastError())"};Write-Host 'Ultra Mode packet interception ACTIVE.'}
    $packet=New-Object byte[] 65535;$addr=[Runtime.InteropServices.Marshal]::AllocHGlobal(128)
    try{
      $ok=[UD]::WinDivertRecv($handle,$packet,[uint32]$packet.Length,[ref]$readLen,$addr)
      if($ok){$blocked=$false;for($i=0;$i -lt $readLen;$i++){foreach($n in $needles){$b=[Text.Encoding]::ASCII.GetBytes($n);if($i+$b.Length -le $readLen){$match=$true;for($j=0;$j -lt $b.Length;$j++){if($packet[$i+$j] -ne $b[$j]){$match=$false;break}};if($match){$blocked=$true;break}}};if($blocked){break}}
        if(-not $blocked){[UD]::WinDivertSend($handle,$packet,[uint32]$readLen,[ref]$written,$addr)|Out-Null}
      }
    }finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($addr)}
  }else{
    if($handle -ne [IntPtr]::Zero){[UD]::WinDivertClose($handle)|Out-Null;$handle=[IntPtr]::Zero;Write-Host 'Ultra Mode packet interception INACTIVE.'}
    Start-Sleep -Milliseconds 500
  }
}
