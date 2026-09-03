# Reporter compatibility sandbox for OSblocker 1.0.0
# Verifies that force-first diagnosis changes classification without silently changing
# the underlying reporter contract for a given emitted error event.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'ErrorLibrary.ps1')

$OriginalLibraryPath=$ErrorLibraryPath
$ErrorLibraryPath=Join-Path $env:TEMP ('osblocker-reporter-compat-'+[guid]::NewGuid().ToString('N')+'.jsonl')

function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "REPORTER COMPAT SANDBOX FAIL: $Message"};Write-Host "REPORTER COMPAT SANDBOX PASS: $Message"}
function Legacy-Report([string]$Text,[int]$ExitCode=0,[int]$HttpStatus=0){
    $category=Classify-Legacy $Text
    $fp=Get-ErrorFingerprint $Text $category
    [ordered]@{schema=1;stream='output-scan';category=$category;fingerprint=$fp;text=$Text;exit_code=$ExitCode;http_status=$HttpStatus}
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

try {
    $corpus=@(
        @{Name='parser';Text='ParserError: Missing closing }';Exit=0;Http=0;Category='PARSER'},
        @{Name='access';Text='Access is denied';Exit=0;Http=0;Category='ACCESS'},
        @{Name='timeout';Text='The request timed out';Exit=0;Http=0;Category='TIMEOUT'},
        @{Name='notfound';Text='The term foo is not recognized as the name of a cmdlet';Exit=0;Http=0;Category='PARSER'},
        @{Name='http422';Text='upstream rejected request';Exit=0;Http=422;Category='HTTP_422'},
        @{Name='exit1';Text='';Exit=1;Http=0;Category='UNKNOWN'}
    )

    foreach($sample in $corpus){
        $legacy=Legacy-Report $sample.Text $sample.Exit $sample.Http
        $current=@(Force-DiagnosticScan -Source 'reporter-compat-sandbox' -Artifact $sample.Name -Lines @($sample.Text) -ExitCode $sample.Exit -HttpStatus $sample.Http -Stage 'compat')
        Assert ($current.Count -eq 1) "$($sample.Name): exactly one event is still reported for a real error condition"
        $record=@(Get-ErrorLibraryRecords | Where-Object {$_.artifact -eq $sample.Name})[0]
        Assert ($null -ne $record) "$($sample.Name): event is persisted"
        Assert ([string]$record.text -eq [string]$legacy.text) "$($sample.Name): reported text unchanged"
        Assert ([string]$record.fingerprint -eq [string]$legacy.fingerprint) "$($sample.Name): fingerprint unchanged"
        Assert ([string]$record.category -eq [string]$legacy.category) "$($sample.Name): category unchanged for the same concrete error"
        Assert ([int]$record.exit_code -eq [int]$legacy.exit_code) "$($sample.Name): exit code unchanged"
        Assert ([int]$record.http_status -eq [int]$legacy.http_status) "$($sample.Name): HTTP status unchanged"
    }

    # Explicitly document the semantic difference: force-first may collapse a noisy batch
    # to its strongest event. That is a checker/report-selection change, not a change to
    # the underlying Save-ErrorEvent fields for the selected event.
    $batch=@('PASS — parser/repair gate complete','ParserError: Missing closing }','cleanup complete')
    $r=@(Force-DiagnosticScan -Source 'reporter-compat-sandbox' -Artifact 'batch' -Lines $batch -ExitCode 0 -HttpStatus 0 -Stage 'batch')
    Assert ($r.Count -eq 1) 'noisy batch yields one strongest diagnostic event'
    $batchRecord=@(Get-ErrorLibraryRecords | Where-Object {$_.artifact -eq 'batch'})[0]
    Assert ([string]$batchRecord.category -eq 'PARSER') 'batch strongest event is the concrete parser error'

    Write-Host 'REPORTER COMPATIBILITY: selected concrete error event preserves text/category/fingerprint/exit/http semantics.'
    Write-Host 'REPORTER COMPATIBILITY: force-first intentionally changes batch event selection/cardinality for noisy output.'
    Write-Host 'REPORTER COMPAT SANDBOX PASS'
    exit 0
} finally {
    Remove-Item -LiteralPath $ErrorLibraryPath -Force -ErrorAction SilentlyContinue
    $ErrorLibraryPath=$OriginalLibraryPath
}
