$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionRoot=Split-Path $Root -Parent
$chrome=(Get-Command chrome.exe -ErrorAction SilentlyContinue).Source
if(-not $chrome){$candidates=@("$env:ProgramFiles\Google\Chrome\Application\chrome.exe","$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe","$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe");$chrome=$candidates|Where-Object{Test-Path $_}|Select-Object -First 1}
if(-not $chrome){throw 'Chrome executable not found on Windows certification runner.'}
$manifest=Get-Content (Join-Path $ExtensionRoot 'manifest.json') -Raw|ConvertFrom-Json
if(-not(@($manifest.permissions)-contains 'webNavigation')){throw 'Manifest missing webNavigation permission.'}
foreach($f in @('policy.js','policy-config.json','blocked.html','background.js')){if(-not(Test-Path (Join-Path $ExtensionRoot $f))){throw "$f missing."}}
$tmp=Join-Path $env:TEMP ('untrapped-browser-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tmp -Force|Out-Null
try{
  foreach($f in @('manifest.json','background.js','content.js','policy.js','policy-config.json','blocked.html')){Copy-Item (Join-Path $ExtensionRoot $f) (Join-Path $tmp $f) -Force}
  Copy-Item (Join-Path $ExtensionRoot 'assets') (Join-Path $tmp 'assets') -Recurse -Force
  function Invoke-Chrome([string]$Url,[string]$ProfileName){
    $profile=Join-Path $tmp $ProfileName;$log=Join-Path $tmp ($ProfileName+'.txt')
    $args=@('--headless=new','--disable-gpu','--no-sandbox','--disable-dev-shm-usage','--disable-extensions-file-access-check','--disable-extensions-except='+$tmp,'--load-extension='+$tmp,'--user-data-dir='+$profile,'--dump-dom',$Url)
    & $chrome @args 1> $log 2>$null
    [pscustomobject]@{dom=(Get-Content $log -Raw);exit=$LASTEXITCODE}
  }
  $blocked=Invoke-Chrome 'https://www.youtube.com/watch?V=AAAAAAAAAAA' 'block-profile'
  if($blocked.dom -notmatch 'Navigation blocked'){throw 'Chrome integration did not produce the Untrapped block page for uppercase-V adversarial navigation.'}
  Write-Host 'BROWSER INTEGRATION PASS: uppercase-V navigation was blocked.'

  @{'youtubePolicy'=@{'allowAdditionalQueryParameters'=$true};'allowedYouTubeVideoIds'=@('AAAAAAAAAAA')}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $tmp 'policy-config.json') -Encoding UTF8
  $allowed=Invoke-Chrome 'https://www.youtube.com/watch?v=AAAAAAAAAAA' 'allow-profile'
  if($allowed.dom -match 'Navigation blocked'){throw 'Chrome integration blocked a canonical explicitly allowlisted video.'}
  Write-Host 'BROWSER INTEGRATION PASS: canonical allowlisted navigation was not blocked.'
  Write-Host 'BROWSER/INTEGRATION GATE PASS.'
}finally{Get-Process chrome -ErrorAction SilentlyContinue|Where-Object{$_.Path -eq $chrome}|Stop-Process -Force -ErrorAction SilentlyContinue;Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue}
