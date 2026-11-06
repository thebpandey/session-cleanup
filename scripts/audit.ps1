<#
audit.ps1 [-NoFetch] [-Repo <path>] [-Since <ISO-8601>] [-BigMB <N>]

Read-only end-of-session audit for Windows (PowerShell 5.1 and 7+). Linux/macOS: use audit.sh.
Prints one section per area as "key: value" lines, matching audit.sh.
The only write it ever performs is `git fetch` (never prunes); pass -NoFetch to skip even that.
It never deletes, kills, stashes or resets anything, and never reads .env files.
Process ownership: Windows does not expose other processes' environments or working
directories, so "this_session" means a descendant of the Claude process (CLAUDE_PID), and
"in_repo" means the command line mentions the repo path.
#>
[CmdletBinding()]
param(
  [switch]$NoFetch,
  [string]$Repo = "",
  [string]$Since = "",
  [int]$BigMB = 50
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

function Hdr($t) { Write-Output ""; Write-Output "=== $t ===" }
function Age([datetime]$t) {
  $s = [int]((Get-Date) - $t).TotalSeconds; if ($s -lt 0) { $s = 0 }
  if ($s -ge 86400) { return ('{0}d{1}h' -f [math]::Floor($s / 86400), [math]::Floor(($s % 86400) / 3600)) }
  if ($s -ge 3600) { return ('{0}h{1}m' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60)) }
  return ('{0}m' -f [math]::Floor($s / 60))
}
function FromEpoch([long]$e) { return ([datetime]'1970-01-01Z').ToUniversalTime().AddSeconds($e).ToLocalTime() }
function Size($p) {
  try {
    $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
      $b = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    } else { $b = $item.Length }
    if (-not $b) { $b = 0 }
    if ($b -ge 1GB) { return ('{0:N1}G' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1}M' -f ($b / 1MB)) }
    return ('{0:N0}K' -f [math]::Ceiling($b / 1KB))
  } catch { return '?' }
}
function G { $out = & git @args 2>$null; return $out }   # git, stderr suppressed
function Under($path, $root) {
  if (-not $path -or -not $root) { return $false }
  $p = $path.Replace('/', '\').TrimEnd('\'); $r = $root.Replace('/', '\').TrimEnd('\')
  return ($p -ieq $r) -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

# ---------- context ----------
Hdr CONTEXT
Write-Output "os: Windows"
if ($Repo) { try { Set-Location -LiteralPath $Repo -ErrorAction Stop } catch { Write-Output "error: cannot cd to $Repo"; exit 1 } }
$inGit = $false
& git rev-parse --git-dir *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Output "git: not a git repository ($((Get-Location).Path)); git sections skipped"
} else {
  $inGit = $true
  $common = (G rev-parse --path-format=absolute --git-common-dir)
  $mainWt = (Split-Path -Parent ($common.Replace('/', '\')))
  $top = (G rev-parse --show-toplevel).Replace('/', '\')
  Write-Output "repo_main_worktree: $mainWt"
  Write-Output "current_worktree: $top"
  $cur = G branch --show-current; if (-not $cur) { $cur = 'DETACHED' }
  Write-Output "current_branch: $cur"
  $main = ""
  foreach ($b in 'main', 'master', 'trunk') { & git show-ref --verify --quiet "refs/heads/$b"; if ($LASTEXITCODE -eq 0) { $main = $b; break } }
  if (-not $main) { $h = G symbolic-ref --short refs/remotes/origin/HEAD; if ($h) { $main = $h -replace '^origin/', '' } }
  if (-not $main) { Write-Output "main_branch: UNKNOWN" } else { Write-Output "main_branch: $main" }
  $remotes = @(G remote)
  $remote = if ($remotes -contains 'origin') { 'origin' } elseif ($remotes.Count -gt 0) { $remotes[0] } else { '' }
  if ($remote) { Write-Output "remote: $remote" } else { Write-Output "remote: none" }
}

$sid = $env:CLAUDE_CODE_SESSION_ID
$claudePid = $env:CLAUDE_PID
Write-Output ("session_id: " + $(if ($sid) { $sid } else { 'unknown' }))
Write-Output ("claude_pid: " + $(if ($claudePid) { $claudePid } else { 'unknown' }))
$sinceDt = $null
if (-not $Since -and $sid) {
  $tx = Get-ChildItem -Path (Join-Path $HOME '.claude\projects') -Filter "$sid.jsonl" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($tx) {
    $m = Select-String -LiteralPath $tx.FullName -Pattern '"timestamp":"([^"]*)"' -List | Select-Object -First 1
    if ($m) { $Since = $m.Matches[0].Groups[1].Value }
  }
}
if ($Since) { try { $sinceDt = [datetime]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() } catch { $sinceDt = $null } }
if (-not $sinceDt -and $claudePid) {
  $cp = Get-Process -Id $claudePid -ErrorAction SilentlyContinue
  if ($cp) { $sinceDt = $cp.StartTime; $Since = 'claude process start' }
}
Write-Output ("session_start: " + $(if ($Since) { $Since } else { 'unknown' }) + " (items newer than this may belong to this session; older items are ASK)")
function Recent([datetime]$t) { return ($sinceDt -and $t -ge $sinceDt) }
function Tag([datetime]$t) { if (Recent $t) { 'this_session' } else { 'pre_session' } }

if ($inGit) {
  # ---------- working tree ----------
  Hdr WORKING_TREE
  $st = @(G status --porcelain=v1)
  if ($st.Count -eq 0) { Write-Output "status: clean" } else {
    Write-Output "status: $($st.Count) entries"
    $st | Select-Object -First 60 | ForEach-Object { "  $_" }
    $junkRe = '(\.orig|\.rej|\.log|\.bak|\.tmp|\.swp|~|\.png|\.jpe?g|\.webp|\.gif|\.mp4|\.webm|\.har|\.trace|\.zip|nohup\.out|\.DS_Store|Thumbs\.db)$|(^|/)(scratch|tmp|temp)[^/]*$'
    $junk = @($st | Where-Object { $_.StartsWith('??') } | ForEach-Object { $_.Substring(3).Trim('"') } | Where-Object { $_ -match $junkRe })
    if ($junk.Count) {
      Write-Output "junk_candidates:"
      foreach ($f in $junk) { $it = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if ($it) { Write-Output "  $f size=$(Size $f) age=$(Age $it.LastWriteTime) $(Tag $it.LastWriteTime)" } }
    }
    $envs = @($st | ForEach-Object { ($_ -split '\s+')[-1] } | Where-Object { $_ -match '(^|/)\.env' -and $_ -notmatch '\.example$' })
    if ($envs.Count) { Write-Output "WARNING: .env-like paths in status (do not read, print or delete): $($envs -join ' ')" }
  }

  # ---------- sync ----------
  Hdr SYNC
  if ($remote) {
    if (-not $NoFetch) {
      $job = Start-Job -ScriptBlock { param($d, $r) Set-Location -LiteralPath $d; $o = & git fetch --quiet $r 2>&1; "$LASTEXITCODE|$o" } -ArgumentList (Get-Location).Path, $remote
      if (Wait-Job $job -Timeout 60) { $res = Receive-Job $job; $rc, $msg = "$res" -split '\|', 2
        if ($rc -eq '0') { Write-Output "fetch: ok" } else { Write-Output "fetch: FAILED ($msg)" } }
      else { Stop-Job $job; Write-Output "fetch: FAILED (timed out after 60s)" }
      Remove-Job $job -Force
    } else { Write-Output "fetch: skipped (-NoFetch); results may be stale" }
    & git show-ref --verify --quiet "refs/remotes/$remote/$main"
    if ($main -and $LASTEXITCODE -eq 0) {
      $lr = (G rev-list --left-right --count "$remote/$main...$main") -split '\s+'
      Write-Output "$main vs $remote/${main}: ahead=$($lr[1]) behind=$($lr[0])"
      if ([int]$lr[1] -gt 0) { G log --oneline "$remote/$main..$main" | Select-Object -First 20 | ForEach-Object { "  unpushed: $_" } }
    } else { Write-Output "$main vs remote: no remote-tracking branch" }
    if ($cur -ne 'DETACHED' -and $cur -ne $main) {
      $up = G rev-parse --abbrev-ref "$cur@{upstream}"
      if ($up) { $lr = (G rev-list --left-right --count "$up...$cur") -split '\s+'; Write-Output "current $cur vs ${up}: ahead=$($lr[1]) behind=$($lr[0])" }
      else { Write-Output "current ${cur}: no upstream" }
    }
  } else { Write-Output "remote: none configured" }

  # ---------- worktrees ----------
  Hdr WORKTREES
  $wts = @(); $w = $null
  foreach ($line in (G worktree list --porcelain)) {
    if ($line -like 'worktree *') { if ($w) { $wts += $w }; $w = @{ path = $line.Substring(9).Replace('/', '\'); branch = ''; prunable = $false } }
    elseif ($line -like 'branch *') { $w.branch = $line.Substring(7) -replace '^refs/heads/', '' }
    elseif ($line -eq 'detached') { $w.branch = '(detached)' }
    elseif ($line -like 'prunable*') { $w.prunable = $true }
  }
  if ($w) { $wts += $w }
  foreach ($w in $wts) {
    if ($w.path -ieq $mainWt) { Write-Output "main: $($w.path) [$($w.branch)]"; continue }
    $inside = if (Under $w.path $mainWt) { 'yes' } else { 'no' }
    if (-not (Test-Path -LiteralPath $w.path)) { Write-Output "linked: $($w.path) [$($w.branch)] MISSING_DIR prunable=$(if ($w.prunable) {'yes'} else {'check'})"; continue }
    $dirty = @(& git -C $w.path status --porcelain 2>$null).Count
    $ahead = '?'; if ($main -and $w.branch -ne '(detached)') { $ahead = G rev-list --count "$main..$($w.branch)" }
    $ct = G -C $w.path log -1 --format=%ct
    $lastAge = if ($ct) { Age (FromEpoch $ct) } else { '?' }
    Write-Output "linked: $($w.path) [$($w.branch)] inside_repo=$inside dirty_files=$dirty commits_not_in_$main=$ahead last_commit_age=$lastAge"
    if ($inside -eq 'no') { Write-Output "  NOTE: outside this repo, report only" }
  }
  $pd = (& git worktree prune --dry-run -v 2>&1) -join '; '
  Write-Output ("prune_dry_run: " + $(if ($pd) { $pd } else { 'nothing to prune' }))

  # ---------- branches ----------
  Hdr BRANCHES
  if ($main) {
    $wtBranches = $wts | ForEach-Object { $_.branch }
    Write-Output "merged_into_${main}:"
    foreach ($br in (G branch --merged $main --format='%(refname:short)')) {
      if ($br -eq $main) { continue }
      $co = if ($wtBranches -contains $br) { ' CHECKED_OUT_IN_WORKTREE' } else { '' }
      Write-Output "  $br last=$(Age (FromEpoch (G log -1 --format=%ct $br)))$co"
    }
    Write-Output "not_merged_into_${main}:"
    foreach ($br in (G branch --no-merged $main --format='%(refname:short)')) {
      $n = G rev-list --count "$main..$br"; $t = FromEpoch (G log -1 --format=%ct $br)
      $eq = if (-not (@(G cherry $main $br) | Where-Object { $_ -like '+*' })) { " PATCHES_ALREADY_IN_$main" } else { '' }
      Write-Output "  $br commits=$n last=$(Age $t) $(Tag $t)$eq"
    }
    Write-Output "upstream_gone:"
    G for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads | Where-Object { $_ -match ' \[gone\]$' } | ForEach-Object { "  " + ($_ -split ' ')[0] }
    if ($remote) {
      Write-Output "stale_remote_tracking (deleted on remote):"
      G remote prune --dry-run $remote | Where-Object { $_ -match 'would prune' } | ForEach-Object { "  $_" }
    }
  }

  # ---------- stashes ----------
  Hdr STASHES
  $sl = @(G stash list --format='%gd%x09%ct%x09%s')
  if ($sl.Count -eq 0) { Write-Output "stashes: none" } else {
    foreach ($s in $sl) { $ref, $ct, $msg = $s -split "`t", 3; $t = FromEpoch $ct
      $flag = ''; if (((Get-Date) - $t).TotalDays -gt 7) { $flag = ' OLDER_THAN_7D' }
      if (Recent $t) { $flag += ' THIS_SESSION' }
      Write-Output "  $ref age=$(Age $t)$flag :: $msg" }
  }
}

# ---------- lanes ----------
Hdr LANES
$K = Join-Path $HOME '.claude\skills\lanes'
if ($inGit -and (Test-Path -LiteralPath (Join-Path $K 'lane\lane-env.sh'))) {
  # Same state-dir name as lanes_state: <repo-name>-<first 8 hex of sha256(repo path)>. Path form must match how bash saw it.
  $sha = [Security.Cryptography.SHA256]::Create()
  $cands = @($mainWt, $mainWt.Replace('\', '/'))
  $S = $null
  foreach ($c in $cands) {
    $hx = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($c)) | ForEach-Object { $_.ToString('x2') })
    $d = Join-Path $HOME (".local\state\lanes\" + (Split-Path -Leaf $mainWt) + "-" + $hx.Substring(0, 8))
    if (Test-Path -LiteralPath $d) { $S = $d; break }
  }
  if ($S) {
    Write-Output "state_dir: $S"
    Write-Output "cleanup_script: bash $K/lane/cleanup.sh <lane-dir> <branch> | --sweep (use this, not Remove-Item)"
    $tsv = Join-Path $S 'lanes.tsv'
    if ((Test-Path -LiteralPath $tsv) -and (Get-Item -LiteralPath $tsv).Length -gt 0) {
      foreach ($row in Get-Content -LiteralPath $tsv) {
        $f = $row -split "`t"; if (-not $f[0]) { continue }
        $wt = if ($f.Count -gt 3) { $f[3] } else { '' }; $job = if ($f.Count -gt 4) { $f[4] } else { '' }
        $note = ''; if ($wt -and -not (Test-Path -LiteralPath $wt)) { $note = ' WORKTREE_MISSING' }
        Write-Output "  row: $($f[0]) agent=$($f[1]) wt=$wt job=$job$note"
      }
    } else { Write-Output "lanes_tsv: empty or absent" }
  } else { Write-Output "lanes: harness installed, no state for this repo" }
} else { Write-Output "lanes: not present" }

# ---------- processes ----------
Hdr PROCESSES
$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$snap = Get-Date
$parent = @{}; foreach ($p in $procs) { $parent[[int]$p.ProcessId] = [int]$p.ParentProcessId }
$desc = @{}
if ($claudePid) {
  foreach ($p in $procs) { $q = [int]$p.ProcessId; $n = 0
    while ($q -gt 4 -and $n -lt 64) { if ($q -eq [int]$claudePid) { $desc[[int]$p.ProcessId] = $true; break }
      if (-not $parent.ContainsKey($q)) { break }; $q = $parent[$q]; $n++ } }
}
$selfChain = @{}; $q = $PID; $n = 0
while ($q -and $n -lt 64) { $selfChain[$q] = $true; if (-not $parent.ContainsKey($q)) { break }; $q = $parent[$q]; $n++ }
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$listed = @()
foreach ($p in $procs) {
  $id = [int]$p.ProcessId
  if ($selfChain.ContainsKey($id) -or ($claudePid -and $id -eq [int]$claudePid)) { continue }
  if ($parent[$id] -eq $PID) { continue }   # our own children (git, etc.)
  $cmd = "$($p.CommandLine)"; if (-not $cmd) { continue }
  if ($p.Name -ieq 'conhost.exe') { continue }   # console host attached to console programs
  $inRepo = if ($inGit -and $cmd.IndexOf($mainWt, [StringComparison]::OrdinalIgnoreCase) -ge 0) { 'yes' } else { 'no' }
  $owner = ''
  if ($desc.ContainsKey($id)) { $owner = 'this_session' }
  if (-not $owner -and $inRepo -eq 'no') { continue }
  $start = $p.CreationDate
  if (-not $owner) {
    $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue
    if ($o -and ("$($o.Domain)\$($o.User)" -ine $me)) { continue }
    $owner = if ($start -and (Recent $start)) { 'started_during_session' } else { 'other_session_or_user' }
  }
  if ($owner -eq 'this_session' -and ($cmd -match '\\\.claude\\|/\.claude/|mcp')) { $owner = 'harness_do_not_kill' }
  $listed += $id
  $short = if ($cmd.Length -gt 140) { $cmd.Substring(0, 140) } else { $cmd }
  $el = if ($start) { Age $start } else { '?' }
  Write-Output "  pid=$id owner=$owner in_repo=$inRepo elapsed=$el cmd=$short"
}
Write-Output "listening_ports (only for the processes above):"
if ($listed.Count) {
  Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $listed -contains [int]$_.OwningProcess } |
    ForEach-Object { "  pid=$($_.OwningProcess) listen=$($_.LocalAddress):$($_.LocalPort)" } | Sort-Object -Unique
}

# ---------- artifacts ----------
Hdr ARTIFACTS
if ($sid) {
  $scr = Get-ChildItem -Path $env:TEMP -Directory -Recurse -Depth 3 -Filter $sid -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'scratchpad' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ($scr) { Write-Output "scratchpad: $scr size=$(Size $scr) files=$(@(Get-ChildItem -LiteralPath $scr -Recurse -File -Force -ErrorAction SilentlyContinue).Count)" }
}
if ($inGit) {
  # Walk the repo once, skipping node_modules and .git, collecting known build-artifact dirs and large files.
  $artNames = @('.next\types', '.next\dev\types', 'coverage', 'test-results', 'playwright-report', '.nyc_output')
  $big = @(); $arts = @()
  $stack = New-Object System.Collections.Stack; $stack.Push($mainWt)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    foreach ($e in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
      if ($e.PSIsContainer) {
        if ($e.Name -in 'node_modules', '.git') { continue }
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $rel = $e.FullName.Substring($mainWt.Length).TrimStart('\')
        if ($artNames | Where-Object { $rel -ieq $_ -or $rel.EndsWith('\' + $_, [StringComparison]::OrdinalIgnoreCase) }) { $arts += $e }
        $stack.Push($e.FullName)
      } elseif ($e.Length -gt ($BigMB * 1MB) -and $e.FullName -notmatch '\\\.next\\') { $big += $e }
    }
  }
  foreach ($a in $arts) {
    & git -C $mainWt check-ignore -q $a.FullName 2>$null; $ign = if ($LASTEXITCODE -eq 0) { 'yes' } else { 'no' }
    Write-Output "  build_artifact: $($a.FullName) size=$(Size $a.FullName) age=$(Age $a.LastWriteTime) gitignored=$ign"
  }
  Write-Output "large_files (>${BigMB}MB, not tracked, excluding node_modules/.git/.next):"
  foreach ($f in ($big | Select-Object -First 30)) {
    & git -C $mainWt ls-files --error-unmatch $f.FullName *> $null
    if ($LASTEXITCODE -ne 0) { Write-Output "  $($f.FullName) size=$(Size $f.FullName) age=$(Age $f.LastWriteTime)" }
  }
}
if ($sinceDt) {
  Write-Output "tmp_dirs_created_this_session (top-level temp dirs owned by you; inspect before touching):"
  Get-ChildItem -LiteralPath $env:TEMP -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.CreationTime -ge $sinceDt -and $_.Name -notmatch '^claude' } | Select-Object -First 30 |
    ForEach-Object { "  $($_.FullName) size=$(Size $_.FullName)" }
}

# ---------- tracker ----------
Hdr TRACKER
if ($inGit -and (Test-Path -LiteralPath (Join-Path $mainWt '.beads')) -and (Get-Command bd -ErrorAction SilentlyContinue)) {
  Write-Output "beads in_progress:"; Push-Location $mainWt; & bd list --status=in_progress 2>&1 | Select-Object -First 30 | ForEach-Object { "  $_" }; Pop-Location
} elseif ($inGit -and (Test-Path -LiteralPath (Join-Path $mainWt 'tasks.md'))) {
  Write-Output "tasks.md in-progress lines:"
  Select-String -LiteralPath (Join-Path $mainWt 'tasks.md') -Pattern 'in[ _-]?progress|\[~\]|\[/\]|WIP' | Select-Object -First 30 | ForEach-Object { "  $($_.LineNumber):$($_.Line)" }
} else { Write-Output "tracker: none found" }

# ---------- deploy ----------
Hdr DEPLOY
if ($inGit) {
  if ($main) { Write-Output "main_tip: $(G rev-parse $main) ($(G log -1 --format=%s $main))" }
  if ($remote -and $main) { $o = G rev-parse --verify -q "$remote/$main"; Write-Output ("origin_main_tip: " + $(if ($o) { $o } else { 'none' })) }
  $plat = @()
  if ((Test-Path (Join-Path $mainWt '.vercel\project.json')) -or (Test-Path (Join-Path $mainWt 'vercel.json')) -or (Test-Path (Join-Path $mainWt 'vercel.ts'))) { $plat += 'vercel' }
  if (Test-Path (Join-Path $mainWt 'netlify.toml')) { $plat += 'netlify' }
  if (Test-Path (Join-Path $mainWt 'fly.toml')) { $plat += 'fly' }
  if ((Test-Path (Join-Path $mainWt 'wrangler.toml')) -or (Test-Path (Join-Path $mainWt 'wrangler.jsonc'))) { $plat += 'cloudflare' }
  Write-Output ("platforms: " + $(if ($plat.Count) { $plat -join ' ' } else { 'none detected' }))
}

# ---------- sessions log ----------
Hdr SESSION_LOG
if ($inGit -and (Test-Path -LiteralPath (Join-Path $mainWt '_sessions'))) {
  & git -C $mainWt check-ignore -q _sessions 2>$null; $ig = if ($LASTEXITCODE -eq 0) { 'yes' } else { 'no' }
  Write-Output "session_log_dir: $(Join-Path $mainWt '_sessions') (ignored=$ig)"
} else { Write-Output "session_log_dir: none" }
Write-Output ""
Write-Output "audit: done (read-only)"
