#!/usr/bin/env bash
# audit.sh [--no-fetch] [--repo <path>] [--since <ISO-8601>] [--big-mb <N>]
# audit.sh --machine [--roots <dir>[:<dir>]] [--big-mb <N>]   machine-wide MACHINE section only
# audit.sh --session-live <id> <newest_mtime>               prints "<id> yes|no|unknown"
#
# Read-only end-of-session audit for Linux and macOS (Windows: use audit.ps1).
# Prints one section per area as "key: value" lines.
# The only write it ever performs is `git fetch` (updates remote-tracking refs, never prunes);
# pass --no-fetch to skip even that. It never deletes, kills, stashes or resets anything.
# It never reads .env files or prints process environments (it only greps them for the session id).
# Compatible with bash 3.2 (macOS default) and GNU or BSD userland.
set -uo pipefail

FETCH=1 REPO="" SINCE="" BIG_MB=50 MACHINE=0 ROOTS_ARG="$HOME/dev" LIVE_IDS_ARG="" LIVE_NM_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) FETCH=0 ;;
    --repo) REPO="$2"; shift ;;
    --since) SINCE="$2"; shift ;;
    --big-mb) BIG_MB="$2"; shift ;;
    --machine) MACHINE=1 ;;
    --roots) ROOTS_ARG="$2"; shift ;;
    --session-live) [ $# -eq 3 ] || { echo "usage: --session-live <id> <newest_mtime>" >&2; exit 2; }; LIVE_IDS_ARG="$2"; LIVE_NM_ARG="$3"; break ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

OS=$(uname -s)
hdr() { printf '\n=== %s ===\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
cnt() { wc -l | tr -d ' '; }   # BSD wc pads with spaces
now=$(date +%s)
age() { # epoch -> "3d4h" style age
  local s=$(( now - ${1:-0} )); [ "$s" -lt 0 ] && s=0
  if [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s/86400)) $((s%86400/3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%dm' $((s/3600)) $((s%3600/60))
  else printf '%dm' $((s/60)); fi
}
sz() { du -sh "$1" 2>/dev/null | cut -f1; }
if [ "$OS" = Darwin ]; then
  mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
  fuid() { stat -f %u "$1" 2>/dev/null; }
  # ISO-8601 (UTC, optional fraction and Z) -> epoch
  iso2epoch() { local t="${1%%.*}"; t="${t%Z}"; date -j -u -f '%Y-%m-%dT%H:%M:%S' "$t" +%s 2>/dev/null || echo 0; }
  epoch2touch() { date -r "$1" +%Y%m%d%H%M.%S; }
  sha8() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }
  lstart2epoch() { date -j -f '%a %b %d %T %Y' "$1" +%s 2>/dev/null; }
else
  mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
  fuid() { stat -c %u "$1" 2>/dev/null; }
  iso2epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }
  epoch2touch() { date -d "@$1" +%Y%m%d%H%M.%S; }
  sha8() { printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-8; }
  lstart2epoch() { date -d "$1" +%s 2>/dev/null; }
fi
# Process start as epoch seconds; clean.sh compares it to detect a reused PID.
pstart() { local s; s=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) && [ -n "$s" ] && lstart2epoch "$s"; }
# yes when <ref>'s work is on the remote's main: an ancestor of it, or every patch present (git cherry)
# and no merge commits (cherry skips merges, which can carry unique conflict resolutions).
on_remote() {
  local r="${REMOTE:-}/$MAIN" c
  { [ -n "${REMOTE:-}" ] && [ -n "$MAIN" ] && git show-ref --verify --quiet "refs/remotes/$r"; } || { echo no; return; }
  git merge-base --is-ancestor "$1" "$r" 2>/dev/null && { echo yes; return; }
  c=$(git cherry "$r" "$1" 2>/dev/null) || { echo no; return; }
  case "$c" in *"+ "*) echo no; return ;; esac
  [ -z "$(git rev-list --merges "$r..$1" 2>/dev/null)" ] && echo yes || echo no
}
# Ignored output that regenerates on the next build: lanes worktree-tools.py cleanup()'s set minus coverage,
# which is evidence (ASK in SKILL.md).
REGEN='(^|/)(__pycache__|\.ruff_cache|\.pytest_cache|\.mypy_cache|node_modules|dist|build|\.next|\.turbo)(/|$)|\.(pyc|tsbuildinfo)$'
# ps etime ([[dd-]hh:]mm:ss) -> seconds; works with GNU and BSD ps
etime2s() {
  local e="$1" d=0 h=0 m=0 s=0
  case "$e" in *-*) d=${e%%-*}; e=${e#*-} ;; esac
  IFS=: read -r a b c <<EOF
$e
EOF
  if [ -n "${c:-}" ]; then h=$a; m=$b; s=$c; else m=$a; s=$b; fi
  echo $(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$s ))
}
run_to() { # run_to <secs> cmd... ; uses timeout/gtimeout when available
  local t="$1"; shift
  if have timeout; then timeout "$t" "$@"; elif have gtimeout; then gtimeout "$t" "$@"; else "$@"; fi
}
recent() { [ "$SINCE_EPOCH" -gt 0 ] && [ "${1:-0}" -ge "$SINCE_EPOCH" ]; }
mine=$(id -u)
TMPROOTS="/tmp"; [ -n "${TMPDIR:-}" ] && [ "${TMPDIR%/}" != /tmp ] && TMPROOTS="$TMPROOTS ${TMPDIR%/}"

