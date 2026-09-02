# UARD (Untrapped Auto-Repair Diagnostic) ver 1.0.0 - TRUE BASELINE
# Baseline 1.0.0 may be retained or upgraded; never silently downgraded.
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
        if ($json.PSObject.Properties.Name -contains $key) {
            if ($json.$key -is [string]) { $value = [string]$json.$key; break }
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
    } catch {
        return $false
    }
}

function DownloadBytes([hashtable]$Spec) {
    $url = $ArtifactBase + $Spec.Remote + '?cb=' + [DateTime]::UtcNow.Ticks
    Log ('DOWNLOAD START ' + $Spec.Remote)
    $request = [Net.HttpWebRequest]::Create($url)
    $request.Method = 'GET'
    $request.Timeout = 45000
    $request.ReadWriteTimeout = 45000
    $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $request.UserAgent = 'Untrapped-UARD/1.0'
    $response = $null
    $stream = $null
    $memory = $null
    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { throw ('Middleman HTTP ' + [int]$response.StatusCode) }
        $stream = $response.GetResponseStream()
        $memory = New-Object IO.MemoryStream
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($memory) { $memory.Dispose() }
        if ($response) { $response.Dispose() }
    }
    $bytes = Normalize $bytes $Spec.Remote $Spec.Type
    if (-not (Valid $Spec $bytes)) { throw ('Artifact validation failed: ' + $Spec.Remote) }
    $expected = [string]$response.Headers['X-Untrapped-SHA256']
    if (-not [string]::IsNullOrWhiteSpace($expected)) {
        if ($expected.ToLowerInvariant() -ne (HashBytes $bytes)) { throw ('Middleman SHA-256 mismatch: ' + $Spec.Remote) }
    }
    Log ('DOWNLOAD OK ' + $Spec.Remote + ' SHA256=' + (HashBytes $bytes))
    return $bytes
}

