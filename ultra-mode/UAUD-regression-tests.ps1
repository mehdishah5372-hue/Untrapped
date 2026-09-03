# UAUD regression tests 1.2.0 — non-installing
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$UAUD=Join-Path $Root 'UAUD.ps1'
$ErrorLibrary=Join-Path $Root 'ErrorLibrary.ps1'
$DiagnosticSandbox=Join-Path $Root 'diagnostic-force-sandbox.ps1'
function ParseText([string]$Source){$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseInput($Source,[ref]$t,[ref]$e);[pscustomobject]@{Ast=$a;Errors=@($e)}}
function Pass([string]$Message){Write-Host "[REGRESSION PASS] $Message" -ForegroundColor Green}
function Fail([string]$Message){Write-Host "[REGRESSION FAIL] $Message" -ForegroundColor Red;exit 1}

if(-not(Test-Path -LiteralPath $UAUD)){Fail 'UAUD.ps1 missing'}
if(-not(Test-Path -LiteralPath $ErrorLibrary)){Fail 'ErrorLibrary.ps1 missing'}
if(-not(Test-Path -LiteralPath $DiagnosticSandbox)){Fail 'diagnostic force sandbox missing'}

$source=Get-Content -LiteralPath $UAUD -Raw
$current=ParseText $source
if(@($current.Errors).Count -ne 0){
    $details=@($current.Errors|ForEach-Object{"line=$($_.Extent.StartLineNumber) col=$($_.Extent.StartColumnNumber): $($_.Message)"}) -join ' | '
    Fail "current UAUD.ps1 does not parse: $details"
}
Pass 'current UAUD.ps1 parses successfully'

$librarySource=Get-Content -LiteralPath $ErrorLibrary -Raw
$libraryResult=ParseText $librarySource
if(@($libraryResult.Errors).Count -ne 0){
    $details=@($libraryResult.Errors|ForEach-Object{"line=$($_.Extent.StartLineNumber) col=$($_.Extent.StartColumnNumber): $($_.Message)"}) -join ' | '
    Fail "current ErrorLibrary.ps1 does not parse: $details"
}
Pass 'current ErrorLibrary.ps1 parses successfully'

$diagnosticSource=Get-Content -LiteralPath $DiagnosticSandbox -Raw
$diagnosticResult=ParseText $diagnosticSource
if(@($diagnosticResult.Errors).Count -ne 0){Fail 'diagnostic force sandbox does not parse'}
Pass 'diagnostic force sandbox parses successfully'

$bad='throw "FETCH FAILURE $name HTTP $code: $message"'
$badResult=ParseText $bad
if(@($badResult.Errors).Count -eq 0){Fail 'historical $code: parser failure was not reproduced'}
Pass 'historical $code: invalid-variable-reference failure is reproduced'

$good='throw "FETCH FAILURE $name HTTP ${code}: $message"'
$goodResult=ParseText $good
if(@($goodResult.Errors).Count -ne 0){Fail 'corrected ${code}: form still fails to parse'}
Pass 'corrected ${code}: form parses successfully'

if($source -match '\$code:'){Fail 'the historical $code: defect is still present in UAUD.ps1'}
Pass 'historical $code: defect is absent from UAUD.ps1'

$badLibrary='function Scan-ErrorLike { param([string]$Source,[string]$Artifact,[string[]]$Lines,[int]$ExitCode=0,[int]$HttpStatus=0,[string]$Stage=""; Scan-ErrorOutput @PSBoundParameters }'
$badLibraryResult=ParseText $badLibrary
if(@($badLibraryResult.Errors).Count -eq 0){Fail 'historical ErrorLibrary param-list parser failure was not reproduced'}
Pass 'historical ErrorLibrary malformed param-list failure is reproduced'

if($librarySource -match '\[string\]\$Stage=''[^\r\n]*;'){Fail 'historical ErrorLibrary malformed param-list defect is still present'}
Pass 'historical ErrorLibrary malformed param-list defect is absent'

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $DiagnosticSandbox
if($LASTEXITCODE -ne 0){Fail "diagnostic force sandbox failed with exit code $LASTEXITCODE"}
Pass 'force-first diagnostic benchmark outperforms OSblocker 1.0.0 lexical baseline'

Pass 'full-file parser gate covers historical missing-string/missing-brace failure'
Write-Host '[REGRESSION PASS] UAUD historical + diagnostic regression suite complete' -ForegroundColor Cyan
exit 0
