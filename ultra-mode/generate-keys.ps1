# Generate an RSA key pair compatible with Windows PowerShell 5.1.
# The private key is encrypted locally with a passphrase and never uploaded.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE 'Untrapped-Ultra-Key'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$rsa = New-Object System.Security.Cryptography.RSACng -ArgumentList 3072
$privatePath = Join-Path $dir 'ultra-private.enc'
$publicPath = Join-Path $dir 'ultra-public.json'
$pass = Read-Host 'Create a passphrase for the private key' -AsSecureString
$plainPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))
try {
  $p = $rsa.ExportParameters($true)
  $pub = $rsa.ExportParameters($false)
  $keyJson = [pscustomobject]@{
    Modulus=[Convert]::ToBase64String($p.Modulus); Exponent=[Convert]::ToBase64String($p.Exponent)
    P=[Convert]::ToBase64String($p.P); Q=[Convert]::ToBase64String($p.Q); DP=[Convert]::ToBase64String($p.DP)
    DQ=[Convert]::ToBase64String($p.DQ); InverseQ=[Convert]::ToBase64String($p.InverseQ); D=[Convert]::ToBase64String($p.D)
  } | ConvertTo-Json -Compress
  $salt = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
  $iv = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($iv)
  $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($plainPass,$salt,200000)
  $aes = New-Object Security.Cryptography.AesManaged; $aes.Key=$kdf.GetBytes(32); $aes.IV=$iv; $aes.Mode='CBC'; $aes.Padding='PKCS7'
  $enc = $aes.CreateEncryptor(); $input=[Text.Encoding]::UTF8.GetBytes($keyJson); $cipher=$enc.TransformFinalBlock($input,0,$input.Length)
  $record=[pscustomobject]@{version=1;salt=[Convert]::ToBase64String($salt);iv=[Convert]::ToBase64String($iv);ciphertext=[Convert]::ToBase64String($cipher)} | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($privatePath,$record)
  [IO.File]::WriteAllText($publicPath,([pscustomobject]@{Modulus=[Convert]::ToBase64String($pub.Modulus);Exponent=[Convert]::ToBase64String($pub.Exponent)} | ConvertTo-Json -Compress))
} finally { Remove-Variable plainPass -ErrorAction SilentlyContinue; if($aes){$aes.Dispose()} ; $rsa.Dispose() }
Write-Host "Encrypted PRIVATE KEY: $privatePath"
Write-Host "PUBLIC KEY:            $publicPath"
Write-Host 'Keep the encrypted private key on your separate device. Do NOT commit it to GitHub.'
