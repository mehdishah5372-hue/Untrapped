# ErrorLibrary for UARD - persistent, fail-safe diagnostic memory
# OSblocker 1.0.0 reporter contract preserved. Diagnostic selection may be smarter.
$ErrorLibraryVersion = '1.1.1'
$ErrorLibraryPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'error-library.jsonl'
$ErrorLibraryMaxRecordBytes = 32768

function Get-ErrorFingerprint([string]$Text, [string]$Category = 'UNKNOWN') {
    $n = if ($null -eq $Text) { '' } else { [string]$Text }
    $n = $n -replace '(?i)0x[0-9a-f]+', '0xHEX'
    $n = $n -replace '(?i)https?://[^\s]+', 'URL'
    $n = $n -replace '\b\d+\b', 'N'
    $n = $n -replace '\s+', ' '
    $n = $n.Trim().ToLowerInvariant()
    $payload = $Category.ToUpperInvariant() + '|' + $n
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Classify-ErrorText([string]$Text) {
    $t = if ($null -eq $Text) { '' } else { [string]$Text }
    if ($t -match '(?i)(ParserError|At line\s+\d+\s+char\s+\d+|At C:\\.*\.ps1:\d+ char:\d+|Missing\s+.*closing|Unexpected\s+token|Missing\s+\)|Missing\s+\]|Missing\s+})') { return 'PARSER' }
    if ($t -match '(?i)(Access is denied|access denied|UnauthorizedAccessException|permission denied|forbidden)') { return 'ACCESS' }
    if ($t -match '(?i)(operation timed out|request timed out|timeout occurred|timed out)') { return 'TIMEOUT' }
    if ($t -match '(?i)(The term .* is not recognized|CommandNotFoundException|cannot find the path|path.*not found)') { return 'NOT_FOUND' }
    if ($t -match '(?i)(HTTP\s+422|422\s+Unprocessable|Unprocessable Entity)') { return 'HTTP_422' }
    if ($t -match '(?i)(HTTP\s+409|409\s+Conflict)') { return 'HTTP_409' }
    if ($t -match '(?i)(HTTP\s+(?:408|425|429)|408\s+Request Timeout|425\s+Too Early|429\s+Too Many Requests|HTTP\s+5\d\d)') { return 'NETWORK_TRANSIENT' }
    if ($t -match '(?i)(redirect rejected|HTTP\s+(?:301|302|303|307|308)|301\s+Moved|302\s+Found|307\s+Temporary|308\s+Permanent)') { return 'REDIRECT' }
    if ($t -match '(?i)(Exception calling|FullyQualifiedErrorId\s*:|CategoryInfo\s*:)') { return 'ERROR' }
    if ($t -match '(?i)^\s*(?:\[[^\]]+\]\s*)?(?:ERROR|FATAL)\s*[:\-]') { return 'ERROR' }
    return 'UNKNOWN'
}

# Reporter: deliberately unchanged from the OSblocker 1.0.0 contract.
function Save-ErrorEvent {
    param(
        [string]$Source, [string]$Stream, [string]$Text, [int]$ExitCode = 0,
        [int]$HttpStatus = 0, [string]$Artifact = '', [string]$CandidateHash = '',
        [string]$PreviousCandidateHash = '', [int]$Attempt = 0, [string]$RepairAction = '',
        [string]$SyntaxResult = '', [string]$Context = ''
    )
    try {
        $category = Classify-ErrorText $Text
        $fingerprint = Get-ErrorFingerprint $Text $category
        $record = [ordered]@{
            schema = 1; library_version = $ErrorLibraryVersion; timestamp_utc = [DateTime]::UtcNow.ToString('o')
            source = $Source; stream = $Stream; artifact = $Artifact; category = $category
            fingerprint = $fingerprint; text = ([string]$Text).Substring(0, [Math]::Min(([string]$Text).Length, 12000))
            exit_code = $ExitCode; http_status = $HttpStatus; candidate_hash = $CandidateHash
            previous_candidate_hash = $PreviousCandidateHash; attempt = $Attempt; repair_action = $RepairAction
            syntax_result = $SyntaxResult; context = ([string]$Context).Substring(0, [Math]::Min(([string]$Context).Length, 12000))
        }
        $line = $record | ConvertTo-Json -Compress -Depth 8
        if ([Text.Encoding]::UTF8.GetByteCount($line) -le $ErrorLibraryMaxRecordBytes) {
            Add-Content -LiteralPath $ErrorLibraryPath -Value $line -Encoding UTF8
        }
        return $fingerprint
    } catch { return $null }
}

function Get-ErrorCount([string]$Fingerprint) {
    if (-not (Test-Path -LiteralPath $ErrorLibraryPath)) { return 0 }
    try {
        return @(Get-Content -LiteralPath $ErrorLibraryPath -ErrorAction Stop | ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { $null }
        } | Where-Object { $_ -and $_.fingerprint -eq $Fingerprint }).Count
    } catch { return 0 }
}

