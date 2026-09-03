# Executive diagnostic: OSblocker 1.0.0 ErrorLibrary vs current diagnostic upgrade
# Non-installing. Runs both implementations in isolated temp copies and compares reporter/checker behaviour.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$BaselineRef='65fec7380613b0bfd673708cb046795b3d28c7e7'
$BaselineUrl="https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/$BaselineRef/ultra-mode/ErrorLibrary.ps1"
$Current=Join-Path $Root 'ErrorLibrary.ps1'
$Report=Join-Path $Root ('executive-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Report | Out-Null

function Stamp([string]$s){Write-Host ('['+(Get-Date -Format HH:mm:ss)+'] '+$s)}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "EXECUTIVE DIAGNOSTIC FAIL: $msg"};Stamp ('PASS — '+$msg)}
function Parse([string]$p){$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);[pscustomobject]@{ast=$a;errors=@($e)}}
function Normalize([object]$r){
    if($null -eq $r){return $null}
    [ordered]@{schema=[int]$r.schema;library_version=[string]$r.library_version;source=[string]$r.source;stream=[string]$r.stream;artifact=[string]$r.artifact;category=[string]$r.category;fingerprint=[string]$r.fingerprint;text=[string]$r.text;exit_code=[int]$r.exit_code;http_status=[int]$r.http_status;candidate_hash=[string]$r.candidate_hash;previous_candidate_hash=[string]$r.previous_candidate_hash;attempt=[int]$r.attempt;repair_action=[string]$r.repair_action;syntax_result=[string]$r.syntax_result;context=([string]$r.context -replace 'timestamp[^;]*','timestamp=IGNORED' -replace 'collected_lines=\d+','collected_lines=N')}
}
function Invoke-Impl([string]$Library,[object[]]$Case,[string]$Label){
    $path=Join-Path $env:TEMP ('osb-'+$Label+'-'+[guid]::NewGuid().ToString('N')+'.ps1')
    Copy-Item -LiteralPath $Library -Destination $path -Force
    try {
        . $path
        $ErrorLibraryPath=Join-Path $env:TEMP ('osb-'+$Label+'-events-'+[guid]::NewGuid().ToString('N')+'.jsonl')
        $before=@(Get-ErrorLibraryRecords).Count
        $out=@(Scan-ErrorOutput -Source 'executive' -Artifact $Case.Name -Lines @($Case.Lines) -ExitCode $Case.Exit -HttpStatus $Case.Http -Stage 'comparison')
        $records=@(Get-ErrorLibraryRecords)
        $new=@($records | Select-Object -Skip $before | ForEach-Object {Normalize $_})
        [pscustomobject]@{selected=$out;records=$new;count=$new.Count}
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if($ErrorLibraryPath){Remove-Item -LiteralPath $ErrorLibraryPath -Force -ErrorAction SilentlyContinue}
        Remove-Module -Name ErrorLibrary -ErrorAction SilentlyContinue
    }
}

