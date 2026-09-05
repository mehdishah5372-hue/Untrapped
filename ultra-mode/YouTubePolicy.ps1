$ErrorActionPreference = 'Stop'

function New-YouTubePolicyResult([string]$Decision,[string]$Reason,[string]$Url) {
    [pscustomobject]@{ decision=$Decision; reason=$Reason; url=$Url }
}

function Decode-PolicyComponent([string]$Value) {
    if ($Value -match '%(?![0-9A-Fa-f]{2})') { throw 'Malformed percent encoding.' }
    [Uri]::UnescapeDataString(($Value -replace '\\+', ' '))
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
    $defaultDecision = 'BLOCK'
    try { $uri = [Uri]$Url } catch { return New-YouTubePolicyResult $defaultDecision 'invalid-url' $Url }
    if ($uri.Scheme -cne 'https') { return New-YouTubePolicyResult $defaultDecision 'scheme-not-https' $Url }
    $hostName = $uri.Host.ToLowerInvariant().TrimEnd('.')
    if (@('youtube.com','www.youtube.com','m.youtube.com') -notcontains $hostName) { return New-YouTubePolicyResult $defaultDecision 'host-not-allowlisted' $Url }
    if ($uri.Port -ne 443) { return New-YouTubePolicyResult $defaultDecision 'non-default-port' $Url }
    if ($uri.UserInfo) { return New-YouTubePolicyResult $defaultDecision 'credentials-present' $Url }
    if ($uri.AbsolutePath -cne '/watch') { return New-YouTubePolicyResult $defaultDecision 'path-not-watch' $Url }
    if ($uri.Fragment) { return New-YouTubePolicyResult $defaultDecision 'fragment-present' $Url }

    try { $pairs = @(Parse-PolicyQuery $uri.Query.TrimStart('?')) } catch { return New-YouTubePolicyResult $defaultDecision 'malformed-query' $Url }
    $encodedIdentity = @($pairs | Where-Object { $_.key -ieq 'v' -and $_.rawKey -cne 'v' })
    if ($encodedIdentity.Count -gt 0) { return New-YouTubePolicyResult $defaultDecision 'encoded-parameter-name' $Url }
    $v = @($pairs | Where-Object { $_.key -ceq 'v' })
    if ($v.Count -ne 1) {
        $reason = if ($v.Count -eq 0) { 'missing-lowercase-v' } else { 'duplicate-v' }
        return New-YouTubePolicyResult $defaultDecision $reason $Url
    }
    if ([string]$v[0].rawValue -cnotmatch '^[A-Za-z0-9_-]{11}$') { return New-YouTubePolicyResult $defaultDecision 'encoded-or-invalid-video-id' $Url }
    if ([string]$v[0].value -cnotmatch '^[A-Za-z0-9_-]{11}$') { return New-YouTubePolicyResult $defaultDecision 'invalid-video-id' $Url }

    $policy = Get-YouTubePolicyConfig $Config
    if (-not $policy.allowAdditionalQueryParameters -and $pairs.Count -ne 1) { return New-YouTubePolicyResult $defaultDecision 'additional-query-parameters' $Url }
    if (-not $policy.allowedIds.Contains([string]$v[0].value)) { return New-YouTubePolicyResult $defaultDecision 'video-not-allowlisted' $Url }
    [pscustomobject]@{ decision='ALLOW'; reason='explicit-video-allowlist'; host=$hostName; path=$uri.AbsolutePath; videoId=[string]$v[0].value; url=$Url }
}
