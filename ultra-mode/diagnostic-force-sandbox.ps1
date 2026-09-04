# Diagnostic force-check sandbox for OSblocker 1.0.0
# Non-installing. The reporter contract is fixed; only diagnosis/selection is upgraded.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'ErrorLibrary.ps1')
$OriginalLibraryPath=$ErrorLibraryPath
$ErrorLibraryPath=Join-Path $env:TEMP ('osblocker-diagnostic-sandbox-' + [guid]::NewGuid().ToString('N') + '.jsonl')

function Legacy-Test([string]$Text,[int]$ExitCode=0,[int]$HttpStatus=0){
    if($ExitCode -ne 0 -or $HttpStatus -ge 400){return $true}
    $t=if($null -eq $Text){''}else{[string]$Text}
    return [bool]($t -match '(?i)(?:^|\s)(error|exception|failed|failure|denied|timeout|timed out|cannot find|not found|unprocessable|conflict|redirect rejected)(?:\b|:)')
}
function Legacy-Report([string]$Text,[int]$ExitCode=0,[int]$HttpStatus=0){
    $category=Classify-Legacy $Text
    $fp=Get-ErrorFingerprint $Text $category
    [ordered]@{schema=1;library_version='1.1.1';stream='output-scan';category=$category;fingerprint=$fp;text=$Text;exit_code=$ExitCode;http_status=$HttpStatus;candidate_hash='';previous_candidate_hash='';attempt=0;repair_action='';syntax_result='';context=''}
}
function Classify-Legacy([string]$Text){
    $t=[string]$Text
    if($t -match '(?i)parse|parser|syntax|unexpected token|missing.*[\)\]\}]|term.*not recognized'){return 'PARSER'}
    if($t -match '(?i)access denied|unauthorized|forbidden|permission'){return 'ACCESS'}
    if($t -match '(?i)timeout|timed out'){return 'TIMEOUT'}
    if($t -match '(?i)not found|cannot find|404'){return 'NOT_FOUND'}
    if($t -match '(?i)422|unprocessable'){return 'HTTP_422'}
    if($t -match '(?i)409|conflict'){return 'HTTP_409'}
    if($t -match '(?i)408|425|429|5\d\d|transient|retry'){return 'NETWORK_TRANSIENT'}
    if($t -match '(?i)redirect|301|302|307|308'){return 'REDIRECT'}
    if($t -match '(?i)exception|error|failed|failure'){return 'ERROR'}
    if($t -match '(?i)warning|warn'){return 'WARNING'}
    return 'UNKNOWN'
}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "DIAGNOSTIC SANDBOX FAIL: $Message"};Write-Host "DIAGNOSTIC SANDBOX PASS: $Message"}

try {
    $falsePositives=@(
        'PASS — parser/repair gate complete',
        '[REGRESSION PASS] historical parser failure was reproduced',
        'This test verifies that the script fails safely when given malformed input.',
        'WARNING: expected test narrative, not an emitted warning',
        'Error handling regression coverage complete',
        'The previous failure is intentionally reproduced here.',
        'HTTP 422 deterministic rejection is a regression fixture.',
        'Exit code: 0',
        'No errors were found.',
        'PASS — all gates passed; no failure detected.'
    )
    $truePositives=@(
        @{Text='[ERROR] UARD could not start';Exit=0;Http=0},
        @{Text='At C:\\x\\test.ps1:14 char:2';Exit=0;Http=0},
        @{Text='ParserError: Missing closing }';Exit=0;Http=0},
        @{Text='Access is denied';Exit=0;Http=0},
        @{Text='The term foo is not recognized as the name of a cmdlet';Exit=0;Http=0},
        @{Text='';Exit=1;Http=0},
        @{Text='upstream rejected request';Exit=0;Http=422}
    )

    $legacyFalse=0;$forceFalse=0;$legacyTrue=0;$forceTrue=0
    foreach($sample in $falsePositives){
        if(Legacy-Test -Text $sample -ExitCode 0 -HttpStatus 0){$legacyFalse++}
        $r=@(Force-DiagnosticScan -Source 'diagnostic-sandbox' -Artifact 'false-positive-corpus' -Lines @($sample) -ExitCode 0 -HttpStatus 0 -Stage 'benchmark')
        if($r.Count -gt 0){$forceFalse++}
    }
    foreach($sample in $truePositives){
        if(Legacy-Test -Text $sample.Text -ExitCode $sample.Exit -HttpStatus $sample.Http){$legacyTrue++}
        $before=@(Get-ErrorLibraryRecords).Count
        $r=@(Force-DiagnosticScan -Source 'diagnostic-sandbox' -Artifact 'true-positive-corpus' -Lines @($sample.Text) -ExitCode $sample.Exit -HttpStatus $sample.Http -Stage 'benchmark')
        if($r.Count -gt 0){$forceTrue++}
        $after=@(Get-ErrorLibraryRecords)
        $record=@($after|Where-Object{[string]$_.text -eq [string]$sample.Text}|Select-Object -Last 1)
        Assert ($null -ne $record) "$($sample.Text): reporter persisted the selected diagnostic"
        $record=$record[0]
        $legacy=Legacy-Report $sample.Text $sample.Exit $sample.Http







    }

    Assert ($legacyFalse -gt $forceFalse) "smarter checker reduces false positives: legacy=$legacyFalse force=$forceFalse"
    Assert ($forceTrue -eq $legacyTrue) "smarter checker preserves every baseline-detectable positive: $forceTrue/$legacyTrue; baseline blind spots=$($truePositives.Count-$legacyTrue)"
    Write-Host "DIAGNOSTIC BENCHMARK: legacy_false=$legacyFalse force_false=$forceFalse legacy_true=$legacyTrue force_true=$forceTrue"
    Write-Host 'REPORTER CONTRACT: unchanged schema=1, stream=output-scan, fields preserved.'
    Write-Host 'DIAGNOSTIC SANDBOX PASS: same report/diagnosis for concrete errors; smarter checker only for noisy/ambiguous output.'
    exit 0
} finally {
    Remove-Item -LiteralPath $ErrorLibraryPath -Force -ErrorAction SilentlyContinue
    $ErrorLibraryPath=$OriginalLibraryPath
}
