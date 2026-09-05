$ErrorActionPreference='Stop'
Set-Location $env:GITHUB_WORKSPACE
$path=Join-Path $env:GITHUB_WORKSPACE 'youtube-allowlist.json'
if(-not(Test-Path -LiteralPath $path)){throw "Missing allowlist: $path"}
$raw=Get-Content -LiteralPath $path -Raw
$rules=$raw|ConvertFrom-Json
if([int]$rules.version -ne 1){throw 'Unsupported allowlist version'}
if([bool]$rules.policy.allowOnlyListedWatchVideos -ne $true){throw 'allowOnlyListedWatchVideos must be true'}
$entries=@($rules.allowedYouTubeUrls)
if($entries.Count -lt 1){throw 'Allowlist must contain at least one URL'}
foreach($entry in $entries){
  $url=[string]$entry.url
  if($url -notmatch '^https://(www\.|m\.)?youtube\.com/watch\?'){throw "Invalid allowed URL: $url"}
  $vm=[regex]::Matches($url,'(?:^|&)v=([^&#]+)')
  if($vm.Count -ne 1){throw "URL must have exactly one v parameter: $url"}
  if($vm[0].Groups[1].Value -notmatch '^[A-Za-z0-9_-]{11}$'){throw "Invalid video ID"}
  if([string]::IsNullOrWhiteSpace([string]$entry.reason)){throw "Missing reason: $url"}
}
if(@($entries|Where-Object { [string]$_.url -match 'dQw4w9WgXcQ' }).Count -gt 0){throw 'Rickroll is allowlisted'}
Write-Host 'YOUTUBE JSON + POWERSHELL POLICY CONTRACT: PASS'