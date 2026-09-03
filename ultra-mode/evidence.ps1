# UARD observable evidence primitives. Never executes candidate artifacts.
$script:EvidenceRoot = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'uaud-evidence'
function Initialize-EvidenceRun([string]$RunId) {
  $script:EvidenceRun = Join-Path $script:EvidenceRoot $RunId
  New-Item -ItemType Directory -Path $script:EvidenceRun -Force | Out-Null
  return $script:EvidenceRun
}
function Write-EvidenceJson([string]$Stage,[string]$Name,[object]$Object) {
  $d=Join-Path $script:EvidenceRun $Stage;New-Item -ItemType Directory -Path $d -Force|Out-Null
  $Object|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $d $Name) -Encoding UTF8
}
function Write-EvidenceText([string]$Stage,[string]$Name,[string]$Text) {
  $d=Join-Path $script:EvidenceRun $Stage;New-Item -ItemType Directory -Path $d -Force|Out-Null
  [string]$Text|Set-Content -LiteralPath (Join-Path $d $Name) -Encoding UTF8
}
function Write-EvidenceResult([string]$Stage,[string]$Result,[string]$Reason='', [int]$ExitCode=0) {
  Write-EvidenceJson $Stage 'result.json' ([ordered]@{stage=$Stage;result=$Result;reason=$Reason;exit_code=$ExitCode;timestamp_utc=[DateTime]::UtcNow.ToString('o')})
}
function Get-EvidenceRunPath { return $script:EvidenceRun }
