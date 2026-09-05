$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$rules=Get-Content (Join-Path $Root 'youtube-allowlist.json') -Raw|ConvertFrom-Json
$entries=@($rules.allowedYouTubeUrls)
if($entries.Count -lt 1){throw 'YouTube allowlist is empty'}
foreach($entry in $entries){
  $u=[Uri]$entry.url
  if($u.Scheme -ne 'https' -or $u.Host -notmatch '^(www\.)?(m\.)?youtube\.com$' -or $u.AbsolutePath -ne '/watch'){throw "Invalid allowed URL: $($entry.url)"}
  $q=[System.Web.HttpUtility]::ParseQueryString($u.Query)
  if($q['v'] -notmatch '^[A-Za-z0-9_-]{11}$'){throw "Invalid video id: $($entry.url)"}
  if([string]::IsNullOrWhiteSpace([string]$entry.reason)){throw "Missing reason: $($entry.url)"}
}
$mustBlock=@(
 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
 'https://www.youtube.com/shorts/dQw4w9WgXcQ',
 'https://www.youtube.com/results?search_query=test',
 'https://youtu.be/dQw4w9WgXcQ',
 'https://www.youtube.com/watch?v=2wgg7KtzTrU&v=dQw4w9WgXcQ'
)
foreach($x in $mustBlock){
  $u=[Uri]$x
  $q=[System.Web.HttpUtility]::ParseQueryString($u.Query)
  if($u.Host -match '^(www\.|m\.)?youtube\.com$' -and $u.AbsolutePath -eq '/watch' -and $q.GetAll('v').Count -eq 1 -and $q['v'] -eq '2wgg7KtzTrU'){throw "Unsafe allow candidate: $x"}
}
Write-Host 'YOUTUBE JSON + POWERSHELL POLICY CONTRACT: PASS'