# Smarter checker: inspect the complete batch, rank concrete evidence, then call the
# unchanged reporter with the same fields and output-scan stream used by OSblocker 1.0.0.
function Force-DiagnosticScan {
    param(
        [string]$Source='UNKNOWN', [string]$Artifact='', [string[]]$Lines,
        [int]$ExitCode=0, [int]$HttpStatus=0, [string]$Stage='', [string]$Context=''
    )
    $all = @($Lines | ForEach-Object { [string]$_ })
    $nonEmpty = @($all | Where-Object { $_.Trim().Length -gt 0 })
    $candidates = @()

    foreach($text in $nonEmpty) {
        if(Test-ErrorLike $text 0 0) {
            $category=Classify-ErrorText $text
            $priority=3
            if($category -eq 'PARSER'){ $priority=10 }
            elseif($category -eq 'ACCESS'){ $priority=9 }
            elseif($category -eq 'TIMEOUT'){ $priority=8 }
            elseif($category -eq 'NOT_FOUND'){ $priority=7 }
            elseif($category -eq 'ERROR'){ $priority=6 }
            $candidates += [pscustomobject]@{Text=$text;Category=$category;Priority=$priority}
        }
    }

    if($HttpStatus -ge 400) {
        $httpText = if($nonEmpty.Count -gt 0){$nonEmpty -join "`r`n"}else{"HTTP status $HttpStatus"}
        $candidates += [pscustomobject]@{Text=$httpText;Category=(Classify-ErrorText ("HTTP $HttpStatus $httpText"));Priority=20}
    }
    if($ExitCode -ne 0) {
        $processText = if($nonEmpty.Count -gt 0){$nonEmpty -join "`r`n"}else{"process exited with code $ExitCode"}
        $candidates += [pscustomobject]@{Text=$processText;Category=(Classify-ErrorText $processText);Priority=21}
    }

    if($candidates.Count -eq 0){ return @() }
    $best=@($candidates | Sort-Object -Property Priority -Descending)[0]
    $fp=Save-ErrorEvent -Source $Source -Stream 'output-scan' -Text ([string]$best.Text) -Artifact $Artifact -ExitCode $ExitCode -HttpStatus $HttpStatus -Context ("stage=$Stage; force-first checker; collected_lines=$($all.Count); $Context")
    if($null -eq $fp){return @()}
    return @([pscustomobject]@{fingerprint=$fp;category=[string]$best.Category})
}

function Test-ErrorLike([string]$Text, [int]$ExitCode = 0, [int]$HttpStatus = 0) {
    if ($ExitCode -ne 0 -or $HttpStatus -ge 400) { return $true }
    $t = if ($null -eq $Text) { '' } else { [string]$Text }
    return [bool]($t -match '(?i)(ParserError|At line\s+\d+\s+char\s+\d+|At C:\\.*\.ps1:\d+ char:\d+|CommandNotFoundException|UnauthorizedAccessException|Exception calling|FullyQualifiedErrorId\s*:|CategoryInfo\s*:|^\s*(?:\[[^\]]+\]\s*)?(?:ERROR|FATAL)\s*[:\-]|redirect rejected|Access is denied|The term .* is not recognized)')
}

function Scan-ErrorOutput {
    param(
        [string]$Source='UNKNOWN', [string]$Artifact='', [string[]]$Lines,
        [int]$ExitCode=0, [int]$HttpStatus=0, [string]$Stage=''
    )
    return @(Force-DiagnosticScan -Source $Source -Artifact $Artifact -Lines $Lines -ExitCode $ExitCode -HttpStatus $HttpStatus -Stage $Stage)
}

function Scan-ErrorLike {
    param(
        [string]$Source,
        [string]$Artifact,
        [string[]]$Lines,
        [int]$ExitCode=0,
        [int]$HttpStatus=0,
        [string]$Stage=''
    )
    return @(Force-DiagnosticScan @PSBoundParameters)
}

function Get-ErrorLibraryRecords {
    if(-not(Test-Path -LiteralPath $ErrorLibraryPath)){return @()}
    @(Get-Content -LiteralPath $ErrorLibraryPath|ForEach-Object{try{$_|ConvertFrom-Json}catch{}})
}
