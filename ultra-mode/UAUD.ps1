# UAUD 2.0.0 - observable stage orchestrator
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$UARD=Join-Path $Root 'self-repair.ps1'
$Evidence=Join-Path $Root 'evidence.ps1'
if(-not(Test-Path -LiteralPath $UARD)){throw "UARD not found: $UARD"}
if(-not(Test-Path -LiteralPath $Evidence)){throw "Evidence library not found: $Evidence"}
. $Evidence
$RunId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$Run=Initialize-EvidenceRun $RunId
Write-Host "UAUD 2.0.0 - OBSERVABLE PIPELINE"
Write-Host "EVIDENCE: $Run"
Write-Host 'Stages: CANON -> MIDDLEMAN -> JSON/PS -> PARSER -> REPAIR -> AST/JSON -> CANON MATCH -> WINDOWS -> REPORT -> INSTALL'
Write-Host 'USER BOUNDARY: paste this console output back here if anything fails.'
Write-EvidenceJson 'run' 'input.json' ([ordered]@{run_id=$RunId;started_utc=[DateTime]::UtcNow.ToString('o');root=$Root;uard=$UARD;orchestrator_version='2.0.0'})
Write-EvidenceJson 'run' 'environment.json' ([ordered]@{powershell=$PSVersionTable;computer=$env:COMPUTERNAME;user=$env:USERNAME;cwd=(Get-Location).Path;language_mode=$ExecutionContext.SessionState.LanguageMode;execution_policy=@(Get-ExecutionPolicy -List|ForEach-Object{$_.ToString()})})
try {
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName="$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $psi.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$UARD+'"'
  $psi.WorkingDirectory=$Root;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$false
  $p=New-Object Diagnostics.ProcessStartInfo
  $p=$null
  $proc=New-Object Diagnostics.Process;$proc.StartInfo=$psi;[void]$proc.Start()
  $out=$proc.StandardOutput.ReadToEnd();$err=$proc.StandardError.ReadToEnd();$proc.WaitForExit()
  Write-EvidenceText 'run' 'stdout.txt' $out;Write-EvidenceText 'run' 'stderr.txt' $err
  $lines=@($out -split "`r?`n")+@($err -split "`r?`n")
  $el=Join-Path $Root 'ErrorLibrary.ps1';if(Test-Path -LiteralPath $el){. $el;Scan-ErrorOutput -Source 'UAUD' -Artifact 'UARD' -Lines $lines -ExitCode $proc.ExitCode -Stage 'run'}
  Write-EvidenceJson 'run' 'result.json' ([ordered]@{stage='run';result=if($proc.ExitCode -eq 0){'SUCCESS'}else{'FAIL'};exit_code=$proc.ExitCode;timestamp_utc=[DateTime]::UtcNow.ToString('o')})
  Write-Host "`n=== UAUD EVIDENCE PACKAGE ==="
  Write-Host "RUN_ID: $RunId"
  Write-Host "EVIDENCE_ROOT: $Run"
  Write-Host "UARD_EXIT_CODE: $($proc.ExitCode)"
  Write-Host "STDOUT_FILE: $Run\run\stdout.txt"
  Write-Host "STDERR_FILE: $Run\run\stderr.txt"
  if($proc.ExitCode -ne 0){Write-Host 'RESULT: FAIL - paste this entire output here.';exit $proc.ExitCode}
  Write-Host 'RESULT: SUCCESS - all UARD gates completed.'
  exit 0
} catch {
  Write-EvidenceText 'run' 'stderr.txt' ($_|Out-String)
  Write-EvidenceResult 'run' 'FAIL' $_.Exception.Message 1
  Write-Host "RESULT: ORCHESTRATOR_FAILURE: $($_.Exception.Message)"
  Write-Host "EVIDENCE_ROOT: $Run"
  exit 1
}