# ---------- machine scope (--machine, --session-live) ----------
# SC_TMP_ROOT replaces /tmp; it exists for evals/machine-test.sh only.
TMP_BASE="${SC_TMP_ROOT:-/tmp}"
claude_bases() { # roots holding Claude Code scratch folders: <base>/<project>/<session-id>/
  echo "$TMP_BASE/claude-$mine"
  [ -z "${SC_TMP_ROOT:-}" ] && [ -n "${TMPDIR:-}" ] && [ "${TMPDIR%/}" != /tmp ] && echo "${TMPDIR%/}/claude-$mine"
  return 0
}
is_uuid() { printf '%s\n' "$1" | grep -Eqx '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; }
if [ "$OS" = Darwin ]; then newest() { find "$1" -exec stat -f %m {} + 2>/dev/null | sort -n | tail -1; }
else newest() { find "$1" -exec stat -c %Y {} + 2>/dev/null | sort -n | tail -1; }; fi

# scan_envs sets LIVE_IDS: the CLAUDE_CODE_SESSION_ID values in this user's readable process environments (only
# that variable is extracted; no environment is printed). Unreadable processes are ignored: a live Claude Code
# session rewrites its transcript every turn, so 7 days of transcript inactivity plus no readable carrier is the
# proof; the residual risk is losing scratch files of a session idle over a week, which are temporary by design.
scan_envs() {
  LIVE_IDS="" ENV_PROBE=none
  [ "$OS" = Linux ] || return 0
  ENV_PROBE=proc
  LIVE_IDS=$(for e in /proc/[0-9]*/environ; do
      [ -r "$e" ] || continue
      { tr '\0' '\n' < "$e" | sed -n 's/^CLAUDE_CODE_SESSION_ID=//p'; } 2>/dev/null
    done | sort -u)
  return 0
}
tx_of() { local f; for f in "$HOME"/.claude/projects/*/"$1".jsonl; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
# session_live <id> <scratch newest mtime>: yes when a readable process carries the id or the transcript changed in
# the last 24h; no only when the transcript exists and is 7+ days idle, no readable process carries the id and the
# scratch folder is 7+ days idle; otherwise unknown (also on macOS, which hides every environment).
session_live() {
  local id="$1" nm="${2:-}" tx t
  t=$(date +%s)
  printf '%s\n' "$LIVE_IDS" | grep -qxF -- "$id" && { echo yes; return; }
  tx=$(tx_of "$id")
  [ -n "$tx" ] && [ $(( t - $(mtime "$tx") )) -lt 86400 ] && { echo yes; return; }
  if [ "$ENV_PROBE" = proc ] && [ -n "$tx" ] && [ $(( t - $(mtime "$tx") )) -ge 604800 ] &&
     [ -n "$nm" ] && [ $(( t - nm )) -ge 604800 ]; then echo no; else echo unknown; fi
}

if [ -n "$LIVE_IDS_ARG" ]; then
  scan_envs
  echo "$LIVE_IDS_ARG $(session_live "$LIVE_IDS_ARG" "$LIVE_NM_ARG")"
  exit 0
fi

if [ "$MACHINE" = 1 ]; then
  hdr MACHINE
  echo "roots: $ROOTS_ARG"
  scan_envs
  if [ "$ENV_PROBE" = proc ]; then echo "liveness: readable process environments and transcript age (no = transcript and scratch folder idle 7+ days)"
  else echo "liveness: transcripts only (this OS hides process environments, so not live means unknown)"; fi
  IT=$(mktemp "${TMPDIR:-/tmp}/.sc-machine.XXXXXX") || exit 1
  trap 'rm -f "$IT"' EXIT
  kb() { du -sk "$1" 2>/dev/null | cut -f1; }
  # Item lines: <kb> TAB <class> TAB <text>. class: safe (machine-sweep.sh deletes it), ask, in_use, report.
  claude_bases | while IFS= read -r base; do
    [ -d "$base" ] && [ ! -L "$base" ] || continue
    for proj in "$base"/*/; do
      proj=${proj%/}; [ -L "$proj" ] && continue
      for e in "$proj"/* "$proj"/.[!.]*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        n=$(basename "$e")
        if is_uuid "$n" && [ -d "$e" ] && [ ! -L "$e" ]; then
          nm=$(newest "$e"); live=$(session_live "$n" "$nm"); class=ask
          [ "$live" = yes ] && class=in_use
          [ "$live" = no ] && class=safe
          printf '%s\t%s\t%s\n' "$(kb "$e")" "$class" "scratchpad: $e session_id=$n newest_mtime=$nm age=$(age "$nm") session_live=$live"
        else
          printf '%s\t%s\t%s\n' "$(kb "$e")" ask "claude_tmp_other: $e age=$(age "$(mtime "$e")")"
        fi
      done
    done
  done >> "$IT"

  # Orphaned dev servers: this user's TCP listeners whose parent is init or the user's systemd and whose cwd is in a root.
  in_mroot() { local r IFS=:; for r in $ROOTS_ARG; do case "$1" in "$r"|"$r"/*) return 0 ;; esac; done; return 1; }
  SYSD=$(ps -axo pid=,ppid=,uid=,comm= 2>/dev/null | awk -v u="$mine" '$2==1 && $3==u && $4=="systemd"{print $1}')
  if [ "$OS" = Darwin ]; then
    listeners=$(lsof -nP -a -u "$mine" -iTCP -sTCP:LISTEN -Fpn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n/{print p, substr($0,2)}')
    lcwd() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; }
  else
    listeners=$(ss -ltnpH 2>/dev/null | awk '{a=$4; while (match($0, /pid=[0-9]+/)) {print substr($0, RSTART+4, RLENGTH-4), a; $0=substr($0, RSTART+RLENGTH)}}')
    lcwd() { readlink "/proc/$1/cwd" 2>/dev/null; }
  fi
  DEVS=$(printf '%s\n' "$listeners" | sort -u | while read -r pid addr; do
    [ -n "$pid" ] || continue
    [ "$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$mine" ] || continue
    pp=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$pp" = 1 ] || { [ -n "$SYSD" ] && printf '%s\n' "$SYSD" | grep -qx "$pp"; } || continue
    cwd=$(lcwd "$pid"); in_mroot "$cwd" || continue
    et=$(ps -o etime= -p "$pid" | tr -d ' ')
    echo "  pid=$pid listen=$addr age=$(age $(( now - $(etime2s "$et") ))) cwd=$cwd cmd=$(ps -o command= -p "$pid" | cut -c1-140)"
  done)

  # Repos under the roots. Lanes owns lane worktrees and temp dirs in repos with lanes state, so they are not classified.
  REPOS=$(IFS=:; for r in $ROOTS_ARG; do
      [ -d "$r" ] && find "$r" -maxdepth 4 \( -name node_modules -o -name .cache \) -prune -o -name .git -type d -print -prune 2>/dev/null
    done | while IFS= read -r g; do (cd "$(dirname "$g")" && pwd -P); done | sort -u)
  REPOLINES=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    nwt=$(( $(git -C "$r" worktree list --porcelain 2>/dev/null | grep -c '^worktree ') - 1 ))
    nst=$(git -C "$r" stash list 2>/dev/null | cnt)
    line="  repo: $r linked_worktrees=$nwt stashes=$nst"
    if [ -d "$HOME/.local/state/lanes/$(basename "$r")-$(sha8 "$r")" ]; then
      line="$line lanes: run cleanup.sh --sweep --dry-run"
    else
      git -C "$r" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}' | tail -n +2 | while IFS= read -r w; do
        [ -d "$w" ] || continue
        printf '%s\t%s\t%s\n' "$(kb "$w")" ask "worktree: $w repo=$r inside_roots=$(in_mroot "$w" && echo yes || echo no) dirty_files=$(git -C "$w" status --porcelain 2>/dev/null | cnt)"
      done >> "$IT"
    fi
    find "$r" \( -name node_modules -o -name .git -o -name .next -o -name .beads -o -path "$r/.claude/worktrees" \) -prune -o -type f -size +"${BIG_MB}"M -print 2>/dev/null | head -30 |
      while IFS= read -r f; do
        git -C "$r" ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
        printf '%s\t%s\t%s\n' "$(kb "$f")" ask "big_untracked_file: $f repo=$r age=$(age "$(mtime "$f")")"
      done >> "$IT"
    REPOLINES="$REPOLINES$line
"
  done <<EOF
$REPOS
EOF

  # Loose files at the root of the lanes temp folder: report only.
  L="$TMP_BASE/lanes-$mine"
  [ -d "$L" ] && find "$L" -mindepth 1 -maxdepth 1 ! -type d 2>/dev/null | while IFS= read -r f; do
    printf '%s\t%s\t%s\n' "$(kb "$f")" report "lanes_tmp_loose: $f age=$(age "$(mtime "$f")")"; done >> "$IT"

  human() { awk '{k=$1; if (k>=1048576) printf "%.1fG", k/1048576; else if (k>=1024) printf "%.1fM", k/1024; else printf "%dK", k}'; }
  tot() { awk -F'\t' -v c="$1" '$2==c{s+=$1; n++} END{print s+0, n+0}' "$IT"; }
  set -- $(tot safe); echo "reclaimable_safe: $(echo "$1" | human) in $2 items (machine-sweep.sh deletes these)"
  set -- $(tot ask); echo "reclaimable_needs_your_call: $(echo "$1" | human) in $2 items"
  echo "items (largest first; safe | ask | in_use | report):"
  awk -F'\t' 'NF>=3' "$IT" | sort -t "$(printf '\t')" -k1,1nr | while IFS=$'\t' read -r k cl text; do
    echo "  $(echo "$k" | human) $cl $text"
  done
  echo "dev_servers_orphaned (report only):"
  if [ -n "$DEVS" ]; then printf '%s\n' "$DEVS"; else echo "  none"; fi
  echo "repos:"
  if [ -n "$REPOLINES" ]; then printf '%s' "$REPOLINES"; else echo "  none"; fi
  echo
  echo "audit: done (read-only)"
  exit 0
fi

# ---------- context ----------
hdr CONTEXT
echo "os: $OS"
if [ -n "$REPO" ]; then cd "$REPO" || { echo "error: cannot cd to $REPO"; exit 1; }; fi
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "git: not a git repository ($(pwd)); git sections skipped"
  IN_GIT=0
else
  IN_GIT=1
  COMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  MAIN_WT=$(dirname "$COMMON")
  TOP=$(git rev-parse --show-toplevel)
  echo "repo_main_worktree: $MAIN_WT"
  echo "current_worktree: $TOP"
  echo "current_branch: $(git branch --show-current 2>/dev/null || echo DETACHED)"
  MAIN=""
  for b in main master trunk; do git show-ref --verify --quiet "refs/heads/$b" && { MAIN=$b; break; }; done
  [ -z "$MAIN" ] && MAIN=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  echo "main_branch: ${MAIN:-UNKNOWN}"
  REMOTE=$(git remote | grep -x origin || git remote | head -1)
  echo "remote: ${REMOTE:-none}"
fi

SID="${CLAUDE_CODE_SESSION_ID:-}"
echo "session_id: ${SID:-unknown}"
echo "claude_pid: ${CLAUDE_PID:-unknown}"
if [ -z "$SINCE" ] && [ -n "$SID" ]; then
  tx=$(ls "$HOME"/.claude/projects/*/"$SID".jsonl 2>/dev/null | head -1)
  [ -n "$tx" ] && SINCE=$(grep -o '"timestamp":"[^"]*"' "$tx" | head -1 | cut -d'"' -f4)
fi
SINCE_EPOCH=0
[ -n "$SINCE" ] && SINCE_EPOCH=$(iso2epoch "$SINCE")
if [ "$SINCE_EPOCH" = 0 ] && [ -n "${CLAUDE_PID:-}" ]; then
  et=$(ps -o etime= -p "$CLAUDE_PID" 2>/dev/null | tr -d ' ')
  [ -n "$et" ] && { SINCE_EPOCH=$(( now - $(etime2s "$et") )); SINCE="claude process start"; }
fi
echo "session_start: ${SINCE:-unknown} (items newer than this may belong to this session; older items are ASK)"

if [ "$IN_GIT" = 1 ]; then
# ---------- working tree ----------
hdr WORKING_TREE
st=$(git status --porcelain=v1 2>/dev/null)
if [ -z "$st" ]; then echo "status: clean"; else
  echo "status: $(printf '%s\n' "$st" | cnt) entries"
  printf '%s\n' "$st" | sed 's/^/  /' | head -60
  junk=$(printf '%s\n' "$st" | awk '$1=="??"{print $2}' | grep -E '(\.orig|\.rej|\.log|\.bak|\.tmp|\.swp|~|\.png|\.jpe?g|\.webp|\.gif|\.mp4|\.webm|\.har|\.trace|\.zip|nohup\.out|\.DS_Store)$|(^|/)(scratch|tmp|temp)[^/]*$')
  if [ -n "$junk" ]; then echo "junk_candidates:"; printf '%s\n' "$junk" | while read -r f; do
    m=$(mtime "$f"); echo "  $f size=$(sz "$f") mtime=$m age=$(age "$m") $(recent "$m" && echo this_session || echo pre_session)"; done; fi
  envs=$(printf '%s\n' "$st" | awk '{print $NF}' | grep -E '(^|/)\.env' | grep -v '\.example$')
  [ -n "$envs" ] && echo "WARNING: .env-like paths in status (do not read, print or delete): $(printf '%s ' $envs)"
fi

# ---------- sync ----------
hdr SYNC
if [ -n "${REMOTE:-}" ]; then
  if [ "$FETCH" = 1 ]; then
    if ferr=$(run_to 60 git fetch --quiet "$REMOTE" 2>&1); then echo "fetch: ok"; else echo "fetch: FAILED ($(printf '%s' "$ferr" | head -1))"; fi
  else echo "fetch: skipped (--no-fetch); results may be stale"; fi
  if [ -n "$MAIN" ] && git show-ref --verify --quiet "refs/remotes/$REMOTE/$MAIN"; then
    read -r behind ahead <<EOF
$(git rev-list --left-right --count "$REMOTE/$MAIN...$MAIN")
EOF
    echo "$MAIN vs $REMOTE/$MAIN: ahead=$ahead behind=$behind"
    [ "$ahead" -gt 0 ] && git log --oneline "$REMOTE/$MAIN..$MAIN" | sed 's/^/  unpushed: /' | head -20
  else echo "$MAIN vs remote: no remote-tracking branch"; fi
  cur=$(git branch --show-current)
  if [ -n "$cur" ] && [ "$cur" != "$MAIN" ]; then
    up=$(git rev-parse --abbrev-ref "$cur@{upstream}" 2>/dev/null)
    if [ -n "$up" ]; then read -r b a <<EOF
$(git rev-list --left-right --count "$up...$cur")
EOF
      echo "current $cur vs $up: ahead=$a behind=$b"
    else echo "current $cur: no upstream"; fi
  fi
else echo "remote: none configured"; fi

# ---------- worktrees ----------
hdr WORKTREES
git worktree list --porcelain | awk '
  /^worktree /{p=substr($0,10)} /^branch /{b=substr($0,8); sub("refs/heads/","",b)} /^detached/{b="(detached)"}
  /^prunable/{pr=1} /^$/{if(p!="")print p "\t" b "\t" pr; p="";b="";pr=0} END{if(p!="")print p "\t" b "\t" pr}' |
while IFS=$'\t' read -r p b pr; do
  [ "$p" = "$MAIN_WT" ] && { echo "main: $p [$b]"; continue; }
  inside=no; case "$p" in "$MAIN_WT"/*) inside=yes ;; esac
  if [ ! -d "$p" ]; then echo "linked: $p [$b] MISSING_DIR prunable=$([ "$pr" = 1 ] && echo yes || echo check)"; continue; fi
  dirty=$(git -C "$p" status --porcelain 2>/dev/null | cnt)
  ahead="?"; [ -n "$MAIN" ] && [ "$b" != "(detached)" ] && ahead=$(git rev-list --count "$MAIN..$b" 2>/dev/null)
  last=$(git -C "$p" log -1 --format=%ct 2>/dev/null || echo 0)
  h=$(git -C "$p" rev-parse HEAD 2>/dev/null)
  ui=$(git -C "$p" status --porcelain --ignored=matching --untracked-files=all 2>/dev/null | sed -n 's/^!! //p' | sed 's#/$##' | grep -Ecv "$REGEN")
  echo "linked: $p [$b] inside_repo=$inside dirty_files=$dirty commits_not_in_$MAIN=$ahead last_commit_age=$(age "$last") head=$h on_${REMOTE:-remote}=$(on_remote "$h") user_ignored_files=$ui"
  [ "$inside" = no ] && echo "  NOTE: outside this repo, report only"
done
pd=$(git worktree prune --dry-run -v 2>&1)
echo "prune_dry_run: ${pd:-nothing to prune}"

# ---------- branches ----------
hdr BRANCHES
if [ -n "$MAIN" ]; then
  wt_branches=$(git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}')
  echo "merged_into_$MAIN:"
  git branch --merged "$MAIN" --format='%(refname:short)' | while read -r br; do
    [ "$br" = "$MAIN" ] && continue
    co=""; printf '%s\n' "$wt_branches" | grep -qx "$br" && co=" CHECKED_OUT_IN_WORKTREE"
    echo "  $br last=$(age "$(git log -1 --format=%ct "$br")")$co tip=$(git rev-parse "$br") on_${REMOTE:-remote}=$(on_remote "$br")"
  done
  echo "not_merged_into_$MAIN:"
  git branch --no-merged "$MAIN" --format='%(refname:short)' | while read -r br; do
    n=$(git rev-list --count "$MAIN..$br"); ct=$(git log -1 --format=%ct "$br")
    # A squash/rebase merge leaves no ancestry; check whether the branch's patches are already in main.
    eq=""; [ -z "$(git cherry "$MAIN" "$br" 2>/dev/null | grep '^+')" ] && eq=" PATCHES_ALREADY_IN_$MAIN"
    echo "  $br commits=$n last=$(age "$ct") $(recent "$ct" && echo this_session || echo pre_session)$eq tip=$(git rev-parse "$br") on_${REMOTE:-remote}=$(on_remote "$br")"
  done
  echo "upstream_gone:"
  git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads | awk '$2=="[gone]"{print "  "$1}'
  if [ -n "${REMOTE:-}" ]; then
    echo "stale_remote_tracking (deleted on remote):"
    git remote prune --dry-run "$REMOTE" 2>/dev/null | grep 'would prune' | sed 's/^/  /'
  fi
fi

# ---------- stashes ----------
hdr STASHES
sl=$(git stash list --format='%gd%x09%ct%x09%H%x09%s' 2>/dev/null)
if [ -z "$sl" ]; then echo "stashes: none"; else
  printf '%s\n' "$sl" | while IFS=$'\t' read -r ref ct sha msg; do
    flag=""; [ $(( now - ct )) -gt 604800 ] && flag=" OLDER_THAN_7D"
    recent "$ct" && flag="$flag THIS_SESSION"
    echo "  $ref age=$(age "$ct")$flag sha=$sha :: $msg"
  done
fi
fi # IN_GIT

# ---------- lanes ----------
hdr LANES
K="$HOME/.claude/skills/lanes"
if [ "$IN_GIT" = 1 ] && [ -f "$K/lane/lane-env.sh" ]; then
  S="$HOME/.local/state/lanes/$(basename "$MAIN_WT")-$(sha8 "$MAIN_WT")"
  if [ -d "$S" ]; then
    echo "state_dir: $S"
    echo "cleanup_script: bash $K/lane/cleanup.sh --sweep --dry-run, then --sweep (lanes owns lane artifacts; never rm)"
    if [ -s "$S/lanes.tsv" ]; then
      while IFS=$'\t' read -r lane agent task wt job; do
        [ -z "$lane" ] && continue
        note=""; [ -n "$wt" ] && [ ! -d "$wt" ] && note=" WORKTREE_MISSING"
        if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$MAIN" ]; then
          br=$(git -C "$wt" branch --show-current 2>/dev/null)
          # Lanes cleans a lane only once its merge is on origin; a local-only merge is not yet recoverable from the remote.
          if [ -n "$br" ] && [ -n "${REMOTE:-}" ] && git show-ref --verify --quiet "refs/remotes/$REMOTE/$MAIN" &&
             git merge-base --is-ancestor "refs/heads/$br" "refs/remotes/$REMOTE/$MAIN" 2>/dev/null; then note="$note BRANCH_MERGED"
          elif [ -n "$br" ] && git merge-base --is-ancestor "refs/heads/$br" "refs/heads/$MAIN" 2>/dev/null; then note="$note MERGED_NOT_ON_${REMOTE:-REMOTE}"
          fi
        fi
        echo "  row: $lane agent=$agent wt=$wt job=$job$note"
      done < "$S/lanes.tsv"
    else echo "lanes_tsv: empty or absent"; fi
    T="/tmp/lanes-$mine/$(basename "$S")"
    if [ -d "$T" ]; then
      for d in "$T"/*/; do [ -d "$d" ] || continue
        n=$(basename "$d"); br_guess="${n%-*}"
        open=$(lsof +D "$d" 2>/dev/null | tail -n +2 | cnt)
        exists=no
        git for-each-ref --format='%(refname:short)' refs/heads | sed 's#/#-#g' | grep -qx "$br_guess" && exists=yes
        echo "  tmp: $d size=$(sz "$d") branch_exists=$exists open_handles=$open"
      done
    else echo "lane_tmp: none ($T)"; fi
  else echo "lanes: harness installed, no state for this repo"; fi
  echo "relay_jobs_running (no rc file, cwd in this repo):"
  for j in "$HOME"/.local/state/model-relay.* "$HOME"/.local/state/codex-lane.* "$HOME"/.local/state/codex-review.*; do
    [ -d "$j" ] && [ -f "$j/cwd" ] || continue
    c=$(cat "$j/cwd"); case "$c" in "$MAIN_WT"|"$MAIN_WT"/*) ;; *) continue ;; esac
    [ -f "$j/rc" ] || echo "  $j cwd=$c age=$(age "$(mtime "$j")")"
  done
else echo "lanes: not present"; fi

# ---------- processes ----------
hdr PROCESSES
# Per-OS probes: has_sid <pid> (env contains this session id), pcwd <pid>.
if [ "$OS" = Darwin ]; then
  # macOS does not expose other processes' environments (even same-user), so ownership falls back
  # to ancestry: a descendant of the Claude process is this session's. Reparented (nohup) processes
  # lose that link and are tagged started_during_session at best.
  has_sid() { printf '%s\n' "$DESC" | grep -qx "$1"; }
  # One lsof call for every cwd of this user's processes ("pid<TAB>cwd"), looked up per pid.
  CWDS=$(lsof -a -u "$mine" -d cwd -Fpn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n/{print p "\t" substr($0,2)}')
  pcwd() { printf '%s\n' "$CWDS" | awk -F'\t' -v x="$1" '$1==x{print $2; exit}'; }
  ports() { lsof -nP -a -p "$1" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | sort -u; }
else
  has_sid() { tr '\0' '\n' 2>/dev/null < "/proc/$1/environ" | grep -qx "CLAUDE_CODE_SESSION_ID=$SID"; }
  pcwd() { readlink "/proc/$1/cwd" 2>/dev/null; }
  ports() { ss -ltnpH 2>/dev/null | grep "pid=$1," | awk '{print $4}'; }
fi
PIDS=""
plist=$(ps -axo pid=,ppid=,uid=,etime=,pcpu=,command= 2>/dev/null); ps_now=$(date +%s)
DESC=""
if [ "$OS" = Darwin ] && [ -n "${CLAUDE_PID:-}" ]; then
  # All descendants of the Claude process, computed once from the snapshot.
  DESC=$(printf '%s\n' "$plist" | awk -v root="$CLAUDE_PID" '{pp[$1]=$2}
    END{for(p in pp){q=p;n=0;while(q>1&&n<64){if(q==root){print p;break} q=pp[q];n++}}}')
fi
while read -r pid ppid uid et cpu cmd; do
  [ "$uid" = "$mine" ] || continue
  [ "$pid" = "$$" ] && continue
  [ "$ppid" = "$$" ] && continue    # our own subshells
  # Same pipeline as this audit (e.g. `audit.sh | grep`): a sibling that started with us.
  [ "$ppid" = "$PPID" ] && [ $(( ps_now - $(etime2s "$et") )) -ge $(( now - 1 )) ] && continue
  [ "$pid" = "${CLAUDE_PID:-x}" ] && continue
  case "$cmd" in *claude*--resume*|*/claude\ *|*"/audit.sh"*|bash\ -c*|/bin/bash\ -c*|-bash*|-zsh*|*snapshot-bash*|*snapshot-zsh*|ps\ -axo*) continue ;; esac
  owner=""
  { [ -n "$SID" ] || [ "$OS" = Darwin ]; } && has_sid "$pid" && owner=this_session
  inrepo=no
  if [ "$IN_GIT" = 1 ]; then cwd=$(pcwd "$pid"); case "$cwd" in "$MAIN_WT"|"$MAIN_WT"/*) inrepo=yes ;; esac; fi
  [ -z "$owner" ] && [ "$inrepo" = no ] && continue
  if [ -z "$owner" ]; then
    if recent $(( ps_now - $(etime2s "$et") )); then owner=started_during_session; else owner=other_session_or_user; fi
  fi
  # Claude Code's own MCP servers, plugins and hooks inherit the session env; they are harness, not leftovers.
  case "$cmd" in *"/.claude/"*|*mcp*|*MCP*) [ "$owner" = this_session ] && owner=harness_do_not_kill ;; esac
  PIDS="$PIDS $pid"
  echo "  pid=$pid owner=$owner in_repo=$inrepo elapsed=$(age $(( ps_now - $(etime2s "$et") ))) cpu=${cpu}% start=$(pstart "$pid") cmd=$(printf '%s' "$cmd" | cut -c1-140)"
done <<EOF
$plist
EOF
echo "listening_ports (only for the processes above):"
for pid in $PIDS; do ports "$pid" | while read -r l; do [ -n "$l" ] && echo "  pid=$pid listen=$l"; done; done

# ---------- artifacts ----------
hdr ARTIFACTS
if [ -n "$SID" ]; then
  for r in $TMPROOTS; do
    for SCR in "$r"/claude-"$mine"/*/"$SID"/scratchpad "$r"/claude/*/"$SID"/scratchpad; do
      [ -d "$SCR" ] && echo "scratchpad: $SCR size=$(sz "$SCR") files=$(find "$SCR" -type f 2>/dev/null | cnt)"
    done
  done
fi
if [ "$IN_GIT" = 1 ]; then
  for rel in .next/types .next/dev/types coverage test-results playwright-report .nyc_output; do
    find "$MAIN_WT" -path '*/node_modules' -prune -o -path '*/.git' -prune -o -path "*/$rel" -type d -print 2>/dev/null | head -20 |
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      ign=no; git -C "$MAIN_WT" check-ignore -q "$d" 2>/dev/null && ign=yes
      echo "  build_artifact: $d size=$(sz "$d") mtime=$(mtime "$d") age=$(age "$(mtime "$d")") gitignored=$ign"
    done
  done
  echo "large_files (>${BIG_MB}MB, not tracked, excluding node_modules/.git/.next):"
  find "$MAIN_WT" \( -name node_modules -o -name .git -o -name .next \) -prune -o -type f -size +"${BIG_MB}"M -print 2>/dev/null | head -30 |
    while IFS= read -r f; do git -C "$MAIN_WT" ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue; echo "  $f size=$(sz "$f") age=$(age "$(mtime "$f")")"; done
