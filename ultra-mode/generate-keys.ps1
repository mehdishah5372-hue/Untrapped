# Generate an RSA key pair for Ultra Mode emergency overrides.
# Run locally. The PRIVATE key is written outside the repository and is never
# uploaded by this script. Only the public key belongs in the repository.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE 'Untrapped-Ultra-Key'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$rsa = [System.Security.Cryptography.RSA]::Create(3072)
$privatePath = Join-Path $dir 'ultra-private.pem'
$publicPath = Join-Path $dir 'ultra-public.pem'
[IO.File]::WriteAllText($privatePath, $rsa.ExportPkcs8PrivateKeyPem())
[IO.File]::WriteAllText($publicPath, $rsa.ExportSubjectPublicKeyInfoPem())
Write-Host "PRIVATE KEY: $privatePath"
Write-Host "PUBLIC KEY:  $publicPath"
Write-Host "Keep the private key on a separate device/storage location. Do NOT commit it to GitHub."
