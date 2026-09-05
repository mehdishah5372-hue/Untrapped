$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'YouTubePolicy.ps1')
$config=Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
$policyConfig=Get-Content (Join-Path (Split-Path $Root -Parent) 'policy-config.json') -Raw | ConvertFrom-Json
if((ConvertTo-Json $policyConfig -Compress -Depth 10) -ne (ConvertTo-Json ([ordered]@{youtubePolicy=$config.youtubePolicy;allowedYouTubeVideoIds=@($config.allowedYouTubeVideoIds)}) -Compress -Depth 10)){throw 'Browser policy snapshot diverges from canonical ultra-mode/config.json.'}

$allowed='AAAAAAAAAAA'
$testConfig=[pscustomobject]@{youtubePolicy=[pscustomobject]@{allowAdditionalQueryParameters=$true};allowedYouTubeVideoIds=@($allowed)}
$cases=New-Object System.Collections.Generic.List[object]
function Add-Case([string]$Url,[string]$Expected,[string]$Name){$cases.Add([pscustomobject]@{name=$Name;url=$Url;expected=$Expected})}
Add-Case "https://www.youtube.com/watch?v=$allowed" 'ALLOW' 'canonical'
Add-Case "https://youtube.com/watch?v=$allowed&hl=en" 'ALLOW' 'extra-query'
Add-Case "https://m.youtube.com/watch?v=$allowed&vl=en" 'ALLOW' 'mobile'
Add-Case "https://www.youtube.com/watch?V=$allowed" 'BLOCK' 'uppercase-V'
Add-Case "https://www.youtube.com/watch?v=$allowed&v=BBBBBBBBBBB" 'BLOCK' 'duplicate-v'
Add-Case "https://www.youtube.com/watch?v=BBBBBBBBBBB" 'BLOCK' 'wrong-id'
Add-Case "https://www.youtube.com/watch?v=$allowed#fragment" 'BLOCK' 'fragment'
Add-Case "https://www.youtube.com/shorts/$allowed" 'BLOCK' 'shorts'
Add-Case "https://www.youtube.com/embed/$allowed" 'BLOCK' 'embed'
Add-Case "https://www.youtube.com/live/$allowed" 'BLOCK' 'live'
Add-Case "https://youtu.be/$allowed" 'BLOCK' 'short-host'
Add-Case "http://www.youtube.com/watch?v=$allowed" 'BLOCK' 'http'
Add-Case "https://www.youtube.com:444/watch?v=$allowed" 'BLOCK' 'port'
Add-Case "https://user:pass@www.youtube.com/watch?v=$allowed" 'BLOCK' 'credentials'
Add-Case "https://www.youtube.com/watch?v=%41AAAAAAAAAA" 'BLOCK' 'encoded-value'
Add-Case "https://www.youtube.com/watch?v=$allowed%" 'BLOCK' 'malformed-percent'
Add-Case "https://www.youtube.com/watch?v=$allowed&%56=$allowed" 'BLOCK' 'encoded-key'
Add-Case "https://www.youtube.com/watch?x=1&v=$allowed" 'ALLOW' 'reordered'
Add-Case "https://www.youtube.com/watch?v=$allowed&v=" 'BLOCK' 'second-empty-v'
Add-Case "https://www.youtube.com/watch?v=" 'BLOCK' 'empty-v'
Add-Case "https://www.youtube.com/watch?x=$allowed" 'BLOCK' 'missing-v'
Add-Case "https://www.youtube.com/watch?v=AAAAAAAAAA!" 'BLOCK' 'invalid-id-character'

$rng=[Random]::new(73129)
$chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-'
for($i=0;$i -lt 30000;$i++){
  $id=-join (1..11|ForEach-Object{$chars[$rng.Next(0,$chars.Length)]})
  if($id -eq $allowed){$id='BBBBBBBBBBB'}
  Add-Case "https://www.youtube.com/watch?v=$id" 'BLOCK' "random-$i"
}

$payload=Join-Path $env:TEMP ('untrapped-policy-'+[guid]::NewGuid().ToString('N')+'.json')
$cases|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $payload -Encoding UTF8
try{
  $nodeScript='const fs=require(''fs''); const p=require(process.argv[1]); const c=JSON.parse(fs.readFileSync(process.argv[2],''utf8'')); for(const x of c){let d; try{d=p.decideYouTubeUrl(x.url,{youtubePolicy:{allowAdditionalQueryParameters:true},allowedYouTubeVideoIds:[''AAAAAAAAAAA'']});}catch(e){d={decision:''BLOCK'',reason:''policy-evaluation-error''};} process.stdout.write(JSON.stringify({name:x.name,url:x.url,decision:d.decision,reason:d.reason})+''\n'');}'
  $nodeOut=& node -e $nodeScript (Join-Path $Root 'policy.js') $payload
  if($LASTEXITCODE -ne 0){throw 'Node policy engine exited non-zero.'}
  $browser=@($nodeOut|ForEach-Object{$_|ConvertFrom-Json})
  if($browser.Count -ne $cases.Count){throw "Browser corpus count mismatch: $($browser.Count) vs $($cases.Count)."}
  $mismatches=@()
  for($i=0;$i -lt $cases.Count;$i++){
    $ps=Resolve-YouTubePolicy $cases[$i].url $testConfig
    if($ps.decision -cne $browser[$i].decision -or $ps.decision -cne $cases[$i].expected){$mismatches += [pscustomobject]@{name=$cases[$i].name;url=$cases[$i].url;expected=$cases[$i].expected;powershell=$ps.decision;browser=$browser[$i].decision;ps_reason=$ps.reason;browser_reason=$browser[$i].reason}}
  }
  if($mismatches.Count){$mismatches|ConvertTo-Json -Depth 10|Set-Content (Join-Path $Root 'policy-differential-failures.json') -Encoding UTF8;throw "Policy differential failures: $($mismatches.Count)."}
  Write-Host "POLICY DIFFERENTIAL PASS: $($cases.Count) browser/PowerShell cases, including 30,000 randomized IDs."
}finally{Remove-Item $payload -Force -ErrorAction SilentlyContinue}
