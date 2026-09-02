# UARD (Untrapped Auto-Repair Diagnostic) ver 1.0.0 - TRUE BASELINE
# Baseline 1.0.0 may be retained or upgraded; never silently downgraded.
# Performance revision: cache canonical artifacts, targeted Brave discovery, and no pointless retries.
$ErrorActionPreference = 'Stop'
$UARDName = 'UARD (Untrapped Auto-Repair Diagnostic)'
$UARDVersion = '1.0.0'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionRoot = Split-Path -Parent $Root
$Middleman = 'https://untrapped-update-middleman-production.up.railway.app'
$ArtifactBase = $Middleman + '/v1/artifact/'
$BackupRoot = Join-Path $Root 'repair-backups'
$Report = Join-Path $Root 'repair-success-latest.txt'
$log = New-Object 'System.Collections.Generic.List[string]'
$changed = $false
$failed = $false
$unknown = $false
$normAttempted = $false
$normOK = $false
$normFail = $false
$normFiles = New-Object 'System.Collections.Generic.List[string]'
$CanonicalCache = @{}
$RunStopwatch = [Diagnostics.Stopwatch]::StartNew()

function Log([string]$Message) {
    $line = '[' + (Get-Date -Format HH:mm:ss) + '] ' + $Message
    Write-Host $line
    [void]$log.Add($line)
}

function HashBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function VersionOf([byte[]]$Bytes) {
    try {
        $text = [Text.Encoding]::UTF8.GetString($Bytes)
        $m = [regex]::Match($text, '(?im)^(?:#|//).*?ver(?:sion)?\s+([0-9]+(?:\.[0-9]+){2})')
        if ($m.Success) { return [version]$m.Groups[1].Value }
    } catch {}
    return [version]'0.0.0'
}

function Normalize([byte[]]$Bytes, [string]$Name, [string]$Type) {
    if ($Type -eq 'json') { return $Bytes }
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $text = $text.TrimStart([char]0xFEFF).Trim()
    if (-not $text.StartsWith('{')) { return $Bytes }
    try { $json = $text | ConvertFrom-Json -ErrorAction Stop } catch { return $Bytes }
    if ($json -is [string]) { return $Bytes }
    $value = $null
    foreach ($key in @('powershell','script','source','code','content','text','body')) {
        if ($json.PSObject.Properties.Name -contains $key -and $json.$key -is [string]) {
            $value = [string]$json.$key
            break
        }
    }
    $language = ([string]$json.language).ToLowerInvariant()
    $encoding = ([string]$json.encoding).ToLowerInvariant()
    $explicitPowerShell = $language -in @('powershell','powershell-script','powershellscript','ps1','pwsh')
    if ($null -eq $value -and $explicitPowerShell -and ($json.PSObject.Properties.Name -contains 'commands')) {
        $items = @($json.commands)
        $value = ($items | ForEach-Object { [string]$_ }) -join "`r`n"
    }
    if ($null -eq $value) { return $Bytes }
    $script:normAttempted = $true
    try {
        if ($encoding -eq 'base64' -or ([string]$json.content_encoding).ToLowerInvariant() -eq 'base64') {
            $out = [Convert]::FromBase64String($value)
        } else {
            $out = [Text.Encoding]::UTF8.GetBytes($value)
        }
        $script:normOK = $true
        [void]$script:normFiles.Add($Name)
        Log ('NORMALIZE SUCCESS ' + $Name + ' -> native ' + $Type)
        return $out
    } catch {
        $script:normFail = $true
        Log ('NORMALIZE FAILED ' + $Name + ': ' + $_.Exception.Message)
        return $Bytes
    }
}

function Valid([hashtable]$Spec, [byte[]]$Bytes) {
    try {
        if ($Bytes.Length -lt 20) { throw 'Artifact unexpectedly small.' }
        $text = [Text.Encoding]::UTF8.GetString($Bytes)
        if ($Spec.Type -eq 'script') { [void][scriptblock]::Create($text) }
        elseif ($Spec.Type -eq 'json') { [void]($text | ConvertFrom-Json -ErrorAction Stop) }
        elseif ($Spec.Type -eq 'js' -or $Spec.Type -eq 'text') { if ($text.Length -lt 20) { throw 'Artifact unexpectedly small.' } }
        return $true
    } catch { return $false }
}

