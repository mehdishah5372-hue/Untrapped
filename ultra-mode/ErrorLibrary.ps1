# ErrorLibrary for UARD - persistent, fail-safe diagnostic memory
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

function Test-ErrorLike([string]$Text, [int]$ExitCode = 0, [int]$HttpStatus = 0) {
    if ($ExitCode -ne 0 -or $HttpStatus -ge 400) { return $true }
    $t = if ($null -eq $Text) { '' } else { [string]$Text }
    return [bool]($t -match '(?i)(?:^|\s)(error|exception|failed|failure|denied|timeout|timed out|cannot find|not found|unprocessable|conflict|redirect rejected)(?:\b|:)')
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

function Scan-ErrorOutput {
    param(
        [string]$Source='UNKNOWN', [string]$Artifact='', [string[]]$Lines,
        [int]$ExitCode=0, [int]$HttpStatus=0, [string]$Stage=''
    )
    $seen=@{}
    foreach($line in @($Lines)) {
        $text=[string]$line
        if(-not(Test-ErrorLike $text $ExitCode $HttpStatus)){continue}
        $category=Classify-ErrorText $text;$fp=Get-ErrorFingerprint $text $category
        if($seen.ContainsKey($fp)){continue};$seen[$fp]=$true
        [void](Save-ErrorEvent -Source $Source -Stream 'output-scan' -Text $text -Artifact $Artifact -ExitCode $ExitCode -HttpStatus $HttpStatus -Context ("stage=$Stage; output matched error detector"))
    }
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
    Scan-ErrorOutput @PSBoundParameters
}

function Get-ErrorLibraryRecords {
    if(-not(Test-Path -LiteralPath $ErrorLibraryPath)){return @()}
    @(Get-Content -LiteralPath $ErrorLibraryPath|ForEach-Object{try{$_|ConvertFrom-Json}catch{}})
}
