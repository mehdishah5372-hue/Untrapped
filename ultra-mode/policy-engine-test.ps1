$ErrorActionPreference="Stop"
. "$PSScriptRoot\PolicyEngine.ps1"
$p=Read-PolicyConfig
$id=[string]$p.AllowedVideoIds[0]
Write-Host "Loaded allowlisted ID: $id"
function Assert-Decision($u,$expected){
  $x=Resolve-PolicyDecision -Url $u -Policy $p
  Write-Host "$($x.Decision) expected=$expected $u"
  if([string]$x.Decision -cne $expected){throw "POLICY MISMATCH expected=$expected actual=$($x.Decision) url=$u"}
}
Assert-Decision "https://m.youtube.com/watch?v=$id&vl=en" "ALLOW"
Assert-Decision "https://www.youtube.com/watch?vl=en&v=$id" "ALLOW"
Assert-Decision "https://www.youtube.com/watch?v=$id#x" "ALLOW"
Assert-Decision "https://www.youtube.com/watch?V=$id" "BLOCK"
Assert-Decision "https://www.youtube.com/watch?v=$id&v=dQw4w9WgXcQ" "BLOCK"
Assert-Decision "https://www.youtube.com/shorts/$id" "BLOCK"
Assert-Decision "https://youtu.be/$id" "BLOCK"
Assert-Decision "http://www.youtube.com/watch?v=$id" "BLOCK"
Assert-Decision "https://evil.youtube.com/watch?v=$id" "BLOCK"
Assert-Decision "https://www.youtube.com/watch?v=dQw4w9WgXcQ" "BLOCK"
Write-Host "POLICY ENGINE PASS: 10 deterministic cases"
