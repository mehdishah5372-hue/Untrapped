# Verify a signed Ultra Mode override request using the public RSA key.
# This is deliberately a separate, explicit action: Ultra Mode remains active
# unless a valid, unexpired signature is supplied.
param([Parameter(Mandatory=$true)][string]$RequestJson)
$ErrorActionPreference = 'Stop'
$configPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json
if (-not $config.publicKeyPem) { throw 'No public key configured in config.json' }
$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.ImportFromPem($config.publicKeyPem)
$req = $RequestJson | ConvertFrom-Json
$parts = $req.payload -split '\|', 4
if ($parts.Count -ne 4 -or $parts[0] -ne 'untrapped-ultra-v1') { throw 'Invalid request format' }
$expires = [DateTime]::Parse($parts[1]).ToUniversalTime()
if ([DateTime]::UtcNow -ge $expires) { throw 'Override request has expired' }
$bytes = [Text.Encoding]::UTF8.GetBytes($req.payload)
$sig = [Convert]::FromBase64String($req.signature)
if (-not $rsa.VerifyData($bytes, $sig, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'Invalid signature' }
$overridePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'override-until.txt'
[IO.File]::WriteAllText($overridePath, $expires.ToString('o'))
Write-Host "Valid override. Ultra Mode will remain overridden until $expires UTC."
