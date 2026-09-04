# Remote observable harness — safe, parser-only + explicitly sandboxed helper execution.
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$Run=Join-Path $Root ('uaud-evidence\remote-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $Run -Force | Out-Null

function Save-J([string]$Stage,[string]$Name,[object]$Object) {
    $d=Join-Path $Run $Stage
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $d $Name) -Encoding UTF8
}
function Save-T([string]$Stage,[string]$Name,[string]$Text) {
    $d=Join-Path $Run $Stage
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    [string]$Text | Set-Content -LiteralPath (Join-Path $d $Name) -Encoding UTF8
}
function Parse-File([string]$Path) {
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    [pscustomobject]@{path=$Path;errors=@($errors)}
}

$files=@('config.json','packet-filter.ps1','self-repair.ps1','ErrorLibrary.ps1','UAUD-validate.ps1','UAUD.ps1','evidence.ps1','observable-pipeline.json')
$summary=@()
foreach($name in $files) {
    $path=Join-Path $Root $name
    if(-not(Test-Path -LiteralPath $path)) { throw "Required remote artifact missing: $name" }
    $stage='validate-'+([IO.Path]::GetFileNameWithoutExtension($name))
    if($name.EndsWith('.ps1')) {
        $parsed=Parse-File $path
        $ok=@($parsed.errors).Count -eq 0
        $details=@($parsed.errors | ForEach-Object {
            [ordered]@{message=$_.Message;line=$_.Extent.StartLineNumber;column=$_.Extent.StartColumnNumber}
        })
    } elseif($name -in @('config.json','observable-pipeline.json')) {
        try {
            $null=Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $ok=$true;$details=@()
        } catch {
            $ok=$false;$details=@([ordered]@{message=$_.Exception.Message;line=0;column=0})
        }
    } else { throw "Unsupported remote validation artifact type: $name" }
    Save-J $stage 'result.json' ([ordered]@{stage=$stage;file=$name;result=if($ok){'PASS'}else{'FAIL'};errors=$details})
    $summary += [ordered]@{stage=$stage;result=if($ok){'PASS'}else{'FAIL'};file=$name}
    if(-not $ok) {
        $details | ForEach-Object { Write-Error ($name+':'+$_.line+':'+$_.column+': '+$_.message) }
        exit 1
    }
}

$behaviourPath=Join-Path $Root 'sandbox-behaviour.ps1'
try {
    $out=& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $behaviourPath 2>&1 | Out-String
    Save-T 'behaviour' 'stdout.txt' $out
    Save-J 'behaviour' 'result.json' ([ordered]@{stage='behaviour';result='PASS';exit_code=0})
    $summary += [ordered]@{stage='behaviour';result='PASS'}
} catch {
    $message=$_.Exception.Message
    Save-T 'behaviour' 'stderr.txt' $message
    Save-J 'behaviour' 'result.json' ([ordered]@{stage='behaviour';result='FAIL';error=$message;exit_code=1})
    $summary += [ordered]@{stage='behaviour';result='FAIL'}
    Write-Error $message
    exit 1
}

Save-J 'run' 'input.json' ([ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');files=$files})
Save-J 'run' 'result.json' ([ordered]@{result='SUCCESS';stages=$summary;completed_utc=[DateTime]::UtcNow.ToString('o')})
Write-Host 'REMOTE UAUD HARNESS PASS'
Write-Host ('EVIDENCE_ROOT: '+$Run)
Write-Host ('STAGES: '+$summary.Count)
