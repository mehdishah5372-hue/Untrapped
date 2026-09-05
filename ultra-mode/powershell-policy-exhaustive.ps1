$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'YouTubePolicy.ps1')
$cfg=[pscustomobject]@{youtubePolicy=[pscustomobject]@{allowAdditionalQueryParameters=$true};allowedYouTubeVideoIds=@('AAAAAAAAAAA')}
$cases=@(
 @{u='https://www.youtube.com/watch?v=AAAAAAAAAAA';e='ALLOW';n='canonical'},
 @{u='https://www.youtube.com/watch?v=AAAAAAAAAAA&hl=en';e='ALLOW';n='extra'},
 @{u='https://m.youtube.com/watch?v=AAAAAAAAAAA&vl=en';e='ALLOW';n='mobile'},
 @{u='https://www.youtube.com/watch?V=AAAAAAAAAAA';e='BLOCK';n='uppercase-V'},
 @{u='https://www.youtube.com/watch?v=AAAAAAAAAAA&v=BBBBBBBBBBB';e='BLOCK';n='duplicate-v'},
 @{u='https://www.youtube.com/watch?v=BBBBBBBBBBB';e='BLOCK';n='wrong-id'},
 @{u='https://www.youtube.com/watch?v=AAAAAAAAAAA#x';e='BLOCK';n='fragment'},
 @{u='https://www.youtube.com/shorts/AAAAAAAAAAA';e='BLOCK';n='shorts'},
 @{u='https://www.youtube.com/embed/AAAAAAAAAAA';e='BLOCK';n='embed'},
 @{u='https://www.youtube.com/live/AAAAAAAAAAA';e='BLOCK';n='live'},
 @{u='https://youtu.be/AAAAAAAAAAA';e='BLOCK';n='youtu-be'},
 @{u='http://www.youtube.com/watch?v=AAAAAAAAAAA';e='BLOCK';n='http'},
 @{u='https://www.youtube.com:444/watch?v=AAAAAAAAAAA';e='BLOCK';n='port'},
 @{u='https://user:pass@www.youtube.com/watch?v=AAAAAAAAAAA';e='BLOCK';n='credentials'},
 @{u='https://www.youtube.com/watch?v=%41AAAAAAAAAA';e='BLOCK';n='encoded-value'},
 @{u='https://www.youtube.com/watch?v=AAAAAAAAAAA%';e='BLOCK';n='bad-percent'},
 @{u='https://www.youtube.com/watch?v=AAAAAAAAAAA&%56=BBBBBBBBBBB';e='BLOCK';n='encoded-key'},
 @{u='https://www.youtube.com/watch?x=1&v=AAAAAAAAAAA';e='ALLOW';n='reordered'},
 @{u='https://www.youtube.com/watch?v=';e='BLOCK';n='empty'},
 @{u='https://www.youtube.com/watch?x=1';e='BLOCK';n='missing-v'},
 @{u='https://www.youtube.com/watch?v=AAAAAAAAAA!';e='BLOCK';n='invalid-char'}
)
$rng=[Random]::new(99117);$chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-'
for($i=0;$i -lt 30000;$i++){$id=-join(1..11|ForEach-Object{$chars[$rng.Next($chars.Length)]});if($id -eq 'AAAAAAAAAAA'){$id='BBBBBBBBBBB'};$cases+=@{u="https://www.youtube.com/watch?v=$id";e='BLOCK';n="random-$i"}}
$fail=@()
foreach($c in $cases){$r=Resolve-YouTubePolicy $c.u $cfg;if($r.decision -cne $c.e){$fail+=[pscustomobject]@{name=$c.n;url=$c.u;expected=$c.e;actual=$r.decision;reason=$r.reason}}}
if($fail.Count){$fail|ConvertTo-Json -Depth 10|Set-Content (Join-Path $Root 'powershell-policy-failures.json') -Encoding UTF8;throw "Exhaustive PowerShell policy gate failed with $($fail.Count) mismatches."}
Write-Host "EXHAUSTIVE POWERSHELL POLICY PASS: $($cases.Count) cases, including 30,000 random IDs and explicit parser attacks."
