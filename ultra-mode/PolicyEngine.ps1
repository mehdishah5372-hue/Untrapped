$ErrorActionPreference='Stop'

function Read-PolicyConfig([string]$Path = (Join-Path $PSScriptRoot '..\youtube-allowlist.json')) {
  $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  if ([int]$cfg.version -ne 1) { throw 'Unsupported policy version.' }
  if ($cfg.policy.allowOnlyListedWatchVideos -ne $true) { throw 'Unsafe policy: allowOnlyListedWatchVideos must be true.' }
  $entries = @($cfg.allowedYouTubeUrls)
  if ($entries.Count -lt 1) { throw 'Policy must contain at least one allowed URL.' }
  $ids = @()
  foreach ($e in $entries) {
    $u = [Uri][string]$e.url
    if ($u.Scheme -cne 'https' -or $u.Host -cnotmatch '^(?:www\.|m\.)?youtube\.com$' -or $u.AbsolutePath -cne '/watch') { throw "Invalid allowed URL: $($e.url)" }
    $pairs = $u.Query.TrimStart('?') -split '&' | Where-Object { $_ -ne '' }
    $v = @($pairs | Where-Object { $_ -cmatch '^v=' })
    if ($v.Count -ne 1) { throw "Allowed URL needs exactly one lowercase v parameter: $($e.url)" }
    $id = $v[0].Substring(2)
    if ($id -cnotmatch '^[A-Za-z0-9_-]{11}$') { throw "Invalid video ID: $id" }
    if ([string]::IsNullOrWhiteSpace([string]$e.reason)) { throw "Missing reason for $id" }
    $ids += $id
  }
  [pscustomobject]@{ Config=$cfg; Entries=$entries; AllowedVideoIds=$ids }
}

function Resolve-PolicyDecision([string]$Url, $Policy) { if($null -eq $Policy){ $Policy=Read-PolicyConfig }
  $reason='Not an explicitly allowed YouTube watch URL'
  try { $u=[Uri]$Url } catch { return [pscustomobject]@{Decision='INVALID';Reason='Malformed URL';Url=$Url} }
  if ($u.Scheme -cne 'https') { return [pscustomobject]@{Decision='BLOCK';Reason='HTTPS required';Url=$Url} }
  if ($u.Host -cnotmatch '^(?:www\.|m\.)?youtube\.com$') { return [pscustomobject]@{Decision='BLOCK';Reason='Host not permitted';Url=$Url} }
  if ($u.AbsolutePath -cne '/watch') { return [pscustomobject]@{Decision='BLOCK';Reason='Only /watch URLs are permitted';Url=$Url} }
  $pairs=@($u.Query.TrimStart('?') -split '&' | Where-Object { $_ -ne '' })
  $v=@($pairs | Where-Object { $_ -cmatch '^v=' })
  if ($v.Count -ne 1) { return [pscustomobject]@{Decision='BLOCK';Reason='Exactly one lowercase v parameter required';Url=$Url} }
  $id=$v[0].Substring(2)
  if ($id -cnotmatch '^[A-Za-z0-9_-]{11}$') { return [pscustomobject]@{Decision='BLOCK';Reason='Invalid video ID';Url=$Url} }
  if (-not ($Policy.AllowedVideoIds -ccontains $id)) { return [pscustomobject]@{Decision='BLOCK';Reason='Video ID is not allowlisted';Url=$Url;VideoId=$id} }
  [pscustomobject]@{Decision='ALLOW';Reason='Explicitly allowlisted video';Url=$Url;VideoId=$id}
}
