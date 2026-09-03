# UAUD validation engine 1.0.3
# Reliable syntax-only gate used by CI. It never executes the candidate script.
param(
 [Parameter(Mandatory=$true)][string]$Candidate,
 [string]$Artifact='candidate.ps1'
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ErrorLibrary=Join-Path $Root 'ErrorLibrary.ps1'
$ReportDir=Join-Path $Root 'uaud-reports'
New-Item -ItemType Directory -Path $ReportDir -Force|Out-Null
if(Test-Path -LiteralPath $ErrorLibrary){. $ErrorLibrary}
function Hash-Text([string]$Text){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Write-Event([string]$Message){$line='[UAUD '+(Get-Date -Format HH:mm:ss)+'] '+$Message;Write-Host $line}
if(-not(Test-Path -LiteralPath $Candidate)){throw "Candidate not found: $Candidate"}
$source=[IO.File]::ReadAllText($Candidate,[Text.Encoding]::UTF8)
$hash=Hash-Text $source
Write-Event "SYNTAX CHECK START artifact=$Artifact hash=$hash"
$tokens=$null;$parseErrors=$null
[void][System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
$errors=@($parseErrors)
if($errors.Count -gt 0){
 foreach($e in $errors){$msg=[string]$e.Message;Write-Event ("SYNTAX FAIL line=$($e.Extent.StartLineNumber) col=$($e.Extent.StartColumnNumber): $msg");if(Get-Command Save-ErrorEvent -ErrorAction SilentlyContinue){[void](Save-ErrorEvent -Source 'UAUD' -Stream 'Parser' -Text $msg -Artifact $Artifact -CandidateHash $hash -Attempt 1 -SyntaxResult 'FAIL' -Context ("line=$($e.Extent.StartLineNumber) column=$($e.Extent.StartColumnNumber)"))}}
 $verdict='SYNTAX_FAIL'
}else{$verdict='SYNTAX_PASS';Write-Event 'SYNTAX PASS'}
$report=[ordered]@{schema=1;uaud_version='1.0.3';artifact=$Artifact;candidate_hash=$hash;syntax=$verdict;error_count=$errors.Count;errors=@($errors|ForEach-Object{[ordered]@{message=$_.Message;line=$_.Extent.StartLineNumber;column=$_.Extent.StartColumnNumber}});behavioural_stage='EXTERNAL_ISOLATED_WINDOWS_CI'}
$reportPath=Join-Path $ReportDir (([IO.Path]::GetFileName($Artifact))+'.json');$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $reportPath -Encoding UTF8;Write-Event "REPORT $reportPath"
$report|ConvertTo-Json -Depth 10
if($errors.Count -eq 0){exit 0}else{exit 1}