function IsTransientHttp([int]$Code) {
    return ($Code -eq 408 -or $Code -eq 429 -or $Code -ge 500)
}

function DownloadCanonical([hashtable]$Spec) {
    if ($CanonicalCache.ContainsKey($Spec.Remote)) {
        Log ('CACHE HIT ' + $Spec.Remote)
        return $CanonicalCache[$Spec.Remote]
    }

    $url = $ArtifactBase + $Spec.Remote + '?cb=' + [DateTime]::UtcNow.Ticks
    Log ('DOWNLOAD START ' + $Spec.Remote)
    $maxAttempts = 4
    $bytes = $null
    $expected = $null
    $lastError = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $request = $null
        $response = $null
        $stream = $null
        $memory = $null
        try {
            $request = [Net.HttpWebRequest]::Create($url)
            $request.Method = 'GET'
            $request.Timeout = 45000
            $request.ReadWriteTimeout = 45000
            $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
            $request.UserAgent = 'Untrapped-UARD/1.0'
            $response = [Net.HttpWebResponse]$request.GetResponse()
            $code = [int]$response.StatusCode
            if ($code -ne 200) {
                $lastError = 'Middleman HTTP ' + $code
                $transient = IsTransientHttp $code
                if (-not $transient) { throw $lastError }
                throw $lastError
            }

            # Capture headers BEFORE disposing the response. This fixes the old verification race.
            $expected = [string]$response.Headers['X-Untrapped-SHA256']
            $stream = $response.GetResponseStream()
            $memory = New-Object IO.MemoryStream
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        } catch {
            $lastError = $_.Exception.Message
            $retry = $true
            if ($lastError -match 'Middleman HTTP (4\d\d)') {
                $codeMatch = [regex]::Match($lastError, 'Middleman HTTP (\d+)')
                if ($codeMatch.Success -and -not (IsTransientHttp ([int]$codeMatch.Groups[1].Value))) { $retry = $false }
            }
            if (-not $retry -or $attempt -eq $maxAttempts) { throw $lastError }
            Log ('TRANSIENT RETRY ' + $Spec.Remote + ' ' + $attempt + '/' + $maxAttempts + ': ' + $lastError)
            Start-Sleep -Milliseconds (750 * $attempt)
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($memory) { $memory.Dispose() }
            if ($response) { $response.Dispose() }
        }
        if ($null -ne $bytes) { break }
    }

    $bytes = Normalize $bytes $Spec.Remote $Spec.Type
    if (-not (Valid $Spec $bytes)) { throw ('Artifact validation failed: ' + $Spec.Remote + ' (non-retryable)') }
    if (-not [string]::IsNullOrWhiteSpace($expected)) {
        $actual = HashBytes $bytes
        if ($expected.ToLowerInvariant() -ne $actual) { throw ('Middleman SHA-256 mismatch: ' + $Spec.Remote + ' (non-retryable)') }
    } else {
        throw ('Middleman did not provide X-Untrapped-SHA256 for ' + $Spec.Remote + ' (non-retryable)')
    }

    $CanonicalCache[$Spec.Remote] = $bytes
    Log ('DOWNLOAD OK ' + $Spec.Remote + ' SHA256=' + (HashBytes $bytes))
    return $bytes
}

function GetCanonical([hashtable]$Spec) {
    try { return DownloadCanonical $Spec }
    catch { throw }
}

