# Diagnostic force-check sandbox for OSblocker 1.0.0
# Non-installing. Compares the legacy lexical detector with the force-first detector.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'ErrorLibrary.ps1')
$OriginalLibraryPath=$ErrorLibraryPath
$ErrorLibraryPath=Join-Path $env:TEMP ('osblocker-diagnostic-sandbox-' + [guid]::NewGuid().ToString('N') + '.jsonl')

function Legacy-Test([string]$Text,[int]$ExitCode=0,[int]$HttpStatus=0){
    if($ExitCode -ne 0 -or $HttpStatus -ge 400){return $true}
    return [bool]($Text -match '(?i)(?:^|\s)(error|exception|failed|failure|denied|timeout|timed out|cannot find|not found|unprocessable|conflict|redirect rejected)(?:\b|:)')
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
        if(Legacy-Test -Text $sample){$legacyFalse++}
        $r=@(Force-DiagnosticScan -Source 'diagnostic-sandbox' -Artifact 'false-positive-corpus' -Lines @($sample) -ExitCode 0 -HttpStatus 0 -Stage 'benchmark')
        if($r.Count -gt 0){$forceFalse++}
    }
    foreach($sample in $truePositives){
        if(Legacy-Test -Text $sample.Text -ExitCode $sample.Exit -HttpStatus $sample.Http){$legacyTrue++}
        $r=@(Force-DiagnosticScan -Source 'diagnostic-sandbox' -Artifact 'true-positive-corpus' -Lines @($sample.Text) -ExitCode $sample.Exit -HttpStatus $sample.Http -Stage 'benchmark')
        if($r.Count -gt 0){$forceTrue++}
    }

    Assert ($legacyFalse -gt $forceFalse) "force-first false positives improve: legacy=$legacyFalse force=$forceFalse"
    Assert ($forceTrue -eq $truePositives.Count) "force-first detector retains all high-confidence positives: $forceTrue/$($truePositives.Count)"
    Assert ((Get-ErrorLibraryRecords | Where-Object {$_.source -eq 'diagnostic-sandbox'}).Count -gt 0) 'force-first events are persisted only inside the disposable sandbox library'
    Write-Host "DIAGNOSTIC BENCHMARK: legacy_false=$legacyFalse force_false=$forceFalse legacy_true=$legacyTrue force_true=$forceTrue"
    Write-Host 'DIAGNOSTIC SANDBOX PASS: force-first detector outperforms OSblocker 1.0.0 lexical baseline'
    exit 0
} finally {
    Remove-Item -LiteralPath $ErrorLibraryPath -Force -ErrorAction SilentlyContinue
    $ErrorLibraryPath=$OriginalLibraryPath
}