function RepairOne([string]$Base, [hashtable]$Spec, [string]$Label) {
    $path = Join-Path $Base $Spec.Rel
    Log ('CHECK ' + $Label + '/' + $Spec.Rel)
    $remote = $null
    $lastError = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $remote = DownloadBytes $Spec
            break
        } catch {
            $lastError = $_.Exception.Message
            Log ('RETRY ' + $Spec.Remote + ' ' + $attempt + '/20: ' + $lastError)
            if ($attempt -lt 20) { Start-Sleep -Milliseconds 1500 }
        }
    }
    if ($null -eq $remote) {
        if (Test-Path -LiteralPath $path) {
            $script:unknown = $true
            Log ('UNVERIFIED ' + $Label + '/' + $Spec.Rel + '; local copy retained. Last error: ' + $lastError)
        } else {
            $script:failed = $true
            Log ('FAIL ' + $Label + '/' + $Spec.Rel + '; required artifact missing. Last error: ' + $lastError)
        }
        return
    }
    $same = $false
    if (Test-Path -LiteralPath $path) {
        try { $same = (HashBytes ([IO.File]::ReadAllBytes($path))) -eq (HashBytes $remote) } catch {}
    }
    if ($same) { Log ('CURRENT ' + $Label + '/' + $Spec.Rel); return }
    Log ('UPDATE NEEDED ' + $Label + '/' + $Spec.Rel)
    $tmp = $null
    try {
        if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null }
        if (Test-Path -LiteralPath $path) {
            $backup = Join-Path $BackupRoot ((Get-Date -Format yyyyMMdd-HHmmss) + '-' + $Label.Replace('/','_') + '-' + $Spec.Rel.Replace('/','_') + '.bak')
            Copy-Item -LiteralPath $path -Destination $backup -Force
            Log ('BACKUP ' + $backup)
        }
        $parent = Split-Path $path -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $tmp = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllBytes($tmp, $remote)
        if ((HashBytes ([IO.File]::ReadAllBytes($tmp))) -ne (HashBytes $remote)) { throw 'Pre-install SHA-256 mismatch.' }
        if (-not (Valid $Spec ([IO.File]::ReadAllBytes($tmp)))) { throw 'Pre-install validation failed.' }
        Move-Item -LiteralPath $tmp -Destination $path -Force
        $tmp = $null
        if ((HashBytes ([IO.File]::ReadAllBytes($path))) -ne (HashBytes $remote)) { throw 'Post-install SHA-256 mismatch.' }
        Log ('REPAIRED+VERIFIED ' + $Label + '/' + $Spec.Rel)
        $script:changed = $true
    } catch {
        $script:failed = $true
        Log ('FAIL ' + $Label + '/' + $Spec.Rel + ': ' + $_.Exception.Message)
        if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function FindBraveCopies {
    $found = New-Object 'System.Collections.Generic.List[string]'
    $roots = @()
    if (Test-Path $ExtensionRoot) { $roots += $ExtensionRoot }
    $roots += @(
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )
    foreach ($base in $roots) {
        if (-not (Test-Path $base)) { continue }
        try {
            $manifests = Get-ChildItem -LiteralPath $base -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 100
            foreach ($manifest in @($manifests)) {
                try {
                    $obj = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
                    if ([string]$obj.name -eq 'Untrapped') { [void]$found.Add($manifest.Directory.FullName) }
                } catch {}
            }
        } catch {}
    }
    $userData = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
    if (Test-Path $userData) {
        try {
            $manifests = Get-ChildItem -LiteralPath $userData -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 500
            foreach ($manifest in @($manifests)) {
                try {
                    $obj = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
                    if ([string]$obj.name -eq 'Untrapped') { [void]$found.Add($manifest.Directory.FullName) }
                } catch {}
            }
        } catch {}
    }
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^brave' -and $_.CommandLine -match '(?i)--load-extension=' })) {
        foreach ($match in [regex]::Matches([string]$process.CommandLine, '--load-extension=(?:"([^"]+)"|([^\s]+))')) {
            $dir = $match.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $match.Groups[2].Value }
            if (Test-Path $dir) {
                $manifest = Join-Path $dir 'manifest.json'
                if (Test-Path $manifest) {
                    try { if ([string]((Get-Content $manifest -Raw | ConvertFrom-Json).name) -eq 'Untrapped') { [void]$found.Add((Resolve-Path $dir).Path) } } catch {}
                }
            }
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
    Start-Sleep -Milliseconds 800
    foreach ($name in @('packet-filter.ps1','ultra-mode.ps1')) {
        $path = Join-Path $Root $name
        if (Test-Path $path) {
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
    $brave = @(FindBraveCopies)
    if ($brave.Count -gt 0) { Log ('BRAVE COPIES DETECTED: ' + $brave.Count) }
    else { Log 'BRAVE UNTRAPPED COPY: NOT FOUND; informational only.' }
    foreach ($spec in $Ext) { RepairOne $ExtensionRoot $spec 'extension-source' }
    foreach ($spec in $Core) { RepairOne $Root $spec 'ultra-mode' }
    foreach ($copy in $brave) { foreach ($spec in $Ext) { RepairOne $copy $spec 'brave-extension' } }
    foreach ($native in @('WinDivert.dll','WinDivert64.sys')) {
        $nativePath = Join-Path $Root $native
        if (Test-Path $nativePath) { Log ('NATIVE OK ' + $native) }
        else { $failed = $true; Log ('FAIL MISSING ' + $native) }
    }
    if ($normFail) { $normalization = 'UNSUCCESSFUL' }
    elseif ($normOK) { $normalization = 'SUCCESSFUL' }
    else { $normalization = 'NOT NEEDED' }
    Log ('NORMALIZATION RESULT: ' + $normalization)
    if ($normFiles.Count -gt 0) { Log ('NORMALIZED FILES: ' + ($normFiles -join ', ')) }
    RestartOwnedProcesses
    if ($failed) { $diagnosis = 'REPAIR INCOMPLETE' }
    elseif ($unknown) { $diagnosis = 'VERIFICATION INCOMPLETE' }
    elseif ($changed) { $diagnosis = 'REPAIR SUCCESS' }
    else { $diagnosis = 'NO REPAIR REQUIRED' }
    [void]$log.Add('')
    [void]$log.Add('[DIAGNOSIS] ' + $diagnosis)
    [void]$log.Add('IDENTITY: ' + $UARDName + ' ver ' + $UARDVersion)
    [void]$log.Add('TRUE BASELINE: 1.0.0 - RETAINED/UPGRADED, NEVER REMOVED')
    [void]$log.Add('MIDDLEMAN: Railway update broker backed by canonical GitHub main')
    [void]$log.Add('BRAVE COPIES DETECTED: ' + $brave.Count)
    [void]$log.Add('NORMALIZATION: ' + $normalization)
    [void]$log.Add('PROTECTED: Firewall/WFP/DNS/routes/Hosts/proxy/adapters/VPN/override policy are never modified.')
    $log | Set-Content -LiteralPath $Report -Encoding UTF8
    Log '=== UARD SELF-REPAIR END ==='
    if ($changed -or $failed -or $unknown) { Start-Process notepad.exe -ArgumentList @($Report) -ErrorAction SilentlyContinue }
    if ($failed) { exit 1 }
    if ($unknown) { exit 2 }
    exit 0
} catch {
    Log ('FAIL FATAL ' + $_.Exception.Message)
    @($UARDName + ' ver ' + $UARDVersion,'UARD FAILURE',$_.Exception.Message,'TRUE BASELINE: 1.0.0') | Set-Content -LiteralPath $Report -Encoding UTF8
    Start-Process notepad.exe -ArgumentList @($Report) -ErrorAction SilentlyContinue
    exit 1
}
