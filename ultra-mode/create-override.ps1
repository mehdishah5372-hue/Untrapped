# Create a signed Ultra Mode override request using the private RSA key.
# The private key should live on a separate device. This helper is intended to
# be run on that device, then the resulting request transferred to the PC.
param(
  [Parameter(Mandatory=$true)][string]$ExpiresUtc,
  [Parameter(Mandatory=$true)][string]$Reason
)
$ErrorActionPreference = 'Stop'
$keyPath = Join-Path $env:USERPROFILE 'Untrapped-Ultra-Key\ultra-private.pem'
if (-not (Test-Path $keyPath)) { throw "Private key not found: $keyPath" }
$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.ImportFromPem((Get-Content $keyPath -Raw))
$nonce = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$payload = "untrapped-ultra-v1|$ExpiresUtc|$nonce|$Reason"
$bytes = [Text.Encoding]::UTF8.GetBytes($payload)
$sig = $rsa.SignData($bytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
[pscustomobject]@{ version='1'; payload=$payload; signature=[Convert]::ToBase64String($sig) } | ConvertTo-Json -Compress
