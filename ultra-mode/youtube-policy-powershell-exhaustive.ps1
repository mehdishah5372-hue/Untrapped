$ErrorActionPreference='Stop'
$rules=Get-Content './youtube-allowlist.json' -Raw|ConvertFrom-Json
$ids=@($rules.allowedYouTubeUrls|ForEach-Object{([Uri]$_.url).Query -replace '^\?v=([^&]+).*','$1'}|Where-Object{$_})
if($ids.Count -lt 1){throw 'No allowed IDs'}
function Test-Policy([string]$url){
  try{$u=[Uri]$url}catch{return $false}
  if($u.Scheme -ne 'https' -or $u.Host -notmatch '^(www\.)?(m\.)?youtube\.com$' -or $u.AbsolutePath -ne '/watch'){return $false}
  $pairs=$u.Query.TrimStart('?') -split '&' | Where-Object{$_ -ne ''}
  $vs=@($pairs|Where-Object{$_ -cmatch '^v='})
  if($vs.Count -ne 1){return $false}
  $id=$vs[0].Substring(2)
  return ($ids -ccontains $id -and $id -match '^[A-Za-z0-9_-]{11}$')
}
$allowId=$ids[0]
$allowed=@("https://m.youtube.com/watch?v=$allowId","https://www.youtube.com/watch?vl=en&v=$allowId","https://youtube.com/watch?utm_source=x&v=$allowId&hl=en","https://www.youtube.com/watch?v=$allowId#fragment","https://www.youtube.com/watch?hl=en&v=$allowId&utm_campaign=x&t=120")
foreach($u in $allowed){if(-not(Test-Policy $u)){throw "FALSE BLOCK: $u"}}
$fixedBlocked=@('https://www.youtube.com/watch?v=dQw4w9WgXcQ','https://www.youtube.com/shorts/2wgg7KtzTrU','https://www.youtube.com/results?search_query=test','https://youtu.be/2wgg7KtzTrU',"http://www.youtube.com/watch?v=$allowId","https://www.youtube.com/watch?v=$allowId&v=dQw4w9WgXcQ","https://evil.youtube.com/watch?v=$allowId","https://www.youtube.com/channel/$allowId")
foreach($u in $fixedBlocked){if(Test-Policy $u){throw "FALSE ALLOW: $u"}}
$rng=[Random]::new(734821);$chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';$tested=0
for($i=0;$i -lt 10000;$i++){
  $n='';for($j=0;$j -lt 11;$j++){$n+=$chars[$rng.Next($chars.Length)]};if($n -eq $allowId){$i--;continue}
  $forms=@("https://www.youtube.com/watch?v=$n","https://m.youtube.com/watch?hl=en&v=$n&utm_source=x","https://youtube.com/watch?utm_medium=x&v=$n#x")
  foreach($u in $forms){$tested++;if(Test-Policy $u){throw "RANDOM FALSE ALLOW: $u"}}
}
$boundary=@("https://www.youtube.com/watch?v=$allowId&v=","https://www.youtube.com/watch?v=$allowId%20","https://www.youtube.com/watch?v=$allowId%26x","https://www.youtube.com/watch?x=1&v=$allowId&v=$allowId","https://www.youtube.com/watch?V=$allowId","https://www.youtube.com/watch?v=${allowId}x","https://www.youtube.com/watch?v=$allowId&bad","https://www.youtube.com/watch?x=1&v=$allowId&x=2")
foreach($u in $boundary){$expect=$u -eq "https://www.youtube.com/watch?x=1&v=$allowId&x=2";$actual=Test-Policy $u;if($actual -ne $expect){throw "BOUNDARY MISMATCH expected=$expect actual=$actual $u"}}
Write-Host "POWERSHELL EXHAUSTIVE YOUTUBE POLICY PASS: $tested random non-allowed URLs + $($allowed.Count) allowed variants + $($fixedBlocked.Count) fixed denies + $($boundary.Count) boundaries"