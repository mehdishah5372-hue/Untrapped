# Create a signed Ultra Mode override request using the encrypted private RSA key.
# The private key stays off the PC; this helper prompts for its passphrase and
# decrypts it only in memory. The decrypted key is never written to disk.
param(
  [Parameter(Mandatory=$true)][string]$ExpiresUtc,
  [Parameter(Mandatory=$true)][string]$Reason
)
$ErrorActionPreference = 'Stop'
$keyPath = Join-Path $env:USERPROFILE 'Untrapped-Ultra-Key\ultra-private.enc'
if (-not (Test-Path $keyPath)) { throw "Encrypted private key not found: $keyPath" }
$record = Get-Content $keyPath -Raw | ConvertFrom-Json
if ($record.version -ne 1) { throw 'Unsupported private-key format' }
$pass = Read-Host 'Private-key passphrase' -AsSecureString
$plainPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))
$aes = $null; $rsa = $null
try {
  $salt=[Convert]::FromBase64String($record.salt); $iv=[Convert]::FromBase64String($record.iv); $cipher=[Convert]::FromBase64String($record.ciphertext)
  $kdf=New-Object Security.Cryptography.Rfc2898DeriveBytes($plainPass,$salt,200000)
  $aes=New-Object Security.Cryptography.AesManaged; $aes.Key=$kdf.GetBytes(32); $aes.IV=$iv; $aes.Mode='CBC'; $aes.Padding='PKCS7'
  $dec=$aes.CreateDecryptor(); $jsonBytes=$dec.TransformFinalBlock($cipher,0,$cipher.Length); $keyJson=[Text.Encoding]::UTF8.GetString($jsonBytes) | ConvertFrom-Json
  $rsa=New-Object System.Security.Cryptography.RSACng
  $rsa.ImportParameters([System.Security.Cryptography.RSAParameters]@{Modulus=[Convert]::FromBase64String($keyJson.Modulus);Exponent=[Convert]::FromBase64String($keyJson.Exponent);P=[Convert]::FromBase64String($keyJson.P);Q=[Convert]::FromBase64String($keyJson.Q);DP=[Convert]::FromBase64String($keyJson.DP);DQ=[Convert]::FromBase64String($keyJson.DQ);InverseQ=[Convert]::FromBase64String($keyJson.InverseQ);D=[Convert]::FromBase64String($keyJson.D)})
  $nonce=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::Create().GetBytes(32))
  $payload="untrapped-ultra-v1|$ExpiresUtc|$nonce|$Reason"; $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
  $sig=$rsa.SignData($bytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
  [pscustomobject]@{version='1';payload=$payload;signature=[Convert]::ToBase64String($sig)} | ConvertTo-Json -Compress
} finally { Remove-Variable plainPass,pass,keyJson,jsonBytes -ErrorAction SilentlyContinue; if($aes){$aes.Dispose()}; if($rsa){$rsa.Dispose()} }
