# smoke.ps1 <skill-dir>: Windows counterpart of smoke.sh. Builds the mixed-leftovers fixture
# with Git Bash, starts a child process as a fake session process, runs audit.ps1, stops that PID.
param([string]$Skill)
$gitBash = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin\bash.exe'
$d = Join-Path $env:TEMP ("sc-smoke." + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $d | Out-Null; Set-Location $d
& $gitBash (Join-Path $Skill 'evals/plain-git-mixed-leftovers/place-files.sh').Replace('\', '/')
New-Item -ItemType Directory -Path (Join-Path $d 'app\coverage') | Out-Null; Set-Content (Join-Path $d 'app\coverage\i') '1'
$env:CLAUDE_CODE_SESSION_ID = "smoke-$PID"; $env:CLAUDE_PID = "$PID"
$child = Start-Process -FilePath ping.exe -ArgumentList '-n', '120', '127.0.0.1' -PassThru -WindowStyle Hidden
Start-Sleep 2
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Skill 'scripts\audit.ps1') -Repo (Join-Path $d 'app') -Since '2000-01-01T00:00:00Z'
$rc = $LASTEXITCODE
Stop-Process -Id $child.Id -ErrorAction SilentlyContinue
Write-Output "smoke_rc=$rc fixture=$d"
