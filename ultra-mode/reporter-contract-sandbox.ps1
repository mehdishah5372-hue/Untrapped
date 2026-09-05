$ErrorActionPreference='Stop'
$baselineCommit='65fec7380613b0bfd673708cb046795b3d28c7e7'
$url="https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/$baselineCommit/ultra-mode/ErrorLibrary.ps1"
$canonical=Join-Path $env:TEMP 'ErrorLibrary-canonical.ps1'
Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $canonical
$text=Get-Content $canonical -Raw
if($text -notmatch '\$ErrorLibraryVersion\s*=\s*''1\.1\.1'''){throw 'Pinned baseline reporter version mismatch'}
$localPath=Join-Path $PSScriptRoot 'ErrorLibrary.ps1';$localText=Get-Content $localPath -Raw
$canonReporter=[regex]::Match($text,'(?s)function Save-ErrorEvent.*?\n}\s*\n\s*function Get-ErrorCount').Value
$localReporter=[regex]::Match($localText,'(?s)function Save-ErrorEvent.*?\n}\s*\n\s*function Get-ErrorCount').Value
if(($canonReporter -replace '\s+',' ').Trim() -ne ($localReporter -replace '\s+',' ').Trim()){throw 'REPORTER IMPLEMENTATION DIVERGENCE'}
$canonHash=(Get-FileHash $canonical -Algorithm SHA256).Hash.ToLowerInvariant();$localHash=(Get-FileHash $localPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "PINNED BASELINE COMMIT=$baselineCommit";Write-Host "CANONICAL FULL FILE SHA256=$canonHash";Write-Host "SANDBOX FULL FILE SHA256=$localHash"
$tmp1=Join-Path $env:TEMP 'canon-record.jsonl';$tmp2=Join-Path $env:TEMP 'sandbox-record.jsonl'
& powershell -NoProfile -Command ". '$canonical'; `$ErrorLibraryPath='$tmp1'; Save-ErrorEvent -Source 'UAUD' -Stream 'output-scan' -Text '[ERROR] synthetic failure' -HttpStatus 500 -Attempt 2 -Artifact 'UAUD.ps1' -CandidateHash 'A' -PreviousCandidateHash 'B' -Context 'stage=test' | Out-Null"
& powershell -NoProfile -Command ". '$localPath'; `$ErrorLibraryPath='$tmp2'; Save-ErrorEvent -Source 'UAUD' -Stream 'output-scan' -Text '[ERROR] synthetic failure' -HttpStatus 500 -Attempt 2 -Artifact 'UAUD.ps1' -CandidateHash 'A' -PreviousCandidateHash 'B' -Context 'stage=test' | Out-Null"
$a=Get-Content $tmp1 -Raw|ConvertFrom-Json;$b=Get-Content $tmp2 -Raw|ConvertFrom-Json
$fields='schema','stream','source','artifact','category','fingerprint','text','exit_code','http_status','candidate_hash','previous_candidate_hash','attempt','repair_action','syntax_result','context'
foreach($f in $fields){if([string]$a.$f -ne [string]$b.$f){throw "REPORTER FIELD DIVERGENCE: $f"}}
Write-Host 'REPORTER IMPLEMENTATION + SERIALIZED FIELD CONTRACT: PASS'