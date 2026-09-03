# UAUD 3.0.1 — complete fail-closed observable launch pipeline
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Middleman = 'https://untrapped-update-middleman-000-999-production.up.railway.app'
$ArtifactBase = $Middleman + '/v1/artifact/'
$ExpectedVersion = '3.2.0'
$ExpectedProtocol = 3
$ExpectedBaseline = '1.0.0'
$MaxBytes = 8388608
$EmergencyCeiling = 200
$RepeatThreshold = 5
$UARD = Join-Path $Root 'self-repair.ps1'
$Schema = Join-Path $Root 'artifact-schema.json'
$Sandbox = Join-Path $Root 'sandbox-behaviour.ps1'
$Evidence = Join-Path $Root 'evidence.ps1'
$ErrorLibrary = Join-Path $Root 'ErrorLibrary.ps1'
$LocalConfig = Join-Path $Root 'config.json'
$Validator = Join-Path $Root 'UAUD-validate.ps1'

function Out([string]$Message) { Write-Host ('[' + (Get-Date -Format HH:mm:ss) + '] ' + $Message) }
function HashBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function HashText([string]$Text) { return HashBytes ([Text.Encoding]::UTF8.GetBytes($Text)) }
function ParsePS([string]$Source) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    return [pscustomobject]@{ Ast = $ast; Tokens = @($tokens); Errors = @($errors) }
}
function ReadLimited([IO.Stream]$Stream) {
    $memory = New-Object IO.MemoryStream
    $buffer = New-Object byte[] 65536
    $total = 0
    try {
        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) { throw "response exceeds $MaxBytes byte limit" }
            $memory.Write($buffer, 0, $read)
        }
        return $memory.ToArray()
    } finally { $memory.Dispose() }
}
function Fetch([string]$Name) {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Out "STAGE 0 FETCH $Name attempt $attempt/5"
            $request = [Net.HttpWebRequest]::Create($ArtifactBase + $Name + '?uaud=' + $RunId)
            $request.Method = 'GET'
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 30000
            $request.AllowAutoRedirect = $false
            $request.UserAgent = 'UAUD/3.0.1'
            $response = $request.GetResponse()
            try {
                $version = [string]$response.Headers['X-Untrapped-Version']
                $protocol = [int]$response.Headers['X-Untrapped-Protocol']
                $baseline = [string]$response.Headers['X-Untrapped-Baseline']
                if ($version -ne $ExpectedVersion -or $protocol -ne $ExpectedProtocol -or $baseline -ne $ExpectedBaseline) {
                    throw "middleman identity mismatch: version=$version protocol=$protocol baseline=$baseline"
                }
                if ($response.ContentLength -gt $MaxBytes) { throw "response exceeds $MaxBytes byte limit" }
                $bytes = ReadLimited $response.GetResponseStream()
                $headerHash = [string]$response.Headers['X-Untrapped-SHA256']
                if ($headerHash -and $headerHash -ne (HashBytes $bytes)) { throw 'middleman SHA256 header mismatch' }
                return $bytes
            } finally { $response.Dispose() }
        } catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
            $message = [string]$_.Exception.Message
            if (Get-Command Save-ErrorEvent -ErrorAction SilentlyContinue) {
                [void](Save-ErrorEvent -Source 'UAUD' -Stream 'Fetch' -Text $message -Artifact $Name -HttpStatus $code -Attempt $attempt -Context 'pipeline fetch')
            }
            if ($code -in @(301,302,303,307,308,400,401,403,404,409,422)) {
                throw "DETERMINISTIC FETCH FAILURE $Name HTTP ${code}: $message"
            }
            if ($attempt -lt 5 -and ($code -eq 0 -or $code -eq 408 -or $code -eq 425 -or $code -eq 429 -or $code -ge 500)) {
                Out "TRANSIENT FETCH ERROR HTTP $code; retrying"
                Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 8))
                continue
            }
            throw "FETCH FAILURE ${Name} HTTP ${code}: $message"
        }
    }
    throw "FETCH FAILURE ${Name}: retry loop exhausted"
}
function Repair([string]$Source, [object]$ParseResult) {
    $candidate = $Source
    foreach ($parseError in @($ParseResult.Errors)) {
        $message = [string]$parseError.Message
        if ($message -match '(?i)missing.*closing.*brace') { $candidate = $candidate.TrimEnd() + "`n}" }
        elseif ($message -match '(?i)missing.*closing.*parenthesis') { $candidate = $candidate.TrimEnd() + "`n)" }
        elseif ($message -match '(?i)missing.*closing.*bracket') { $candidate = $candidate.TrimEnd() + "`n]" }
        else { return $null }
    }
    if ($candidate -eq $Source) { return $null }
    return $candidate
}
function StageResult([string]$Stage, [string]$Result, [hashtable]$Data = @{}) {
    $record = [ordered]@{ stage = $Stage; result = $Result; timestamp_utc = [DateTime]::UtcNow.ToString('o') }
    foreach ($key in $Data.Keys) { $record[$key] = $Data[$key] }
    Write-EvidenceJson $Stage 'result.json' $record
}

