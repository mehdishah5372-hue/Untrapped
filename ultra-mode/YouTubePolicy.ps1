$ErrorActionPreference = 'Stop'

function Decode-PolicyComponent([string]$Value) {
    if ($Value -match '%(?![0-9A-Fa-f]{2})') { throw 'Malformed percent encoding.' }
    [Uri]::UnescapeDataString(($Value -replace '\+', ' '))
}

function Parse-PolicyQuery([string]$RawQuery) {
    if ([string]::IsNullOrEmpty($RawQuery)) { return @() }
    @($RawQuery -split '&' | ForEach-Object {
        $i = $_.IndexOf('=')
        if ($i -lt 0) { $rk = $_; $rv = '' } else { $rk = $_.Substring(0,$i); $rv = $_.Substring($i+1) }
        [pscustomobject]@{ rawKey=$rk; rawValue=$rv; key=Decode-PolicyComponent $rk; value=Decode-PolicyComponent $rv }
    })
}

function Get-YouTubePolicyConfig($Config) {
    $ids = @()
    if ($null -ne $Config.allowedYouTubeVideoIds) { $ids = @($Config.allowedYouTubeVideoIds | ForEach-Object { [string]$_ }) }
    [pscustomobject]@{
        allowAdditionalQueryParameters = ($null -eq $Config.youtubePolicy.allowAdditionalQueryParameters -or [bool]$Config.youtubePolicy.allowAdditionalQueryParameters)
        allowedIds = [System.Collections.Generic.HashSet[string]]::new([string[]]$ids)
    }
}

function Resolve-YouTubePolicy([string]$Url,[object]$Config) {
    $default = [ordered]@{ decision='BLOCK'; reason='default-deny'; url=$Url }
    try { $uri = [Uri]$Url } catch { return [pscustomobject]($default + @{reason='invalid-url'}) }
    if ($uri.Scheme -cne 'https') { return [pscustomobject]($default + @{reason='scheme-not-https'}) }
    $hostName = $uri.Host.ToLowerInvariant().TrimEnd('.')
    if (@('youtube.com','www.youtube.com','m.youtube.com') -notcontains $hostName) { return [pscustomobject]($default + @{reason='host-not-allowlisted'}) }
    if ($uri.Port -ne 443) { return [pscustomobject]($default + @{reason='non-default-port'}) }
    if ($uri.UserInfo) { return [pscustomobject]($default + @{reason='credentials-present'}) }
    if ($uri.AbsolutePath -cne '/watch') { return [pscustomobject]($default + @{reason='path-not-watch'}) }
    if ($uri.Fragment) { return [pscustomobject]($default + @{reason='fragment-present'}) }

    try { $pairs = @(Parse-PolicyQuery $uri.Query.TrimStart('?')) } catch { return [pscustomobject]($default + @{reason='malformed-query'}) }
    $v = @($pairs | Where-Object { $_.key -ceq 'v' })
    if ($v.Count -ne 1) { return [pscustomobject]($default + @{reason=if($v.Count -eq 0){'missing-lowercase-v'}else{'duplicate-v'}}) }
    if ([string]$v[0].rawKey -cne 'v') { return [pscustomobject]($default + @{reason='encoded-parameter-name'}) }
    if ([string]$v[0].rawValue -cnotmatch '^[A-Za-z0-9_-]{11}$') { return [pscustomobject]($default + @{reason='encoded-or-invalid-video-id'}) }
    if ([string]$v[0].value -cnotmatch '^[A-Za-z0-9_-]{11}$') { return [pscustomobject]($default + @{reason='invalid-video-id'}) }

    $policy = Get-YouTubePolicyConfig $Config
    if (-not $policy.allowAdditionalQueryParameters -and $pairs.Count -ne 1) { return [pscustomobject]($default + @{reason='additional-query-parameters'}) }
    if (-not $policy.allowedIds.Contains([string]$v[0].value)) { return [pscustomobject]($default + @{reason='video-not-allowlisted'}) }
    [pscustomobject]@{ decision='ALLOW'; reason='explicit-video-allowlist'; host=$hostName; path=$uri.AbsolutePath; videoId=[string]$v[0].value; url=$Url }
}
