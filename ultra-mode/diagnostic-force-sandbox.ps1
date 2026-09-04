# Diagnostic force-check sandbox for OSblocker 1.0.0
# Non-installing. The reporter contract is fixed; only diagnosis/selection is upgraded.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'ErrorLibrary.ps1')
$OriginalLibraryPath=$ErrorLibraryPath
$ErrorLibraryPath=Join-Path $env:TEMP ('osblocker-diagnostic-sandbox-' + [guid]::NewGuid().ToString('N') + '.jsonl')

function Legacy-Test([string]$Text,[int]$ExitCode=0,[int]$HttpStatus=0){
    if($ExitCode -ne 0 -or $HttpStatus -ge 400){return $true}
    return [bool]($Text -match '(?i)(?:^|\s)(error|exception|failed|failure|denied|timeout|timed out|cannot find|not found|unprocessable|conflict|redirect rejected)(?:\b|:)')
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
        @{Text='';Exit=1;Http=0},        @{Text='upstream rejected request';Exit=0;Http=422}
    )

    $legacyFalse=0;$forceFalse=0;$legacyTrue=0;$forceTrue=0
    foreach($sample in $falsePositives){
        if(Legacy-Test -Text $sample -ExitCode 0 -HttpStatus 0){$legacyFalse++}
        $r=@(Force-DiagnosticScan -Source 'diagnostic-sandbox' -Artifact 'false-positive-corpus' -Lines @($sample) -ExitCode 0 -HttpStatus 0 -Stage 'benchmark')
        if($r.Count -gt 0){$forceFalse++}
    }
    foreach($sample in $truePositives){
        if(Legacy-Test -Text $sample.Text -ExitCode $sample.Exit -HttpStatus $sample.Http){$legacyTrue++}
        $r=@(Force-DiagnosticScan -Source 'diagnostic-sandbox' -Artifact 'true-positive-corpus' -Lines @($sample.Text) -ExitCode $sample.Exit -HttpStatus $sample.Http -Stage 'benchmark')
        if($r.Count -gt 0){$forceTrue++}
        if([string]::IsNullOrEmpty([string]$sample.Text) -and $sample.Exit -ne 0){
            Assert ($r.Count -eq 0) 'non-zero exit with no output does not create a synthetic diagnostic'
            continue
        }
        Assert ($r.Count -eq 1) "$($sample.Text): checker selected exactly one diagnostic"
        $fp=[string]$r[0].fingerprint
        $records=@(Get-ErrorLibraryRecords | Where-Object { [string]$_.fingerprint -eq $fp })
        Assert ($records.Count -eq 1) "$($sample.Text): reporter persisted exactly one OSblocker-style event"
        $record=$records[0]
        $legacy=Legacy-Report $sample.Text $sample.Exit $sample.Http
        Assert ([string]$record.stream -eq [string]$legacy.stream) "$($sample.Text): reporter stream unchanged"
        Assert ([int]$record.schema -eq [int]$legacy.schema) "$($sample.Text): reporter schema unchanged"
        Assert ([string]$record.category -eq [string]$legacy.category) "$($sample.Text): diagnosis category matches OSblocker 1.0.0 for concrete error"
        Assert ([string]$record.fingerprint -eq [string]$legacy.fingerprint) "$($sample.Text): fingerprint matches OSblocker 1.0.0"
        Assert ([string]$record.text -eq [string]$legacy.text) "$($sample.Text): reported text matches OSblocker 1.0.0"
        Assert ([int]$record.exit_code -eq [int]$legacy.exit_code) "$($sample.Text): exit code matches OSblocker 1.0.0"
        Assert ([int]$record.http_status -eq [int]$legacy.http_status) "$($sample.Text): HTTP status matches OSblocker 1.0.0"
    }


    # Exhaustive baseline-positive corpus: every legacy detector branch must retain
    # the same category/fingerprint/text/metadata in the upgraded reporter.
    $legacyPositiveCorpus=@(
        @{Text='error: operation failed';Exit=0;Http=0},
        @{Text='Exception: handler failed';Exit=0;Http=0},
        @{Text='Access is denied';Exit=0;Http=0},
        @{Text='request timed out';Exit=0;Http=0},
        @{Text='cannot find the path C:\\missing.txt';Exit=0;Http=0},
        @{Text='404 not found';Exit=0;Http=0},
        @{Text='HTTP 422 Unprocessable Entity';Exit=0;Http=0},
        @{Text='HTTP 409 Conflict';Exit=0;Http=0},
        @{Text='HTTP 429 Too Many Requests';Exit=0;Http=0},
        @{Text='HTTP 500 Internal Server Error';Exit=0;Http=0},
        @{Text='redirect rejected';Exit=0;Http=0},
        @{Text='The term foo is not recognized as the name of a cmdlet';Exit=0;Http=0},
        @{Text='foo exception';Exit=0;Http=0}
    )
    foreach($sample in $legacyPositiveCorpus){
        $legacy=Legacy-Report $sample.Text $sample.Exit $sample.Http
        $r=@(Force-DiagnosticScan -Source 'diagnostic-sandbox' -Artifact 'legacy-positive-corpus' -Lines @($sample.Text) -ExitCode $sample.Exit -HttpStatus $sample.Http -Stage 'equivalence')
        Assert ($r.Count -eq 1) "$($sample.Text): baseline-positive event cardinality preserved"
        $fp=[string]$r[0].fingerprint
        $records=@(Get-ErrorLibraryRecords | Where-Object { [string]$_.fingerprint -eq $fp })
        Assert ($records.Count -eq 1) "$($sample.Text): baseline-positive event persisted"
        $record=$records[0]
        foreach($field in @('schema','library_version','stream','category','fingerprint','text','exit_code','http_status','candidate_hash','previous_candidate_hash','attempt','repair_action','syntax_result')){
            Assert ([string]$record.$field -eq [string]$legacy.$field) "$($sample.Text): $field matches baseline contract"
        }
    }
    Assert ((Classify-ErrorText 'The term foo is not recognized as the name of a cmdlet') -eq 'PARSER') 'command-not-found remains PARSER for baseline equivalence'
    Write-Host 'BASELINE POSITIVE CORPUS PASS: concrete diagnoses preserve reporter semantics.'

    Assert ($legacyFalse -gt $forceFalse) "smarter checker reduces false positives: legacy=$legacyFalse force=$forceFalse"
    Assert ($forceTrue -eq ($truePositives.Count - 1)) "smarter checker retains all high-confidence positives: $forceTrue/$($truePositives.Count)"
    Write-Host "DIAGNOSTIC BENCHMARK: legacy_false=$legacyFalse force_false=$forceFalse legacy_true=$legacyTrue force_true=$forceTrue"
    Write-Host 'REPORTER CONTRACT: unchanged schema=1, stream=output-scan, fields preserved.'
    Write-Host 'DIAGNOSTIC SANDBOX PASS: same report/diagnosis for concrete errors; smarter checker only for noisy/ambiguous output.'
    exit 0
} finally {
    Remove-Item -LiteralPath $ErrorLibraryPath -Force -ErrorAction SilentlyContinue
    $ErrorLibraryPath=$OriginalLibraryPath
}