fi
if [ "$SINCE_EPOCH" -gt 0 ]; then
  echo "tmp_dirs_created_this_session (top-level temp dirs owned by you; inspect before touching):"
  ref=$(mktemp "${TMPDIR:-/tmp}/.sc-ref.XXXXXX") && touch -t "$(epoch2touch "$SINCE_EPOCH")" "$ref"
  for r in $TMPROOTS; do
    find "$r" -maxdepth 1 -mindepth 1 -type d -user "$mine" -newer "$ref" ! -name "claude-$mine" ! -name claude ! -name "lanes-$mine" 2>/dev/null | head -30 |
      while IFS= read -r d; do echo "  $d size=$(sz "$d") mtime=$(mtime "$d") open_handles=$(lsof +D "$d" 2>/dev/null | tail -n +2 | cnt)"; done
  done
  rm -f "$ref"
fi

# ---------- tracker ----------
hdr TRACKER
if [ "$IN_GIT" = 1 ] && [ -d "$MAIN_WT/.beads" ] && have bd; then
  echo "beads in_progress:"; (cd "$MAIN_WT" && run_to 30 bd list --status=in_progress 2>&1 | sed 's/^/  /' | head -30)
elif [ "$IN_GIT" = 1 ] && [ -f "$MAIN_WT/tasks.md" ]; then
  echo "tasks.md in-progress lines:"; grep -n -i -E 'in[ _-]?progress|\[~\]|\[/\]|WIP' "$MAIN_WT/tasks.md" | sed 's/^/  /' | head -30
