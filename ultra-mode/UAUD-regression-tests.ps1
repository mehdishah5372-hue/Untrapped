# UAUD regression tests 1.0.0 — non-installing
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$UAUD=Join-Path $Root 'UAUD.ps1'
function ParseText([string]$Source){$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseInput($Source,[ref]$t,[ref]$e);[pscustomobject]@{Ast=$a;Errors=@($e)}}
function Pass([string]$Message){Write-Host "[REGRESSION PASS] $Message" -ForegroundColor Green}
function Fail([string]$Message){Write-Host "[REGRESSION FAIL] $Message" -ForegroundColor Red;exit 1}

if(-not(Test-Path -LiteralPath $UAUD)){Fail 'UAUD.ps1 missing'}
$source=Get-Content -LiteralPath $UAUD -Raw
$current=ParseText $source
if(@($current.Errors).Count -ne 0){
    $details=@($current.Errors|ForEach-Object{"line=$($_.Extent.StartLineNumber) col=$($_.Extent.StartColumnNumber): $($_.Message)"}) -join ' | '
    Fail "current UAUD.ps1 does not parse: $details"
}
Pass 'current UAUD.ps1 parses successfully'

# Historical regression: PowerShell treats $code: inside a double-quoted string as an invalid variable reference.
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

# The former end-of-pipeline malformed catch/string is covered by the full-file parser gate above.
Pass 'full-file parser gate covers the historical missing-string/missing-brace failure'

Write-Host '[REGRESSION PASS] UAUD historical parser regression suite complete' -ForegroundColor Cyan
exit 0