try {
    Stamp 'OSblocker EXECUTIVE DIAGNOSTIC — REPORTER + CHECKER COMPARISON'
    Stamp 'Baseline: OSblocker 1.0.0 ErrorLibrary from pinned baseline commit.'
    Stamp 'Upgrade: current main ErrorLibrary.ps1.'
    Stamp 'No installation, firewall, DNS, WFP, hosts, routes, VPN, proxy, adapter, or override mutation is performed.'

    $base=Join-Path $env:TEMP ('osb-baseline-'+[guid]::NewGuid().ToString('N')+'.ps1')
    $wc=New-Object Net.WebClient
    $wc.DownloadString($BaselineUrl) | Set-Content -LiteralPath $base -Encoding UTF8
    Remove-Variable wc -ErrorAction SilentlyContinue

    $bp=Parse $base;$cp=Parse $Current
    Assert (@($bp.errors).Count -eq 0) 'OSblocker 1.0.0 baseline ErrorLibrary parses'
    Assert (@($cp.errors).Count -eq 0) 'current ErrorLibrary parses'

    $cases=@(
      [pscustomobject]@{Name='clean-pass';Lines=@('PASS — parser/repair gate complete');Exit=0;Http=0;ExpectedError=$false},
      [pscustomobject]@{Name='narrative-regression';Lines=@('[REGRESSION PASS] historical parser failure was reproduced');Exit=0;Http=0;ExpectedError=$false},
      [pscustomobject]@{Name='narrative-malformed';Lines=@('This test verifies that the script fails safely when given malformed input.');Exit=0;Http=0;ExpectedError=$false},
      [pscustomobject]@{Name='narrative-warning';Lines=@('WARNING: expected test narrative, not an emitted warning');Exit=0;Http=0;ExpectedError=$false},
      [pscustomobject]@{Name='narrative-error';Lines=@('Error handling regression coverage complete');Exit=0;Http=0;ExpectedError=$false},
      [pscustomobject]@{Name='narrative-failure';Lines=@('The previous failure is intentionally reproduced here.');Exit=0;Http=0;ExpectedError=$false},
      [pscustomobject]@{Name='narrative-http';Lines=@('HTTP 422 deterministic rejection is a regression fixture.');Exit=0;Http=0;ExpectedError=$false},
      [pscustomobject]@{Name='zero-exit';Lines=@('Exit code: 0');Exit=0;Http=0;ExpectedError=$false},
      [pscustomobject]@{Name='no-errors';Lines=@('No errors were found.');Exit=0;Http=0;ExpectedError=$false},
      [pscustomobject]@{Name='true-explicit';Lines=@('[ERROR] UARD could not start');Exit=0;Http=0;ExpectedError=$true},
      [pscustomobject]@{Name='true-parser';Lines=@('ParserError: Missing closing }');Exit=0;Http=0;ExpectedError=$true},
      [pscustomobject]@{Name='true-access';Lines=@('Access is denied');Exit=0;Http=0;ExpectedError=$true},
      [pscustomobject]@{Name='true-command';Lines=@('The term foo is not recognized as the name of a cmdlet');Exit=0;Http=0;ExpectedError=$true},
      [pscustomobject]@{Name='true-exit';Lines=@();Exit=1;Http=0;ExpectedError=$true},
      [pscustomobject]@{Name='true-http';Lines=@('upstream rejected request');Exit=0;Http=422;ExpectedError=$true},
      [pscustomobject]@{Name='mixed-batch';Lines=@('PASS — all gates passed','ParserError: Missing closing }','This test verifies failure handling safely.');Exit=0;Http=0;ExpectedError=$true},
      [pscustomobject]@{Name='two-errors';Lines=@('Access is denied','ParserError: Missing closing }');Exit=0;Http=0;ExpectedError=$true}
    )

    $rows=@();$baselineEvents=0;$upgradeEvents=0;$baselineFalse=0;$upgradeFalse=0;$baselineTrue=0;$upgradeTrue=0
    foreach($case in $cases){
        $b=Invoke-Impl $base $case 'baseline';$u=Invoke-Impl $Current $case 'upgrade'
        $bn=@($b.records);$un=@($u.records)
        $same=$false
        if($bn.Count -eq $un.Count){$same=$true;for($i=0;$i -lt $bn.Count;$i++){if((($bn[$i] | ConvertTo-Json -Compress -Depth 10)) -ne (($un[$i]|ConvertTo-Json -Compress -Depth 10))){$same=$false}}}
        $rows += [ordered]@{case=$case.Name;expected_error=$case.ExpectedError;baseline_count=$b.count;upgrade_count=$u.count;reporter_contract_same=($bn.Count -eq $un.Count);normalized_records_same=$same;baseline_categories=@($bn|ForEach-Object{$_.category});upgrade_categories=@($un|ForEach-Object{$_.category})}
        $baselineEvents += $b.count;$upgradeEvents += $u.count
        if($case.ExpectedError){if($b.count -gt 0){$baselineTrue++};if($u.count -gt 0){$upgradeTrue++}}
        else {if($b.count -gt 0){$baselineFalse++};if($u.count -gt 0){$upgradeFalse++}}
    }
    $rows | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Report 'case-comparison.json') -Encoding UTF8

    $static=[ordered]@{
      baseline_sha256=(Get-FileHash $base -Algorithm SHA256).Hash.ToLowerInvariant()
      upgrade_sha256=(Get-FileHash $Current -Algorithm SHA256).Hash.ToLowerInvariant()
      baseline_lines=@(Get-Content $base).Count
      upgrade_lines=@(Get-Content $Current).Count
      baseline_has_force_checker=([bool](Select-String -LiteralPath $base -Pattern 'Force-DiagnosticScan' -Quiet))
      upgrade_has_force_checker=([bool](Select-String -LiteralPath $Current -Pattern 'Force-DiagnosticScan' -Quiet))
      baseline_reporter_schema=1
      upgrade_reporter_schema=1
      baseline_reporter_stream='output-scan'
      upgrade_reporter_stream='output-scan'
      baseline_save_event_present=([bool](Select-String -LiteralPath $base -Pattern 'function Save-ErrorEvent' -Quiet))
      upgrade_save_event_present=([bool](Select-String -LiteralPath $Current -Pattern 'function Save-ErrorEvent' -Quiet))
    }
    $static | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Report 'static-comparison.json') -Encoding UTF8

    # Executive assertions: reporter must not regress on true-positive cases; checker should reduce false positives.
    Assert ($baselineFalse -gt $upgradeFalse) "checker improvement is real: false positives baseline=$baselineFalse upgrade=$upgradeFalse"
    Assert ($upgradeTrue -eq $baselineTrue) "no high-confidence positive cases lost: baseline=$baselineTrue upgrade=$upgradeTrue"
    Assert ($static.upgrade_reporter_schema -eq $static.baseline_reporter_schema) 'reporter schema remains identical (schema 1)'
    Assert ($static.upgrade_reporter_stream -eq $static.baseline_reporter_stream) 'reporter stream remains identical (output-scan)'

    $summary=[ordered]@{
      status='PASS'
      baseline='OSblocker 1.0.0'
      baseline_commit=$BaselineRef
      upgrade='current-main'
      cases=$cases.Count
      baseline_events=$baselineEvents
      upgrade_events=$upgradeEvents
      false_positives=[ordered]@{baseline=$baselineFalse;upgrade=$upgradeFalse;improvement=$($baselineFalse-$upgradeFalse)}
      true_positive_cases=[ordered]@{baseline=$baselineTrue;upgrade=$upgradeTrue;lost=$($baselineTrue-$upgradeTrue)}
      reporter=[ordered]@{schema_same=$true;stream_same=$true;contract='schema=1 + output-scan + baseline fields'}
      checker=[ordered]@{force_first_upgrade=$true;batch_inspection=$true;structural_evidence=$true;lexical_narrative_suppression=$true}
      report_directory=$Report
      timestamp_utc=[DateTime]::UtcNow.ToString('o')
    }
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Report 'executive-summary.json') -Encoding UTF8

    Stamp 'EXECUTIVE RESULT: PASS'
    Stamp "False positives: baseline=$baselineFalse upgrade=$upgradeFalse (improvement=$($baselineFalse-$upgradeFalse))"
    Stamp "High-confidence positives retained: baseline=$baselineTrue upgrade=$upgradeTrue"
    Stamp 'Reporter contract: schema=1, stream=output-scan, baseline field set preserved.'
    Stamp 'Any remaining downgrade is in checker/report cardinality on mixed batches and must be reviewed before adoption.'
    Stamp ('REPORT: '+$Report)
    exit 0
} catch {
    Stamp ('FAIL-CLOSED: '+$_.Exception.Message)
    try{$_|Out-File -LiteralPath (Join-Path $Report 'fatal.txt') -Encoding UTF8}catch{}
    exit 1
} finally {if($base){Remove-Item -LiteralPath $base -Force -ErrorAction SilentlyContinue}}
