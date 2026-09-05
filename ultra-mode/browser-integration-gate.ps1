$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionRoot=Split-Path $Root -Parent
$chrome=(Get-Command chrome.exe -ErrorAction SilentlyContinue).Source
if(-not $chrome){$candidates=@("$env:ProgramFiles\Google\Chrome\Application\chrome.exe","$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe","$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe");$chrome=$candidates|Where-Object{Test-Path $_}|Select-Object -First 1}
if(-not $chrome){throw 'Chrome executable not found on Windows certification runner.'}
$manifest=Get-Content (Join-Path $ExtensionRoot 'manifest.json') -Raw|ConvertFrom-Json
if(-not(@($manifest.permissions)-contains 'webNavigation')){throw 'Manifest missing webNavigation permission.'}
if(-not(Test-Path (Join-Path $ExtensionRoot 'policy.js'))){throw 'policy.js missing.'}
if(-not(Test-Path (Join-Path $ExtensionRoot 'policy-config.json'))){throw 'policy-config.json missing.'}
$tmp=Join-Path $env:TEMP ('untrapped-browser-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tmp -Force|Out-Null
$profile=Join-Path $tmp 'profile';$log=Join-Path $tmp 'dom.txt'
try{
  # Copy only extension resources required by manifest/background/content execution.
  foreach($f in @('manifest.json','background.js','content.js','policy.js','policy-config.json','blocked.html')){Copy-Item (Join-Path $ExtensionRoot $f) (Join-Path $tmp $f) -Force}
  Copy-Item (Join-Path $ExtensionRoot 'assets') (Join-Path $tmp 'assets') -Recurse -Force
  $args=@('--headless=new','--disable-gpu','--no-sandbox','--disable-dev-shm-usage','--disable-extensions-file-access-check','--disable-extensions-except='+$tmp,'--load-extension='+$tmp,'--user-data-dir='+$profile,'--dump-dom','https://www.youtube.com/watch?V=AAAAAAAAAAA')
  & $chrome @args 1> $log 2>$null
  $dom=Get-Content $log -Raw
  if($dom -notmatch 'Navigation blocked'){throw 'Chrome integration did not produce the Untrapped block page for uppercase-V adversarial navigation.'}
  Write-Host 'BROWSER INTEGRATION PASS: Chrome navigation reached the Untrapped block boundary.'
}finally{Get-Process chrome -ErrorAction SilentlyContinue|Where-Object{$_.Path -eq $chrome}|Stop-Process -Force -ErrorAction SilentlyContinue;Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue}
