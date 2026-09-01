# Untrapped Ultra Mode — Windows local enforcement
# Run as Administrator/SYSTEM. Blocks configured domains during the scheduled window.
# A valid, unexpired signed override may temporarily suspend the block.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$PublicKeyPath = Join-Path $env:USERPROFILE 'Untrapped-Ultra-Key\ultra-public.json'
if (-not (Test-Path $PublicKeyPath)) { $PublicKeyPath = Join-Path $Root 'ultra-public.json' }
$OverridePath = Join-Path $Root 'override-until.txt'
$StartMarker = '# >>> UNTRAPPED ULTRA MODE >>>'
$EndMarker = '# <<< UNTRAPPED ULTRA MODE <<<'

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Missing config.json" }
    Get-Content $ConfigPath -Raw | ConvertFrom-Json
}
function In-Window([datetime]$Now, [string]$Start, [string]$End) {
    $s=[TimeSpan]::Parse($Start); $e=[TimeSpan]::Parse($End); $t=$Now.TimeOfDay
    if ($s -eq $e) { return $true }; if ($s -lt $e) { return $t -ge $s -and $t -lt $e }; return $t -ge $s -or $t -lt $e
}
function Read-Hosts { if (Test-Path $HostsPath) { Get-Content $HostsPath } else { @() } }
function Remove-UltraBlock([string[]]$Lines) {
    $out=New-Object System.Collections.Generic.List[string]; $inside=$false
    foreach($line in $Lines){ if($line -eq $StartMarker){$inside=$true;continue}; if($line -eq $EndMarker){$inside=$false;continue}; if(-not $inside){[void]$out.Add($line)} }
    $out.ToArray()
}
function Apply-UltraBlock($Config) {
    $lines=Remove-UltraBlock (Read-Hosts); $block=New-Object System.Collections.Generic.List[string]
    [void]$block.Add($StartMarker); [void]$block.Add('# Managed by Untrapped Ultra Mode; do not edit this section manually.')
    foreach($domain in $Config.domains){ if($domain -and $domain -notmatch '[\s#]'){[void]$block.Add("0.0.0.0 $domain");[void]$block.Add(":: $domain")} }
    [void]$block.Add($EndMarker); Set-Content -Path $HostsPath -Value @($lines + '' + $block.ToArray()) -Encoding ascii; ipconfig /flushdns | Out-Null
}
function Test-SignedOverride {
    if(-not (Test-Path $OverridePath)){ return $false }
    try {
        $req=Get-Content $OverridePath -Raw | ConvertFrom-Json
        if($req.version -ne '1' -or -not $req.payload -or -not $req.signature){return $false}
        $parts=$req.payload -split '\|',4
        if($parts.Count -ne 4 -or $parts[0] -ne 'untrapped-ultra-v1'){return $false}
        $expires=[DateTime]::Parse($parts[1]).ToUniversalTime()
        if([DateTime]::UtcNow -ge $expires){return $false}
        if(-not (Test-Path $PublicKeyPath)){return $false}
        $pub=Get-Content $PublicKeyPath -Raw | ConvertFrom-Json
        $rsa=New-Object System.Security.Cryptography.RSACng
        $rsa.ImportParameters([System.Security.Cryptography.RSAParameters]@{Modulus=[Convert]::FromBase64String($pub.Modulus);Exponent=[Convert]::FromBase64String($pub.Exponent)})
        $bytes=[Text.Encoding]::UTF8.GetBytes($req.payload); $sig=[Convert]::FromBase64String($req.signature)
        $ok=$rsa.VerifyData($bytes,$sig,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1); $rsa.Dispose(); return $ok
    } catch { return $false }
}
$config=Get-Config; $active=$config.enabled -and (In-Window (Get-Date) $config.start $config.end); $override=Test-SignedOverride
$current=Read-Hosts; $hasBlock=[bool]($current | Where-Object {$_ -eq $StartMarker})
if($active -and -not $override -and -not $hasBlock){Apply-UltraBlock $config}
elseif(((-not $active) -or $override) -and $hasBlock){Set-Content -Path $HostsPath -Value (Remove-UltraBlock $current) -Encoding ascii;ipconfig /flushdns | Out-Null}
if($override -and (Test-Path $OverridePath)){try{$req=Get-Content $OverridePath -Raw|ConvertFrom-Json;$exp=[DateTime]::Parse(($req.payload -split '\|',4)[1]).ToUniversalTime();if([DateTime]::UtcNow -ge $exp){Remove-Item $OverridePath -Force -ErrorAction SilentlyContinue}}catch{}}
