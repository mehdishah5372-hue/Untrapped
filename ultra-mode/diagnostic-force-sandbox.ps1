# Focused force-first checker sandbox. No installation or policy mutation.
$ErrorActionPreference='Stop';$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
function Assert([bool]$ok,[string]$msg){if(-not$ok){throw "DIAGNOSTIC SANDBOX FAIL: $msg"};Write-Host "DIAGNOSTIC SANDBOX PASS: $msg"}
. (Join-Path $Root 'ErrorLibrary.ps1');$old=$ErrorLibraryPath;$ErrorLibraryPath=Join-Path $env:TEMP ('osb-force-'+[guid]::NewGuid().ToString('N')+'.jsonl')
try{
 $narrative=@('PASS — parser/repair gate complete','[REGRESSION PASS] historical parser failure was reproduced','This test verifies that the script fails safely when given malformed input.','WARNING: expected test narrative, not an emitted warning','Error handling regression coverage complete','The previous failure is intentionally reproduced here.','HTTP 422 deterministic rejection is a regression fixture.','No errors were found.','No error occurred; the regression test passed.','The test failed previously and is now fixed.')
 $concrete=@('[ERROR] UARD could not start','ParserError: Missing closing }','Access is denied','The term foo is not recognized as the name of a cmdlet','The request timed out while contacting the middleman','redirect rejected: unexpected location','Exception calling "Invoke" with "1" argument(s): boom','FullyQualifiedErrorId : CommandNotFoundException','CategoryInfo : ObjectNotFound')
 $bad=@();foreach($x in $narrative){$r=@(Force-DiagnosticScan -Source 'force-sandbox' -Artifact 'narrative' -Lines @($x) -Stage 'checker');if($r.Count -gt 0){$bad+=$x;Write-Host "FALSE POSITIVE RETAINED: <$x>"}}
 $good=0;foreach($x in $concrete){$before=@(Get-ErrorLibraryRecords).Count;[void](Force-DiagnosticScan -Source 'force-sandbox' -Artifact 'concrete' -Lines @($x) -Stage 'checker');$after=@(Get-ErrorLibraryRecords);if(($after.Count-$before) -eq 1){$good++}}
 Assert ($bad.Count -eq 0) "force-first suppresses all known narrative false positives: $($bad.Count)/$($narrative.Count)"
 Assert ($good -eq $concrete.Count) "force-first retains concrete errors: $good/$($concrete.Count)"
 Assert (@(Get-ErrorLibraryRecords|Where-Object{$_.schema -ne 1}).Count -eq 0) 'all emitted records retain schema 1'
 Assert (@(Get-ErrorLibraryRecords|Where-Object{$_.stream -ne 'output-scan'}).Count -eq 0) 'all emitted records retain output-scan stream'
 Write-Host "DIAGNOSTIC SANDBOX RESULT: narrative_false=$($bad.Count) concrete_true=$good"
 exit 0
}finally{Remove-Item $ErrorLibraryPath -Force -ErrorAction SilentlyContinue;$ErrorLibraryPath=$old}