function RepairOne([string]$Base, [hashtable]$Spec, [string]$Label, [byte[]]$Remote) {
    $path = Join-Path $Base $Spec.Rel
    Log ('CHECK ' + $Label + '/' + $Spec.Rel)
    if ($null -eq $Remote) {
        if (Test-Path -LiteralPath $path) {
            $script:unknown = $true
            Log ('UNVERIFIED ' + $Label + '/' + $Spec.Rel + '; canonical unavailable; local copy retained.')
        } else {
            $script:failed = $true
            Log ('FAIL ' + $Label + '/' + $Spec.Rel + '; required artifact missing and canonical unavailable.')
        }
        return
    }

    $remoteHash = HashBytes $Remote
    $same = $false
    if (Test-Path -LiteralPath $path) {
        try { $same = (HashBytes ([IO.File]::ReadAllBytes($path))) -eq $remoteHash } catch {}
    }
    if ($same) { Log ('CURRENT ' + $Label + '/' + $Spec.Rel); return }

    Log ('UPDATE NEEDED ' + $Label + '/' + $Spec.Rel)
    $tmp = $null
    try {
        if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null }
        if (Test-Path -LiteralPath $path) {
            $safeLabel = $Label.Replace('/','_')
            $safeRel = $Spec.Rel.Replace('/','_')
            $backup = Join-Path $BackupRoot ((Get-Date -Format yyyyMMdd-HHmmssfff) + '-' + $safeLabel + '-' + $safeRel + '.bak')
            Copy-Item -LiteralPath $path -Destination $backup -Force
            Log ('BACKUP ' + $backup)
        }
        $parent = Split-Path $path -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $tmp = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllBytes($tmp, $Remote)
        $tmpBytes = [IO.File]::ReadAllBytes($tmp)
        if ((HashBytes $tmpBytes) -ne $remoteHash) { throw 'Pre-install SHA-256 mismatch.' }
        if (-not (Valid $Spec $tmpBytes)) { throw 'Pre-install validation failed.' }
        Move-Item -LiteralPath $tmp -Destination $path -Force
        $tmp = $null
        if ((HashBytes ([IO.File]::ReadAllBytes($path))) -ne $remoteHash) { throw 'Post-install SHA-256 mismatch.' }
        Log ('REPAIRED+VERIFIED ' + $Label + '/' + $Spec.Rel)
        $script:changed = $true
    } catch {
        $script:failed = $true
        Log ('FAIL ' + $Label + '/' + $Spec.Rel + ': ' + $_.Exception.Message)
        if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function TestUntrappedManifest([string]$ManifestPath) {
    try {
        $obj = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        return ([string]$obj.name -eq 'Untrapped')
    } catch { return $false }
}

function FindBraveCopies {
    $found = New-Object 'System.Collections.Generic.List[string]'

    # Fast path: actual Brave extension stores only. This avoids crawling unrelated user files.
    $userData = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
    $extensionStores = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $userData) {
        [void]$extensionStores.Add((Join-Path $userData 'Default\Extensions'))
        try {
            foreach ($profile in @(Get-ChildItem -LiteralPath $userData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
                [void]$extensionStores.Add((Join-Path $profile.FullName 'Extensions'))
            }
        } catch {}
    }
    if (Test-Path -LiteralPath $ExtensionRoot) { [void]$extensionStores.Add($ExtensionRoot) }

    foreach ($store in @($extensionStores | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $store)) { continue }
        try {
            foreach ($manifest in @(Get-ChildItem -LiteralPath $store -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue)) {
                if (TestUntrappedManifest $manifest.FullName) { [void]$found.Add($manifest.Directory.FullName) }
            }
        } catch {}
    }

    # Command-line loaded unpacked extensions are cheap to inspect and may not live in User Data.
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^brave' -and $_.CommandLine -match '(?i)--load-extension=' })) {
        foreach ($match in [regex]::Matches([string]$process.CommandLine, '--load-extension=(?:"([^"]+)"|([^\s]+))')) {
            $dir = $match.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $match.Groups[2].Value }
            if (Test-Path -LiteralPath $dir) {
                $manifest = Join-Path $dir 'manifest.json'
                if ((Test-Path -LiteralPath $manifest) -and (TestUntrappedManifest $manifest)) {
                    try { [void]$found.Add((Resolve-Path -LiteralPath $dir).Path) } catch {}
                }
            }
        }
    }

    # Full fallback retained for completeness, but only reached if the fast path found nothing.
    if ($found.Count -eq 0) {
        Log 'BRAVE FAST SCAN FOUND 0; running retained broad fallback scan.'
        foreach ($base in @($ExtensionRoot,(Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:USERPROFILE 'Documents'),(Join-Path $env:USERPROFILE 'Downloads'))) {
            if (-not (Test-Path -LiteralPath $base)) { continue }
            try {
                foreach ($manifest in @(Get-ChildItem -LiteralPath $base -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 250)) {
                    if (TestUntrappedManifest $manifest.FullName) { [void]$found.Add($manifest.Directory.FullName) }
                }
            } catch {}
        }
    }
    return @($found | Sort-Object -Unique)
}

