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
    if ($t -match '(?i)parse|parser|syntax|unexpected token|missing.*[\)\]\}]|term.*not recognized') { return 'PARSER' }
    if ($t -match '(?i)access denied|unauthorized|forbidden|permission') { return 'ACCESS' }
    if ($t -match '(?i)timeout|timed out') { return 'TIMEOUT' }
    if ($t -match '(?i)not found|cannot find|404') { return 'NOT_FOUND' }
    if ($t -match '(?i)422|unprocessable') { return 'HTTP_422' }
    if ($t -match '(?i)409|conflict') { return 'HTTP_409' }
    if ($t -match '(?i)408|425|429|5\d\d|transient|retry') { return 'NETWORK_TRANSIENT' }
    if ($t -match '(?i)redirect|301|302|307|308') { return 'REDIRECT' }
    if ($t -match '(?i)exception|error|failed|failure') { return 'ERROR' }
    if ($t -match '(?i)warning|warn') { return 'WARNING' }
    return 'UNKNOWN'
}

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

# Smarter checker only. The reporter below remains the OSblocker 1.0.0 contract.
# The checker deliberately separates evidence collection from diagnosis so narrative text
# cannot masquerade as an error, while objective process/HTTP failure evidence preserves
# the legacy per-line reporting contract.
$ErrorLibraryCheckerVersion = '2.0.0'
$ErrorLibraryGlobalAttemptCeiling = 256
$ErrorLibraryRepeatedFingerprintCeiling = 20

function Get-CheckerEvidenceScore([string]$Text) {
    $t = if ($null -eq $Text) { '' } else { [string]$Text }
    if ([string]::IsNullOrWhiteSpace($t)) { return 0 }
    $strong = 0
    if ($t -match '(?i)ParserError|PSSecurityException|CommandNotFoundException|UnauthorizedAccessException|FullyQualifiedErrorId\s*:|CategoryInfo\s*:') { $strong = [Math]::Max($strong,100) }
    if ($t -match '(?i)At\s+(?:[A-Z]:\\|\\\\).+\.ps1:\d+\s+char:\d+') { $strong = [Math]::Max($strong,90) }
    if ($t -match '(?i)\b(?:Missing|Unexpected|Incomplete)\b.{0,100}\b(?:token|closing|parenthesis|brace|bracket|string)') { $strong = [Math]::Max($strong,80) }
    if ($t -match '(?i)The term .+ is not recognized as the name of (?:a )?(?:cmdlet|function|script file|operable program)') { $strong = [Math]::Max($strong,80) }
    if ($t -match '(?i)(?:Access is denied|access denied|permission denied|unauthorized)') { $strong = [Math]::Max($strong,80) }
    if ($t -match '(?i)(?:cannot find the path|path .{0,60} does not exist|ItemNotFoundException)') { $strong = [Math]::Max($strong,80) }
    if ($t -match '(?i)^\s*\[(?:ERROR|FATAL)\]') { $strong = [Math]::Max($strong,80) }
    if ($t -match '(?i)^\s*(?:\[[^\]]+\]\s*)?(?:ERROR|FATAL)\s*[:\-]') { $strong = [Math]::Max($strong,70) }
    if ($t -match '(?i)\b(?:timed out|timeout occurred|request timed out)\b') { $strong = [Math]::Max($strong,70) }
    if ($t -match '(?i)redirect\s+rejected') { $strong = [Math]::Max($strong,70) }
    if ($t -match '(?i)\bHTTP\s+[45]\d\d\b') { $strong = [Math]::Max($strong,70) }
    $narrative = $t -match '(?i)\b(?:pass|passed|success|successful|complete|completed|test|fixture|regression|diagnostic|narrative|example|intentionally|expected|verifies|reproduced|coverage|historical)\b'
    if ($narrative -and $t -match '(?i)\bHTTP\s+[45]\d\d\b') { return 0 }
    if ($narrative -and $strong -lt 70) { return 0 }
    if ($strong -ge 70) { return $strong }
    if ($t -match '(?i)\b(?:error|exception|failed|failure|denied|cannot find|not found|unprocessable|conflict|redirect rejected)\b') { return 15 }
    return 0
}
function Test-ConcreteDiagnosticEvidence([string]$Text) {
    return ((Get-CheckerEvidenceScore $Text) -ge 50)
}

function Force-DiagnosticScan {
    param(
        [string]$Source='UNKNOWN', [string]$Artifact='', [string[]]$Lines,
        [int]$ExitCode=0, [int]$HttpStatus=0, [string]$Stage='', [string]$Context=''
    )
    $all=@($Lines|ForEach-Object{[string]$_})
    $nonEmpty=@($all|Where-Object{$_.Trim().Length -gt 0})
    $seen=@{}
    $selected=@()

    # Objective failure evidence is authoritative. This intentionally preserves the
    # baseline's reporter behaviour: when the process/HTTP request failed, every
    # non-empty captured line remains reportable rather than silently disappearing.
    if($ExitCode -ne 0 -or $HttpStatus -ge 400){
        $selected=$nonEmpty
    } else {
        # Force-first: inspect the entire batch before selecting anything. Strong,
        # structured diagnostics win; narrative references to errors do not.
        $ranked=@($nonEmpty|ForEach-Object{
            [pscustomobject]@{Text=$_;Score=(Get-CheckerEvidenceScore $_)}
        }|Where-Object{$_.Score -ge 50}|Sort-Object Score -Descending)
        $selected=@($ranked|ForEach-Object{$_.Text})
    }

    foreach($text in $selected){
        $category=Classify-ErrorText $text
        $fp=Get-ErrorFingerprint $text $category
        if($seen.ContainsKey($fp)){continue}
        $seen[$fp]=$true
        [void](Save-ErrorEvent -Source $Source -Stream 'output-scan' -Text $text -Artifact $Artifact -ExitCode $ExitCode -HttpStatus $HttpStatus -Context ("stage=$Stage; output matched error detector"))
    }
    return @($seen.Keys|ForEach-Object{[pscustomobject]@{fingerprint=$_}})
}

function Test-ErrorLike([string]$Text, [int]$ExitCode = 0, [int]$HttpStatus = 0) {
    if ($ExitCode -ne 0 -or $HttpStatus -ge 400) { return $true }
    return (Test-ConcreteDiagnosticEvidence $Text)
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
