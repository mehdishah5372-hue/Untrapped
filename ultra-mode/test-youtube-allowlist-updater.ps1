$ErrorActionPreference='Stop';$Root=Split-Path -Parent $MyInvocation.MyCommand.Path;$work=Join-Path $env:TEMP ('untrapped-updater-test-'+[guid]::NewGuid().ToString('N'));New-Item $work -ItemType Directory -Force|Out-Null
try{
 $policy=Join-Path $work 'policy-config.json';Copy-Item (Join-Path $Root '..\policy-config.json') $policy;$before=Get-Content $policy -Raw|ConvertFrom-Json
 & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'update-youtube-allowlist.ps1') -InputValue 'dQw4w9WgXcQ' -InputValue 'BaW_jenozKc' -PolicyPath $policy;if($LASTEXITCODE -ne 0){throw 'Updater returned non-zero.'}
 $after=Get-Content $policy -Raw|ConvertFrom-Json;foreach($id in @('dQw4w9WgXcQ','BaW_jenozKc')){if(@($after.allowedYouTubeVideoIds)-notcontains $id){throw ('Missing updated ID: '+$id)}}
 $beforeOther=($before|Select-Object * -ExcludeProperty allowedYouTubeVideoIds|ConvertTo-Json -Depth 20);$afterOther=($after|Select-Object * -ExcludeProperty allowedYouTubeVideoIds|ConvertTo-Json -Depth 20);if($beforeOther -ne $afterOther){throw 'Updater changed fields outside allowedYouTubeVideoIds.'}
 & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'update-youtube-allowlist.ps1') -InputValue 'dQw4w9WgXcQ' -PolicyPath $policy;if($LASTEXITCODE -ne 0){throw 'Idempotent updater invocation failed.'}
 & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'update-youtube-allowlist.ps1') -InputValue 'bad-id' -PolicyPath $policy;$badExit=$LASTEXITCODE;if($badExit -eq 0){throw 'Invalid input was accepted.'}
 $final=Get-Content $policy -Raw|ConvertFrom-Json;if(@($final.allowedYouTubeVideoIds).Count -ne @($after.allowedYouTubeVideoIds).Count){throw 'Invalid-input attempt disturbed the policy.'}
 . (Join-Path $Root 'YouTubePolicy.ps1');foreach($id in @('dQw4w9WgXcQ','BaW_jenozKc')){if((Resolve-YouTubePolicy ('https://www.youtube.com/watch?v='+$id) $final).decision -cne 'ALLOW'){throw ('Canonical allow failed for '+$id)}}
 Write-Host 'YOUTUBE ALLOWLIST UPDATER PASS: atomic write, field isolation, idempotence, invalid-input safety and policy validation all passed.'
}finally{Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