function RestartOwnedProcesses {
    if (-not $changed) { Log 'RESTART NOT NEEDED'; return }
    Log 'RESTART Checking Untrapped-owned packet/control processes only.'
    foreach ($pattern in @('*packet-filter.ps1*','*ultra-mode.ps1*')) {
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like $pattern })) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            Log ('STOP PID ' + $process.ProcessId)
        }
    }
    Start-Sleep -Milliseconds 500
    foreach ($name in @('packet-filter.ps1','ultra-mode.ps1')) {
        $path = Join-Path $Root $name
        if (Test-Path -LiteralPath $path) {
            Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$path) -WorkingDirectory $Root -Verb RunAs -WindowStyle Hidden -ErrorAction SilentlyContinue
            Log ('START ' + $name)
        }
    }
    Log 'RESTART COMPLETE'
}

$Core = @(
    @{Remote='ultra-mode/INSTALL-PACKET-FILTER.ps1';Rel='INSTALL-PACKET-FILTER.ps1';Type='script'},
    @{Remote='ultra-mode/INSTALL-ULTRA-MODE.ps1';Rel='INSTALL-ULTRA-MODE.ps1';Type='script'},
    @{Remote='ultra-mode/config.json';Rel='config.json';Type='json'},
    @{Remote='ultra-mode/create-override.ps1';Rel='create-override.ps1';Type='script'},
    @{Remote='ultra-mode/generate-keys.ps1';Rel='generate-keys.ps1';Type='script'},
    @{Remote='ultra-mode/packet-filter.ps1';Rel='packet-filter.ps1';Type='script'},
    @{Remote='ultra-mode/self-repair.ps1';Rel='self-repair.ps1';Type='script'},
    @{Remote='ultra-mode/status-untrapped.ps1';Rel='status-untrapped.ps1';Type='script'},
    @{Remote='ultra-mode/test-untrapped.ps1';Rel='test-untrapped.ps1';Type='script'},
    @{Remote='ultra-mode/ultra-mode.ps1';Rel='ultra-mode.ps1';Type='script'},
    @{Remote='ultra-mode/verify-override.ps1';Rel='verify-override.ps1';Type='script'}
)
$Ext = @(
    @{Remote='manifest.json';Rel='manifest.json';Type='json'},
    @{Remote='background.js';Rel='background.js';Type='js'},
    @{Remote='content.js';Rel='content.js';Type='js'},
    @{Remote='popup.html';Rel='popup.html';Type='text'},
    @{Remote='popup.js';Rel='popup.js';Type='js'},
    @{Remote='bootstrap.bundle.min.js';Rel='bootstrap.bundle.min.js';Type='js'},
    @{Remote='assets/untrapped.png';Rel='assets/untrapped.png';Type='binary'},
    @{Remote='assets/untrapped.svg';Rel='assets/untrapped.svg';Type='binary'}
)

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Log ('=== ' + $UARDName + ' ver ' + $UARDVersion + ' SELF-REPAIR BEGIN ===')
    Log 'TRUE BASELINE 1.0.0: retained or upgraded, never removed.'
    Log 'MIDDLEMAN: Railway update broker is the comparison/update source.'
    Log 'PERFORMANCE: each canonical artifact is fetched, normalized, validated and SHA-checked once per run.'
    Log 'RETRY POLICY: only transient transport/HTTP failures retry; deterministic failures stop immediately.'

    $brave = @(FindBraveCopies)
    if ($brave.Count -gt 0) { Log ('BRAVE COPIES DETECTED: ' + $brave.Count) }
    else { Log 'BRAVE COPIES DETECTED: 0 (informational; not a repair failure)' }

    $allSpecs = @($Core + $Ext)
    $uniqueSpecs = @($allSpecs | Group-Object Remote | ForEach-Object { $_.Group[0] })
    Log ('CANONICAL PLAN: ' + $uniqueSpecs.Count + ' unique artifacts; local copies will reuse cache.')

    # Canonical acquisition happens once. No artifact is downloaded again for every Brave copy.
    foreach ($spec in $uniqueSpecs) {
        try { [void](GetCanonical $spec) }
        catch {
            if ($spec.Remote -match '^ultra-mode/' -and (Test-Path -LiteralPath (Join-Path $Root $spec.Rel))) {
                $script:unknown = $true
                Log ('CANONICAL UNVERIFIED ' + $spec.Remote + '; local copy retained: ' + $_.Exception.Message)
            } elseif ($spec.Remote -notmatch '^ultra-mode/' -and $brave.Count -eq 0) {
                Log ('EXTENSION CANONICAL SKIPPED ' + $spec.Remote + '; no Brave copy requires it.')
            } else {
                $script:unknown = $true
                Log ('CANONICAL UNVERIFIED ' + $spec.Remote + ': ' + $_.Exception.Message)
            }
        }
    }

    foreach ($spec in $Core) {
        $remote = $null
        if ($CanonicalCache.ContainsKey($spec.Remote)) { $remote = $CanonicalCache[$spec.Remote] }
        RepairOne $Root $spec 'CORE' $remote
    }

    foreach ($copy in $brave) {
        Log ('EXTENSION REPAIR TARGET ' + $copy)
        foreach ($spec in $Ext) {
            $remote = $null
            if ($CanonicalCache.ContainsKey($spec.Remote)) { $remote = $CanonicalCache[$spec.Remote] }
            RepairOne $copy $spec 'BRAVE' $remote
        }
    }

    RestartOwnedProcesses

    if ($normAttempted) {
        if ($normFail) { Log 'NORMALIZATION RESULT: UNSUCCESSFUL' }
        else { Log 'NORMALIZATION RESULT: SUCCESSFUL' }
    } else { Log 'NORMALIZATION RESULT: NOT NEEDED' }

    if ($failed) {
        Log 'DIAGNOSIS: REPAIR INCOMPLETE'
    } elseif ($unknown) {
        Log 'DIAGNOSIS: VERIFICATION INCOMPLETE'
    } elseif ($changed) {
        Log 'DIAGNOSIS: REPAIR SUCCESS'
    } else {
        Log 'DIAGNOSIS: NO REPAIR REQUIRED'
    }
} catch {
    $failed = $true
    Log ('FATAL: ' + $_.Exception.Message)
    Log 'DIAGNOSIS: REPAIR INCOMPLETE'
} finally {
    $RunStopwatch.Stop()
    $elapsed = [math]::Round($RunStopwatch.Elapsed.TotalSeconds,2)
    Log ('[PERF] TOTAL ELAPSED: ' + $elapsed + 's')
    Log ('[PERF] CANONICAL CACHE ENTRIES: ' + $CanonicalCache.Count)
    Log ('[PERF] TRANSIENT RETRIES ARE LIMITED; DETERMINISTIC FAILURES ARE NOT RETRIED.')

    try {
        $reportLines = @(
            $UARDName + ' ver ' + $UARDVersion,
            'TRUE BASELINE 1.0.0',
            'Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            '',
            'DIAGNOSIS: ' + $(if ($failed) { 'REPAIR INCOMPLETE' } elseif ($unknown) { 'VERIFICATION INCOMPLETE' } elseif ($changed) { 'REPAIR SUCCESS' } else { 'NO REPAIR REQUIRED' }),
            'Brave copies detected: ' + $brave.Count,
            'Canonical artifacts cached: ' + $CanonicalCache.Count,
            'Normalization attempted: ' + $normAttempted,
            'Normalization successful: ' + $normOK,
            'Normalization failed: ' + $normFail,
            'Elapsed seconds: ' + $elapsed,
            '',
            '=== DETAILED LOG ==='
        ) + @($log)
        Set-Content -LiteralPath $Report -Value $reportLines -Encoding UTF8
        if ($changed -or $failed -or $unknown) { Start-Process notepad.exe -ArgumentList @($Report) -ErrorAction SilentlyContinue }
    } catch {}
}

if ($failed) { exit 1 }
if ($unknown) { exit 2 }
exit 0
