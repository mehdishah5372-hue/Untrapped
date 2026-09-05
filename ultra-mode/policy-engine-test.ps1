$ErrorActionPreference="Stop"
. (Join-Path $PSScriptRoot "PolicyEngine.ps1")
$p=Read-PolicyConfig
if($p.AllowedVideoIds.Count -lt 1){throw "No allowlisted IDs"}
$id=@($p.AllowedVideoIds)[0]
$cases=@(
 @{u="https://m.youtube.com/watch?v=$id&vl=en";d="ALLOW"},
 @{u="https://www.youtube.com/watch?vl=en&v=$id";d="ALLOW"},
 @{u="https://www.youtube.com/watch?v=$id#x";d="ALLOW"},
 @{u="https://www.youtube.com/watch?V=$id";d="BLOCK"},
 @{u="https://www.youtube.com/watch?v=$id&v=dQw4w9WgXcQ";d="BLOCK"},
 @{u="https://www.youtube.com/shorts/2wgg7KtzTrU";d="BLOCK"},
 @{u="https://youtu.be/$id";d="BLOCK"},
 @{u="http://www.youtube.com/watch?v=$id";d="BLOCK"},
 @{u="https://evil.youtube.com/watch?v=$id";d="BLOCK"},
 @{u="https://www.youtube.com/watch?v=dQw4w9WgXcQ";d="BLOCK"}
)
foreach($c in $cases){$r=Resolve-PolicyDecision $c.u $p;if($r.Decision -cne $c.d){throw "POLICY MISMATCH $($c.u): expected=$($c.d) actual=$($r.Decision)"}}
Write-Host "POLICY ENGINE PASS: $($cases.Count) deterministic cases"