# Create a signed Ultra Mode override request.
# The encrypted private key may live on a separate computer/removable drive.
# The passphrase is entered interactively and the decrypted key exists only in memory.
param(
  [Parameter(Mandatory=$true)][string]$ExpiresUtc,
  [Parameter(Mandatory=$true)][string]$Reason,
  [Parameter(Mandatory=$true)][string]$KeyPath,
  [string]$OutputPath = (Join-Path $PSScriptRoot 'override-until.txt')
)
$ErrorActionPreference='Stop'
if(-not (Test-Path $KeyPath)){throw "Encrypted private key not found: $KeyPath"}
$record=Get-Content $KeyPath -Raw|ConvertFrom-Json
if($record.version -ne 1){throw 'Unsupported private-key format'}
$pass=Read-Host 'Private-key passphrase' -AsSecureString
$plainPass=[Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))
$aes=$null;$rsa=$null
try{
 $salt=[Convert]::FromBase64String($record.salt);$iv=[Convert]::FromBase64String($record.iv);$cipher=[Convert]::FromBase64String($record.ciphertext)
 $kdf=New-Object Security.Cryptography.Rfc2898DeriveBytes($plainPass,$salt,200000)
 $aes=New-Object Security.Cryptography.AesManaged;$aes.Key=$kdf.GetBytes(32);$aes.IV=$iv;$aes.Mode='CBC';$aes.Padding='PKCS7'
 $dec=$aes.CreateDecryptor();$jsonBytes=$dec.TransformFinalBlock($cipher,0,$cipher.Length);$keyJson=[Text.Encoding]::UTF8.GetString($jsonBytes)|ConvertFrom-Json
 $rsa=New-Object System.Security.Cryptography.RSACng
 $rsa.ImportParameters([System.Security.Cryptography.RSAParameters]@{Modulus=[Convert]::FromBase64String($keyJson.Modulus);Exponent=[Convert]::FromBase64String($keyJson.Exponent);P=[Convert]::FromBase64String($keyJson.P);Q=[Convert]::FromBase64String($keyJson.Q);DP=[Convert]::FromBase64String($keyJson.DP);DQ=[Convert]::FromBase64String($keyJson.DQ);InverseQ=[Convert]::FromBase64String($keyJson.InverseQ);D=[Convert]::FromBase64String($keyJson.D)})
 $nonce=[Convert]::ToBase64String((New-Object byte[] 32));[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonce)
 $payload="untrapped-ultra-v1|$ExpiresUtc|$([guid]::NewGuid().ToString('N'))|$Reason";$bytes=[Text.Encoding]::UTF8.GetBytes($payload)
 $sig=$rsa.SignData($bytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
 $out=[pscustomobject]@{version='1';payload=$payload;signature=[Convert]::ToBase64String($sig)}|ConvertTo-Json -Compress
 Set-Content -Path $OutputPath -Value $out -Encoding utf8
 Write-Host "Signed override written to: $OutputPath"
}finally{Remove-Variable plainPass,pass,keyJson,jsonBytes -ErrorAction SilentlyContinue;if($aes){$aes.Dispose()};if($rsa){$rsa.Dispose()}}