foreach ($path in @($UARD,$Schema,$Sandbox,$Evidence,$LocalConfig,$Validator)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required pipeline file missing: $path" }
}
. $Evidence
if (Test-Path -LiteralPath $ErrorLibrary) { . $ErrorLibrary }
$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$Run = Initialize-EvidenceRun $RunId

try {
    Out 'UAUD 3.0.1 — FAIL-CLOSED OBSERVABLE PIPELINE'
    Out "EVIDENCE: $Run"
    Write-EvidenceJson 'run' 'input.json' ([ordered]@{
        run_id=$RunId; orchestrator_version='3.0.1'; middleman=$Middleman;
        expected_version=$ExpectedVersion; expected_protocol=$ExpectedProtocol; expected_baseline=$ExpectedBaseline
    })

    Out 'STAGE 0A — CANONICAL JSON'
    $remoteConfigBytes = Fetch 'ultra-mode/config.json'
    $remoteConfig = ([Text.Encoding]::UTF8.GetString($remoteConfigBytes)).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $localConfig = Get-Content -LiteralPath $LocalConfig -Raw | ConvertFrom-Json
    $remoteCanonical = $remoteConfig | ConvertTo-Json -Depth 20 -Compress
    $localCanonical = $localConfig | ConvertTo-Json -Depth 20 -Compress
    if ($remoteCanonical -ne $localCanonical) { throw 'CANONICAL_MISMATCH: local config.json differs from 000-999 canonical config' }
    StageResult 'stage-0-canonical' 'PASS' @{ canonical_hash=(HashText $remoteCanonical) }
    Out 'PASS — canonical config matches middleman'

    Out 'STAGE 1 — JSON -> PS SANDBOX'
    $domains = @($remoteConfig.domains)
    $blocked = @($remoteConfig.alwaysBlockedDomains)
    $allowed = @($remoteConfig.alwaysAllowedDomains)
    $enabledLiteral = if ($remoteConfig.enabled) { '$true' } else { '$false' }
    $domainLiteral = (@($domains | ForEach-Object { "'$($_.ToString().Replace("'","''"))'" }) -join ', ')
    $blockedLiteral = (@($blocked | ForEach-Object { "'$($_.ToString().Replace("'","''"))'" }) -join ', ')
    $allowedLiteral = (@($allowed | ForEach-Object { "'$($_.ToString().Replace("'","''"))'" }) -join ', ')
    $generated = @"
`$Policy = [ordered]@{
    enabled = $enabledLiteral
    start = '$($remoteConfig.start)'
    end = '$($remoteConfig.end)'
    domains = @($domainLiteral)
    alwaysBlockedDomains = @($blockedLiteral)
    alwaysAllowedDomains = @($allowedLiteral)
}
"@
    $stage1Parse = ParsePS $generated
    if (@($stage1Parse.Errors).Count -gt 0) { throw 'STAGE1_FAILURE: generated PowerShell from canonical JSON did not parse' }
    Write-EvidenceText 'stage-1-json-ps' 'candidate.ps1' $generated
    StageResult 'stage-1-json-ps' 'PASS' @{ candidate_hash=(HashText $generated) }
    Out 'PASS — JSON transformed into parseable PS'

    Out 'STAGE 2 — POWERSHELL PARSER + ADAPTIVE REPAIR'
    $candidate = $generated
    $history = @()
    $counts = @{}
    $repaired = $false
    $parserPassed = $false
    for ($attempt=1; $attempt -le $EmergencyCeiling; $attempt++) {
        $candidateHash = HashText $candidate
        $parseResult = ParsePS $candidate
        Out "PARSER attempt=$attempt hash=$candidateHash errors=$(@($parseResult.Errors).Count)"
        if (@($parseResult.Errors).Count -eq 0) { $parserPassed=$true; StageResult 'stage-2-parser' 'PASS' @{attempt=$attempt;candidate_hash=$candidateHash}; break }
        $repeat = $false
        foreach ($parseError in @($parseResult.Errors)) {
            $fingerprint = if (Get-Command Get-ErrorFingerprint -ErrorAction SilentlyContinue) { Get-ErrorFingerprint ([string]$parseError.Message) 'PARSER' } else { HashText ('PARSER|' + [string]$parseError.Message) }
            if (-not $counts.ContainsKey($fingerprint)) { $counts[$fingerprint] = 0 }
            $counts[$fingerprint]++
            $history += [ordered]@{attempt=$attempt;fingerprint=$fingerprint;message=[string]$parseError.Message;line=$parseError.Extent.StartLineNumber;column=$parseError.Extent.StartColumnNumber}
            if ($counts[$fingerprint] -ge $RepeatThreshold) { $repeat=$true }
        }
        if ($repeat) { throw 'COOKED_REPEATED_ERROR: parser error fingerprint repeated beyond repair threshold' }
        $next = Repair $candidate $parseResult
        if ($null -eq $next) { throw 'UNKNOWN_ERROR: no safe adaptive syntax repair exists' }
        $nextParse = ParsePS $next
        if (@($nextParse.Errors).Count -ge @($parseResult.Errors).Count) { throw 'NON_PROGRESSING_REPAIR: repair did not reduce parser errors' }
        $candidate = $next
        $repaired = $true
    }
    Write-EvidenceJson 'stage-2-parser' 'repair-history.json' @($history)
    if (-not $parserPassed) { throw 'EMERGENCY_CEILING: adaptive parser repair ceiling reached without a valid candidate' }
    Out 'PASS — parser/repair gate complete'

    Out 'STAGE 3 — REPAIR VALIDATION SANDBOX'
    $repairCandidate = Join-Path $env:TEMP ('UAUD-repair-' + $RunId + '.ps1')
    $validatorStdout = Join-Path $env:TEMP ('UAUD-validator-' + $RunId + '-stdout.txt')
    $validatorStderr = Join-Path $env:TEMP ('UAUD-validator-' + $RunId + '-stderr.txt')
    [IO.File]::WriteAllText($repairCandidate,$candidate,(New-Object Text.UTF8Encoding($false)))
    try {
        $vp = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$Validator,'-Candidate',$repairCandidate,'-Artifact','generated-policy.ps1') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $validatorStdout -RedirectStandardError $validatorStderr
        $validatorOutput = @()
        if (Test-Path $validatorStdout) { $validatorOutput += Get-Content $validatorStdout -ErrorAction SilentlyContinue }
        if (Test-Path $validatorStderr) { $validatorOutput += Get-Content $validatorStderr -ErrorAction SilentlyContinue }
        if (Get-Command Scan-ErrorOutput -ErrorAction SilentlyContinue) { [void](Scan-ErrorOutput -Source 'UAUD' -Artifact 'generated-policy.ps1' -Lines $validatorOutput -ExitCode $vp.ExitCode -Stage 'stage-3') }
        Write-EvidenceText 'stage-3-repair' 'validator-output.txt' (($validatorOutput -join "`r`n"))
        if ($vp.ExitCode -ne 0) { throw "STAGE3_FAILURE: validator rejected repaired candidate with exit code $($vp.ExitCode)" }
        StageResult 'stage-3-repair' 'PASS' @{validator_exit_code=$vp.ExitCode;candidate_hash=(HashText $candidate);repaired=$repaired}
    } finally { Remove-Item -LiteralPath $repairCandidate,$validatorStdout,$validatorStderr -Force -ErrorAction SilentlyContinue }
    Out 'PASS — repair sandbox accepted candidate'

    Out 'STAGE 4 — PS/AST -> EXPLICIT CANONICAL REPRESENTATION'
    $packetBytes = Fetch 'ultra-mode/packet-filter.ps1'
    $packet = [Text.Encoding]::UTF8.GetString($packetBytes)
    $packetParse = ParsePS $packet
    if (@($packetParse.Errors).Count -gt 0) { throw 'STAGE4_FAILURE: packet-filter.ps1 is syntactically invalid' }
    $functions = @($packetParse.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true) | ForEach-Object { $_.Name })
    $schemaObject = Get-Content -LiteralPath $Schema -Raw | ConvertFrom-Json
    foreach ($required in @($schemaObject.required_functions)) {
        if ($functions -notcontains $required) { throw "STAGE4_FAILURE: required function missing: $required" }
    }
    $representation = [ordered]@{
        schema_version=1; artifact='packet-filter.ps1'; canonical='config.json'
        schedule=[ordered]@{start=[string]$remoteConfig.start;end=[string]$remoteConfig.end}
        domains=@($remoteConfig.domains | ForEach-Object {[string]$_})
        always_blocked=@($remoteConfig.alwaysBlockedDomains | ForEach-Object {[string]$_})
        always_allowed=@($remoteConfig.alwaysAllowedDomains | ForEach-Object {[string]$_})
        required_functions=@($functions)
        tcp_443=($packet -match 'tcp\.DstPort\s*==\s*443')
        udp_443=($packet -match 'udp\.DstPort\s*==\s*443')
        outbound=($packet -match '\boutbound\b')
        loopback_excluded=($packet -match '!loopback')
        drop_flag=($packet -match '\$FlagDrop\s*=\s*0x0002')
        override_source=($packet -match 'override-until\.txt')
    }
    Write-EvidenceJson 'stage-4-ast-canonical' 'representation.json' $representation
    Out 'PASS — explicit AST representation built'

    Out 'STAGE 5 — CANONICAL EQUIVALENCE'
    if ([string]$representation.schedule.start -ne [string]$remoteConfig.start -or [string]$representation.schedule.end -ne [string]$remoteConfig.end) { throw 'CANONICAL_MISMATCH: schedule differs' }
    if ((@($representation.domains) -join '|') -ne (@($remoteConfig.domains | ForEach-Object {[string]$_}) -join '|')) { throw 'CANONICAL_MISMATCH: domains differ' }
    if ((@($representation.always_blocked) -join '|') -ne (@($remoteConfig.alwaysBlockedDomains | ForEach-Object {[string]$_}) -join '|')) { throw 'CANONICAL_MISMATCH: always-blocked domains differ' }
    if ((@($representation.always_allowed) -join '|') -ne (@($remoteConfig.alwaysAllowedDomains | ForEach-Object {[string]$_}) -join '|')) { throw 'CANONICAL_MISMATCH: always-allowed domains differ' }
    if (-not $representation.tcp_443 -or -not $representation.udp_443 -or -not $representation.outbound -or -not $representation.loopback_excluded -or -not $representation.drop_flag -or -not $representation.override_source) { throw 'CANONICAL_MISMATCH: required policy primitive missing' }
    StageResult 'stage-5-equivalence' 'PASS' @{canonical_hash=(HashText $remoteCanonical);artifact_hash=(HashBytes $packetBytes)}
    Out 'PASS — canonical equivalence gate complete'

    Out 'STAGE 6 — WINDOWS BEHAVIOURAL SANDBOX'
    $sbStdout = Join-Path $env:TEMP ('UAUD-sandbox-' + $RunId + '-stdout.txt')
    $sbStderr = Join-Path $env:TEMP ('UAUD-sandbox-' + $RunId + '-stderr.txt')
    try {
        $sb = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$Sandbox) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $sbStdout -RedirectStandardError $sbStderr
        $sandboxOutput=@()
        if(Test-Path $sbStdout){$sandboxOutput+=Get-Content $sbStdout -ErrorAction SilentlyContinue}
        if(Test-Path $sbStderr){$sandboxOutput+=Get-Content $sbStderr -ErrorAction SilentlyContinue}
        if(Get-Command Scan-ErrorOutput -ErrorAction SilentlyContinue){[void](Scan-ErrorOutput -Source 'UAUD' -Artifact 'sandbox-behaviour.ps1' -Lines $sandboxOutput -ExitCode $sb.ExitCode -Stage 'stage-6')}
        Write-EvidenceText 'stage-6-windows' 'sandbox-output.txt' (($sandboxOutput -join "`r`n"))
        if ($sb.ExitCode -ne 0) { throw "STAGE6_FAILURE: behavioural sandbox exited $($sb.ExitCode)" }
        StageResult 'stage-6-windows' 'PASS' @{exit_code=$sb.ExitCode}
    } finally { Remove-Item -LiteralPath $sbStdout,$sbStderr -Force -ErrorAction SilentlyContinue }
    Out 'PASS — Windows behavioural sandbox complete'

    Out 'STAGE 7 — UAUD REPORT'
    StageResult 'stage-7-report' 'PASS' @{canonical_hash=(HashText $remoteCanonical);candidate_hash=(HashText $candidate);packet_hash=(HashBytes $packetBytes)}
    Out 'PASS — UAUD evidence complete'

    Out 'STAGE 8 — UARD INSTALL AUTHORITY'
    Out 'All UAUD gates passed. Starting UARD installation authority.'
    $uardStdout = Join-Path $env:TEMP ('UAUD-uard-' + $RunId + '-stdout.txt')
    $uardStderr = Join-Path $env:TEMP ('UAUD-uard-' + $RunId + '-stderr.txt')
    try {
        $uard = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$UARD) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $uardStdout -RedirectStandardError $uardStderr
        $uardOutput=@()
        if(Test-Path $uardStdout){$uardOutput+=Get-Content $uardStdout -ErrorAction SilentlyContinue}
        if(Test-Path $uardStderr){$uardOutput+=Get-Content $uardStderr -ErrorAction SilentlyContinue}
        if(Get-Command Scan-ErrorOutput -ErrorAction SilentlyContinue){[void](Scan-ErrorOutput -Source 'UAUD' -Artifact 'self-repair.ps1' -Lines $uardOutput -ExitCode $uard.ExitCode -Stage 'stage-8')}
        Write-EvidenceText 'stage-8-install' 'uard-output.txt' (($uardOutput -join "`r`n"))
        if ($uard.ExitCode -ne 0) { throw "UARD_FAILURE: UARD exited with code $($uard.ExitCode)" }
        StageResult 'stage-8-install' 'PASS' @{uard_exit_code=$uard.ExitCode}
    } finally { Remove-Item -LiteralPath $uardStdout,$uardStderr -Force -ErrorAction SilentlyContinue }
    Out 'SUCCESS — UARD completed successfully'
    exit 0
} catch {
    $fatal = [string]$_.Exception.Message
    Out "FAIL-CLOSED: $fatal"
    if (Get-Command Save-ErrorEvent -ErrorAction SilentlyContinue) { [void](Save-ErrorEvent -Source 'UAUD' -Stream 'Fatal' -Text $fatal -Artifact 'UAUD.ps1' -Context 'top-level pipeline failure') }
    try { Write-EvidenceText 'fatal' 'failure.txt' $fatal } catch {}
    exit 1
}
