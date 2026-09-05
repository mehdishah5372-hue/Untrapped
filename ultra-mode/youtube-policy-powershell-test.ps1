$ErrorActionPreference='Stop'
$path=Join-Path (Split-Path -Parent $PSScriptRoot) 'youtube-allowlist.json'
if(-not(Test-Path -LiteralPath $path)){throw "Missing allowlist: $path"}
$rules=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
if([int]$rules.version -ne 1){throw 'Unsupported allowlist version'}
if($rules.policy.allowOnlyListedWatchVideos -ne $true){throw 'allowOnlyListedWatchVideos must be true'}
$entries=@($rules.allowedYouTubeUrls)
if($entries.Count -lt 1){throw 'Allowlist must contain at least one URL'}
$allowedIds=@()
foreach($entry in $entries){
  $url=[string]$entry.url
  if($url -notmatch '^https://(?:www\.|m\.)?youtube\.com/watch\?'){throw "Invalid allowed URL: $url"}
  $matches=[regex]::Matches($url,'(?:^|&)v=([^&#]+)')
  if($matches.Count -ne 1){throw "Allowed URL must contain exactly one v parameter: $url"}
  $id=$matches[0].Groups[1].Value
  if($id -notmatch '^[A-Za-z0-9_-]{11}$'){throw "Invalid video ID: $id"}
  if([string]::IsNullOrWhiteSpace([string]$entry.reason)){throw "Missing reason: $url"}
  $allowedIds+=$id
}
if($allowedIds -contains 'dQw4w9WgXcQ'){throw 'Rickroll must not be allowlisted'}
Write-Host "ALLOWLIST PATH=$path"
Write-Host "ALLOWLIST ENTRIES=$($entries.Count)"
Write-Host "ALLOWLIST VIDEO IDS=$($allowedIds -join ',')"
Write-Host 'YOUTUBE JSON + POWERSHELL POLICY CONTRACT: PASS'