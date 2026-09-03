# UAUD validation engine 1.0.0
# Validates a candidate PowerShell artifact without executing the candidate.
# Behavioural execution is deliberately delegated to an isolated Windows CI/VM stage.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ErrorLibrary=Join-Path $Root 'ErrorLibrary.ps1'
if(Test-Path -LiteralPath $ErrorLibrary){. $ErrorLibrary}
$ReportDir=Join-Path $Root 'uaud-reports'
New-Item -ItemType Directory -Path $ReportDir -Force|Out-Null
$MaxAttempts=50
$RepeatedErrorThreshold=5
$EmergencyCeiling=200

function Write-Event([string]$Message){Write-Host ('[UAUD '+(Get-Date -Format HH:mm:ss)+'] '+$Message)}
function Hash-Text([string]$Text){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Get-ParserResult([string]$Source){
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
    if(@($errors).Count -eq 0){return [pscustomobject]@{pass=$true;errors=@();ast=$ast}}
    $items=@($errors|ForEach-Object{[ordered]@{message=$_.Message;line=$_.Extent.StartLineNumber;column=$_.Extent.StartColumnNumber;end_line=$_.Extent.EndLineNumber;end_column=$_.Extent.EndColumnNumber}})
    [pscustomobject]@{pass=$false;errors=$items;ast=$ast}
}
function Get-CanonicalProjection([string]$Source){
    # Conservative structural projection: the AST is inspected, not executed.
    $r=Get-ParserResult $Source
    if(-not $r.pass){return $null}
    $commands=@($r.ast.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()})
    $paths=@($r.ast.FindAll({param($n)$n -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true)|ForEach-Object{$_.Value})
    [ordered]@{command_names=@($commands);string_literals=@($paths);ast_type=$r.ast.GetType().FullName}
}
function Invoke-DeterministicRepair([string]$Source,[object]$ParserResult){
    # Repair is intentionally conservative. Only parser-local, mechanically safe edits belong here.
    # No network, firewall, WFP, DNS, Hosts, VPN, adapter, or override-policy change is performed.
    $out=$Source
    foreach($e in @($ParserResult.errors)){
        if($e.message -match '(?i)missing.*closing.*brace|missing.*}'){$out=$out.TrimEnd()+"`n}"}
        elseif($e.message -match '(?i)missing.*closing.*parenthesis|missing.*\)'){$out=$out.TrimEnd()+"`n)"}
        elseif($e.message -match '(?i)missing.*closing.*bracket|missing.*\]'){$out=$out.TrimEnd()+"`n]"}
        else{return [pscustomobject]@{changed=$false;source=$Source;action='NO_SAFE_DETERMINISTIC_REPAIR'}}
    }
    [pscustomobject]@{changed=($out -ne $Source);source=$out;action='BALANCED_MISSING_DELIMITER'}
}
function Test-Progress([string]$Old,[string]$New,[object]$OldResult,[object]$NewResult){
    if($NewResult.pass -and -not $OldResult.pass){return $true}
    $oldCount=@($OldResult.errors).Count;$newCount=@($NewResult.errors).Count
    if($newCount -lt $oldCount){return $true}
    return $false
}
function Write-RunReport($obj,[string]$Artifact){$name=([IO.Path]::GetFileName($Artifact))+'.'+(Get-Date -Format 'yyyyMMdd-HHmmssfff')+'.json';$p=Join-Path $ReportDir $name;$obj|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $p -Encoding UTF8;Write-Event ('REPORT '+$p);return $p}

param([Parameter(Mandatory=$true)][string]$Candidate,[string]$Canonical,[string]$Artifact='candidate.ps1')
$history=New-Object 'System.Collections.Generic.List[object]';$perError=@{};$attempt=0;$source=Get-Content -LiteralPath $Candidate -Raw -Encoding UTF8;$previousHash='';
while($true){
    $attempt++
    if($attempt -gt $EmergencyCeiling){$verdict='EMERGENCY_CEILING';break}
    if($attempt -gt $MaxAttempts){$verdict='REPAIR_ATTEMPT_CEILING';break}
    $candidateHash=Hash-Text $source
    Write-Event ("SYNTAX attempt $attempt candidate=$candidateHash")
    $r=Get-ParserResult $source
    if($r.pass){Write-Event 'SYNTAX PASS';$verdict=if($attempt -eq 1){'SYNTAX_PASS'}else{'SYNTAX_REPAIR_SUCCESS'};break}
    foreach($e in @($r.errors)){
        $fp=Get-ErrorFingerprint $e.message 'PARSER'
        if(-not $perError.ContainsKey($fp)){$perError[$fp]=0};$perError[$fp]++
        if(Get-Command Save-ErrorEvent -ErrorAction SilentlyContinue){[void](Save-ErrorEvent -Source 'UAUD' -Stream 'Parser' -Text $e.message -Artifact $Artifact -CandidateHash $candidateHash -PreviousCandidateHash $previousHash -Attempt $attempt -SyntaxResult 'FAIL' -Context ("line=$($e.line) column=$($e.column)"))}
        $history.Add([ordered]@{attempt=$attempt;fingerprint=$fp;message=$e.message;line=$e.line;column=$e.column})
        if($perError[$fp] -ge $RepeatedErrorThreshold){Write-Event ("COOKED_REPEATED_ERROR fingerprint=$fp count=$($perError[$fp])");$verdict='COOKED_REPEATED_ERROR';break}
    }
    if($verdict -eq 'COOKED_REPEATED_ERROR'){break}
    $repair=Invoke-DeterministicRepair $source $r
    if(-not $repair.changed){$verdict='UNKNOWN_ERROR';break}
    $newResult=Get-ParserResult $repair.source
    if(-not(Test-Progress $source $repair.source $r $newResult)){$verdict='NON_PROGRESSING_REPAIR';break}
    Write-Event ('REPAIR '+$repair.action)
    $previousHash=$candidateHash;$source=$repair.source
}

if($verdict -in @('SYNTAX_PASS','SYNTAX_REPAIR_SUCCESS') -and $Canonical){
    Write-Event 'ROUND-TRIP / CANONICAL GATE'
    try{$canonObj=Get-Content -LiteralPath $Canonical -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$verdict='CANONICAL_INVALID';$canonObj=$null}
    $projection=Get-CanonicalProjection $source
    if($null -eq $projection){$verdict='AST_FAILURE'}
    else{
        # Exact canonical comparison is supplied by the artifact-specific validator manifest.
        # This gate refuses to claim equality from a generic AST projection.
        Write-Event 'AST PASS; artifact-specific canonical comparator required before install.'
        $verdict='AST_PASS_CANONICAL_COMPARATOR_REQUIRED'
    }
}
$report=[ordered]@{schema=1;uaud_version='1.0.0';artifact=$Artifact;candidate_hash=Hash-Text $source;attempts=$attempt;error_history=@($history);per_error=$perError;final_verdict=$verdict;behavioural_stage='NOT_RUN_BY_CLIENT';install_allowed=$false;candidate_path=$Candidate;canonical_path=$Canonical}
Write-RunReport $report $Artifact|Out-Null
$report|ConvertTo-Json -Depth 20
if($verdict -in @('SYNTAX_PASS','SYNTAX_REPAIR_SUCCESS')){exit 0}else{exit 1}
