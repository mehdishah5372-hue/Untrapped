$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$rules=Get-Content (Join-Path $Root 'youtube-allowlist.json') -Raw|ConvertFrom-Json
if([int]$rules.version -ne 1 -or -not [bool]$rules.policy.allowOnlyListedWatchVideos){throw 'Invalid allowlist policy'}
$entries=@($rules.allowedYouTubeUrls)
if($entries.Count -lt 1){throw 'YouTube allowlist is empty'}
foreach($entry in $entries){
  $u=[Uri]$entry.url
  if($u.Scheme -ne 'https' -or $u.Host -notmatch '^(www\.)?(m\.)?youtube\.com$' -or $u.AbsolutePath -ne '/watch'){throw "Invalid allowed URL: $($entry.url)"}
  $ids=[regex]::Matches($u.Query,'(?:^|&)v=([^&]*)')
  if($ids.Count -ne 1 -or $ids[0].Groups[1].Value -notmatch '^[A-Za-z0-9_-]{11}$'){throw "Invalid video id: $($entry.url)"}
  if([string]::IsNullOrWhiteSpace([string]$entry.reason)){throw "Missing reason: $($entry.url)"}
}
$mustBlock=@('https://www.youtube.com/watch?v=dQw4w9WgXcQ','https://www.youtube.com/shorts/dQw4w9WgXcQ','https://www.youtube.com/results?search_query=test','https://youtu.be/dQw4w9WgXcQ','https://www.youtube.com/watch?v=2wgg7KtzTrU&v=dQw4w9WgXcQ')
foreach($x in $mustBlock){
  $u=[Uri]$x
  $ids=[regex]::Matches($u.Query,'(?:^|&)v=([^&]*)')
  if($u.Host -match '^(www\.|m\.)?youtube\.com$' -and $u.AbsolutePath -eq '/watch' -and $ids.Count -eq 1 -and $ids[0].Groups[1].Value -eq '2wgg7KtzTrU'){throw "Unsafe allow candidate: $x"}
}
Write-Host 'YOUTUBE JSON + POWERSHELL POLICY CONTRACT: PASS'