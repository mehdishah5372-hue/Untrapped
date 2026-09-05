param(
  [Parameter(Mandatory=$true,Position=0)]
  [string[]]$InputValue,
  [string]$PolicyPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\policy-config.json'),
  [switch]$RunExhaustive
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$PolicyPath=(Resolve-Path -LiteralPath $PolicyPath).Path
$PolicyText=Get-Content -LiteralPath $PolicyPath -Raw
$Policy=$PolicyText|ConvertFrom-Json
if($null -eq $Policy.youtubePolicy){throw 'policy-config.json is missing youtubePolicy.'}
if($null -eq $Policy.allowedYouTubeVideoIds){$Policy|Add-Member -NotePropertyName allowedYouTubeVideoIds -NotePropertyValue @()}
$ids=@($Policy.allowedYouTubeVideoIds|ForEach-Object{[string]$_})
$VideoIdRegex='^[A-Za-z0-9_-]{11}$'
$YouTubeUrlRegex='^https://(?:www\.)?youtube\.com/watch\?v=([A-Za-z0-9_-]{11})$'
$added=@()
foreach($value in $InputValue){
  $s=[string]$value
  if($s -match $YouTubeUrlRegex){$id=$Matches[1]}
  elseif($s -match $VideoIdRegex){$id=$s}
  else{throw "Invalid YouTube video ID/URL: $s. Use an 11-character ID or https://www.youtube.com/watch?v=<ID>."}
  if($ids -notcontains $id){$ids+=@($id);$added+=@($id)}
}
if($added.Count -eq 0){Write-Host 'ALLOWLIST UPDATE: no changes required.';exit 0}
$before=(ConvertFrom-Json $PolicyText)
$Policy.allowedYouTubeVideoIds=@($ids)
$serialized=$Policy|ConvertTo-Json -Depth 20
$tmp="$PolicyPath.$([guid]::NewGuid().ToString('N')).tmp"
$backup="$PolicyPath.bak.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))"
try{
  Set-Content -LiteralPath $tmp -Value $serialized -Encoding UTF8
  $check=Get-Content -LiteralPath $tmp -Raw|ConvertFrom-Json
  foreach($id in $added){if(@($check.allowedYouTubeVideoIds)-notcontains $id){throw "Atomic-write verification failed for $id"}}
  $beforeOther=($before|Select-Object * -ExcludeProperty allowedYouTubeVideoIds|ConvertTo-Json -Depth 20)
  $afterOther=($check|Select-Object * -ExcludeProperty allowedYouTubeVideoIds|ConvertTo-Json -Depth 20)
  if($beforeOther -ne $afterOther){throw 'Safety check failed: fields outside allowedYouTubeVideoIds changed.'}
  Copy-Item -LiteralPath $PolicyPath -Destination $backup -Force
  Move-Item -LiteralPath $tmp -Destination $PolicyPath -Force
  Write-Host "ALLOWLIST UPDATE PASS: added=$($added -join ',')"
  Write-Host "Backup: $backup"
  . (Join-Path $Root 'YouTubePolicy.ps1')
  foreach($id in $added){
    $url="https://www.youtube.com/watch?v=$id"
    $r=Resolve-YouTubePolicy $url $check
    if($r.decision -cne 'ALLOW'){throw "Post-update policy validation failed for $id: $($r.reason)"}
    $upper=Resolve-YouTubePolicy "https://www.youtube.com/watch?V=$id" $check
    if($upper.decision -cne 'BLOCK'){throw "Post-update case-sensitive validation failed for $id"}
  }
  $dup=Resolve-YouTubePolicy "https://www.youtube.com/watch?v=$($added[0])&v=$($added[0])" $check
  if($dup.decision -cne 'BLOCK'){throw 'Post-update duplicate-v safety validation failed.'}
  Write-Host 'ALLOWLIST UPDATE VALIDATION PASS: canonical URL allows; uppercase V and duplicate v remain blocked.'
  if($RunExhaustive){& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'powershell-policy-exhaustive.ps1');if($LASTEXITCODE -ne 0){throw 'Exhaustive policy certification failed after allowlist update.'}}
}catch{
  if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
  if(Test-Path -LiteralPath $backup){Copy-Item -LiteralPath $backup -Destination $PolicyPath -Force}
  throw
}