else echo "tracker: none found"; fi

# ---------- deploy ----------
hdr DEPLOY
if [ "$IN_GIT" = 1 ]; then
  [ -n "$MAIN" ] && echo "main_tip: $(git rev-parse "$MAIN") ($(git log -1 --format=%s "$MAIN" | cut -c1-80))"
  [ -n "${REMOTE:-}" ] && [ -n "$MAIN" ] && echo "origin_main_tip: $(git rev-parse --verify -q "$REMOTE/$MAIN" || echo none)"
  plat=""
  { [ -f "$MAIN_WT/.vercel/project.json" ] || [ -f "$MAIN_WT/vercel.json" ] || [ -f "$MAIN_WT/vercel.ts" ]; } && plat="$plat vercel"
  [ -f "$MAIN_WT/netlify.toml" ] && plat="$plat netlify"
  [ -f "$MAIN_WT/fly.toml" ] && plat="$plat fly"
  { [ -f "$MAIN_WT/wrangler.toml" ] || [ -f "$MAIN_WT/wrangler.jsonc" ]; } && plat="$plat cloudflare"
  echo "platforms:${plat:- none detected}"
fi

# ---------- sessions log ----------
hdr SESSION_LOG
if [ "$IN_GIT" = 1 ] && [ -d "$MAIN_WT/_sessions" ]; then
  echo "session_log_dir: $MAIN_WT/_sessions (ignored=$(git -C "$MAIN_WT" check-ignore -q _sessions && echo yes || echo no))"
else echo "session_log_dir: none"; fi
echo
echo "audit: done (read-only)"
