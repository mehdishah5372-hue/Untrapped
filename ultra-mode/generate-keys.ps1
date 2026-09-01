# Generate an RSA key pair for Ultra Mode emergency overrides.
# The private key is encrypted locally with a passphrase and never uploaded.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE 'Untrapped-Ultra-Key'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$rsa = [System.Security.Cryptography.RSA]::Create(3072)
$privatePath = Join-Path $dir 'ultra-private.pem'
$publicPath = Join-Path $dir 'ultra-public.pem'
$secure = Read-Host 'Create a passphrase for the private key' -AsSecureString
$plain = [System.Net.NetworkCredential]::new('', $secure).Password
$encrypted = $rsa.ExportEncryptedPkcs8PrivateKeyPem($plain, [System.Security.Cryptography.PbeParameters]::new([System.Security.Cryptography.PbeEncryptionAlgorithm]::Aes256Cbc, [System.Security.Cryptography.HashAlgorithmName]::SHA256, 200000))
[IO.File]::WriteAllText($privatePath, $encrypted)
[IO.File]::WriteAllText($publicPath, $rsa.ExportSubjectPublicKeyInfoPem())
Remove-Variable plain, secure
Write-Host "PRIVATE KEY (encrypted): $privatePath"
Write-Host "PUBLIC KEY:              $publicPath"
Write-Host "Move the encrypted private key to your separate device/storage. Never commit it to GitHub."
