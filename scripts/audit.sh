#!/usr/bin/env bash
# audit.sh [--no-fetch] [--repo <path>] [--since <ISO-8601>] [--big-mb <N>]
#
# Read-only end-of-session audit. Prints one section per area as "key: value" lines.
# The only write it ever performs is `git fetch` (updates remote-tracking refs, never prunes);
# pass --no-fetch to skip even that. It never deletes, kills, stashes or resets anything.
# It never reads .env files or prints process environments (it only greps them for the session id).
set -uo pipefail

FETCH=1 REPO="" SINCE="" BIG_MB=50
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) FETCH=0 ;;
    --repo) REPO="$2"; shift ;;
    --since) SINCE="$2"; shift ;;
    --big-mb) BIG_MB="$2"; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

hdr() { printf '\n=== %s ===\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
now=$(date +%s)
age() { # epoch -> "3d 4h" style age
  local s=$(( now - $1 )); [ "$s" -lt 0 ] && s=0
  if [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s/86400)) $((s%86400/3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%dm' $((s/3600)) $((s%3600/60))
  else printf '%dm' $((s/60)); fi
}
sz() { du -sh "$1" 2>/dev/null | cut -f1; }

# ---------- context ----------
hdr CONTEXT
if [ -n "$REPO" ]; then cd "$REPO" || { echo "error: cannot cd to $REPO"; exit 1; }; fi
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "git: not a git repository ($(pwd)); git sections skipped"
  IN_GIT=0
else
  IN_GIT=1
  COMMON=$(git rev-parse --path-format=absolute --git-common-dir)
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
if [ -z "$SINCE" ] && [ -n "${CLAUDE_PID:-}" ]; then
  SINCE=$(date -u -d "$(ps -o lstart= -p "$CLAUDE_PID" 2>/dev/null)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
fi
SINCE_EPOCH=0
[ -n "$SINCE" ] && SINCE_EPOCH=$(date -d "$SINCE" +%s 2>/dev/null || echo 0)
echo "session_start: ${SINCE:-unknown} (items newer than this may belong to this session; older items are ASK)"

if [ "$IN_GIT" = 1 ]; then
# ---------- working tree ----------
hdr WORKING_TREE
st=$(git status --porcelain=v1 2>/dev/null)
if [ -z "$st" ]; then echo "status: clean"; else
  echo "status: $(printf '%s\n' "$st" | wc -l) entries"
  printf '%s\n' "$st" | sed 's/^/  /' | head -60
  junk=$(printf '%s\n' "$st" | awk '$1=="??"{print $2}' | grep -E '(\.orig|\.rej|\.log|\.bak|\.tmp|\.swp|~|\.png|\.jpe?g|\.webp|\.gif|\.mp4|\.webm|\.har|\.trace|\.zip|nohup\.out|\.DS_Store)$|(^|/)(scratch|tmp|temp)[^/]*$' )
  [ -n "$junk" ] && { echo "junk_candidates:"; printf '%s\n' "$junk" | while read -r f; do
    m=$(stat -c %Y "$f" 2>/dev/null || echo 0); echo "  $f size=$(sz "$f") age=$(age "$m") $([ "$m" -ge "$SINCE_EPOCH" ] && [ "$SINCE_EPOCH" -gt 0 ] && echo this_session || echo pre_session)"; done; }
  envs=$(printf '%s\n' "$st" | awk '{print $NF}' | grep -E '(^|/)\.env' | grep -v '\.example$')
  [ -n "$envs" ] && echo "WARNING: .env-like paths in status (do not read, print or delete): $(printf '%s ' $envs)"
fi

# ---------- sync ----------
hdr SYNC
if [ -n "${REMOTE:-}" ]; then
  if [ "$FETCH" = 1 ]; then
    if timeout 60 git fetch --quiet "$REMOTE" 2>/tmp/.sc-fetch-err.$$; then echo "fetch: ok"; else echo "fetch: FAILED ($(head -1 /tmp/.sc-fetch-err.$$))"; fi
    rm -f /tmp/.sc-fetch-err.$$
  else echo "fetch: skipped (--no-fetch); results may be stale"; fi
  if [ -n "$MAIN" ] && git show-ref --verify --quiet "refs/remotes/$REMOTE/$MAIN"; then
    read -r behind ahead < <(git rev-list --left-right --count "$REMOTE/$MAIN...$MAIN")
    echo "$MAIN vs $REMOTE/$MAIN: ahead=$ahead behind=$behind"
    [ "$ahead" -gt 0 ] && git log --oneline "$REMOTE/$MAIN..$MAIN" | sed 's/^/  unpushed: /' | head -20
  else echo "$MAIN vs remote: no remote-tracking branch"; fi
  cur=$(git branch --show-current)
  if [ -n "$cur" ] && [ "$cur" != "$MAIN" ]; then
    up=$(git rev-parse --abbrev-ref "$cur@{upstream}" 2>/dev/null)
    if [ -n "$up" ]; then read -r b a < <(git rev-list --left-right --count "$up...$cur"); echo "current $cur vs $up: ahead=$a behind=$b"
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
  dirty=$(git -C "$p" status --porcelain 2>/dev/null | wc -l)
  ahead="?"; [ -n "$MAIN" ] && [ "$b" != "(detached)" ] && ahead=$(git rev-list --count "$MAIN..$b" 2>/dev/null)
  last=$(git -C "$p" log -1 --format=%ct 2>/dev/null || echo 0)
  echo "linked: $p [$b] inside_repo=$inside dirty_files=$dirty commits_not_in_$MAIN=$ahead last_commit_age=$(age "$last")"
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
    echo "  $br last=$(age "$(git log -1 --format=%ct "$br")")$co"
  done
  echo "not_merged_into_$MAIN:"
  git branch --no-merged "$MAIN" --format='%(refname:short)' | while read -r br; do
    n=$(git rev-list --count "$MAIN..$br"); ct=$(git log -1 --format=%ct "$br")
    # A squash/rebase merge leaves no ancestry; check whether the branch diff is already in main.
    eq=""; [ -z "$(git cherry "$MAIN" "$br" 2>/dev/null | grep '^+')" ] && eq=" PATCHES_ALREADY_IN_$MAIN"
    echo "  $br commits=$n last=$(age "$ct") $([ "$ct" -ge "$SINCE_EPOCH" ] && [ "$SINCE_EPOCH" -gt 0 ] && echo this_session || echo pre_session)$eq"
  done
  echo "upstream_gone:"
  git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads | awk '$2=="[gone]"{print "  "$1}'
  [ -n "${REMOTE:-}" ] && { rp=$(git remote prune --dry-run "$REMOTE" 2>/dev/null | grep 'would prune' | sed 's/^/  /'); echo "stale_remote_tracking (deleted on remote):"; [ -n "$rp" ] && echo "$rp"; }
fi

# ---------- stashes ----------
hdr STASHES
sl=$(git stash list --format='%gd%x09%ct%x09%s' 2>/dev/null)
if [ -z "$sl" ]; then echo "stashes: none"; else
  printf '%s\n' "$sl" | while IFS=$'\t' read -r ref ct msg; do
    flag=""; [ $(( now - ct )) -gt 604800 ] && flag=" OLDER_THAN_7D"
    [ "$ct" -ge "$SINCE_EPOCH" ] && [ "$SINCE_EPOCH" -gt 0 ] && flag="$flag THIS_SESSION"
    echo "  $ref age=$(age "$ct")$flag :: $msg"
  done
fi
fi # IN_GIT

# ---------- lanes ----------
hdr LANES
K="$HOME/.claude/skills/lanes"
if [ "$IN_GIT" = 1 ] && [ -f "$K/lane/lane-env.sh" ]; then
  S="$HOME/.local/state/lanes/$(basename "$MAIN_WT")-$(printf '%s' "$MAIN_WT" | sha256sum | cut -c1-8)"
  if [ -d "$S" ]; then
    echo "state_dir: $S"
    echo "cleanup_script: bash $K/lane/cleanup.sh <lane-dir> <branch> | --sweep (use this, not rm)"
    if [ -s "$S/lanes.tsv" ]; then
      while IFS=$'\t' read -r lane agent task wt job; do
        [ -z "$lane" ] && continue
        note=""; [ -n "$wt" ] && [ ! -d "$wt" ] && note=" WORKTREE_MISSING"
        if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$MAIN" ]; then
          br=$(git -C "$wt" branch --show-current 2>/dev/null)
          [ -n "$br" ] && git merge-base --is-ancestor "$br" "$MAIN" 2>/dev/null && note="$note BRANCH_MERGED"
        fi
        echo "  row: $lane agent=$agent wt=$wt job=$job$note"
      done < "$S/lanes.tsv"
    else echo "lanes_tsv: empty or absent"; fi
    T="/tmp/lanes-$(id -u)/$(basename "$S")"
    if [ -d "$T" ]; then
      for d in "$T"/*/; do [ -d "$d" ] || continue
        n=$(basename "$d"); br_guess="${n%-*}"
        open=$(lsof +D "$d" 2>/dev/null | tail -n +2 | wc -l)
        exists=no; git show-ref --verify --quiet "refs/heads/$br_guess" && exists=yes
        git for-each-ref --format='%(refname:short)' refs/heads | sed 's#/#-#g' | grep -qx "$br_guess" && exists=yes
        echo "  tmp: $d size=$(sz "$d") branch_exists=$exists open_handles=$open"
      done
    else echo "lane_tmp: none ($T)"; fi
  else echo "lanes: harness installed, no state for this repo"; fi
  echo "relay_jobs_running (no rc file, cwd in this repo):"
  for j in "$HOME"/.local/state/model-relay.* "$HOME"/.local/state/codex-lane.* "$HOME"/.local/state/codex-review.*; do
    [ -d "$j" ] && [ -f "$j/cwd" ] || continue
    c=$(cat "$j/cwd"); case "$c" in "$MAIN_WT"|"$MAIN_WT"/*) ;; *) continue ;; esac
    [ -f "$j/rc" ] || echo "  $j cwd=$c age=$(age "$(stat -c %Y "$j")")"
  done
else echo "lanes: not present"; fi

# ---------- processes ----------
hdr PROCESSES
mine=$(id -u)
PIDS=""
for pd in /proc/[0-9]*; do
  pid=${pd#/proc/}; [ "$pid" = "$$" ] && continue
  # Skip processes in the same pipeline as this audit (e.g. `audit.sh | grep`).
  [ "$(awk '{print $4}' "$pd/stat" 2>/dev/null)" = "$PPID" ] && continue
  [ "$(stat -c %u "$pd" 2>/dev/null)" = "$mine" ] || continue
  cwd=$(readlink "$pd/cwd" 2>/dev/null) || continue
  owner=""
  if [ -n "$SID" ] && tr '\0' '\n' < "$pd/environ" 2>/dev/null | grep -qx "CLAUDE_CODE_SESSION_ID=$SID"; then owner=this_session; fi
  inrepo=no; [ "$IN_GIT" = 1 ] && case "$cwd" in "$MAIN_WT"|"$MAIN_WT"/*) inrepo=yes ;; esac
  [ -z "$owner" ] && [ "$inrepo" = no ] && continue
  cmd=$(tr '\0' ' ' < "$pd/cmdline" 2>/dev/null | cut -c1-140)
  [ -z "$cmd" ] && continue
  # Skip the Claude process itself, its shell wrappers and this audit.
  case "$cmd" in *claude*--resume*|*/claude\ *|*"/audit.sh"*|bash\ -c*|/bin/bash\ -c*|-bash*|*snapshot-bash*) continue ;; esac
  [ "$pid" = "${CLAUDE_PID:-x}" ] && continue
  [ -z "$owner" ] && owner=other_session_or_user
  # Claude Code's own MCP servers, plugins and hooks inherit the session env; they are harness, not leftovers.
  case "$cmd" in *"/.claude/"*|*mcp*|*MCP*) [ "$owner" = this_session ] && owner=harness_do_not_kill ;; esac
  PIDS="$PIDS $pid"
  et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
  cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
  echo "  pid=$pid owner=$owner in_repo=$inrepo elapsed=$(age $(( now - ${et:-0} ))) cpu=${cpu}% cmd=$cmd"
done
echo "listening_ports (only for the processes above):"
for pid in $PIDS; do
  ss -ltnpH 2>/dev/null | grep "pid=$pid," | awk -v p="$pid" '{print "  pid=" p " listen=" $4}'
done

# ---------- artifacts ----------
hdr ARTIFACTS
SCR=$(ls -d /tmp/claude-"$mine"/*/"$SID"/scratchpad 2>/dev/null | head -1)
[ -n "$SCR" ] && echo "scratchpad: $SCR size=$(sz "$SCR") files=$(find "$SCR" -type f 2>/dev/null | wc -l)"
if [ "$IN_GIT" = 1 ]; then
  for rel in .next/types .next/dev/types coverage test-results playwright-report .nyc_output; do
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      ign=no; git -C "$MAIN_WT" check-ignore -q "$d" 2>/dev/null && ign=yes
      echo "  build_artifact: $d size=$(sz "$d") age=$(age "$(stat -c %Y "$d")") gitignored=$ign"
    done < <(find "$MAIN_WT" -path '*/node_modules' -prune -o -path "*/.git" -prune -o -path "*/$rel" -type d -print 2>/dev/null | head -20)
  done
  echo "large_files (>${BIG_MB}MB, not tracked, excluding node_modules/.git):"
  find "$MAIN_WT" \( -name node_modules -o -name .git -o -name .next \) -prune -o -type f -size +"${BIG_MB}"M -print 2>/dev/null | head -30 |
    while IFS= read -r f; do git -C "$MAIN_WT" ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue; echo "  $f size=$(sz "$f") age=$(age "$(stat -c %Y "$f")")"; done
fi
if [ "$SINCE_EPOCH" -gt 0 ]; then
  echo "tmp_dirs_created_this_session (top-level /tmp, owned by you; inspect before touching):"
  find /tmp -maxdepth 1 -mindepth 1 -type d -user "$mine" -newermt "@$SINCE_EPOCH" ! -name "claude-$mine" ! -name "lanes-$mine" 2>/dev/null | head -30 |
    while IFS= read -r d; do echo "  $d size=$(sz "$d") open_handles=$(lsof +D "$d" 2>/dev/null | tail -n +2 | wc -l)"; done
fi

# ---------- tracker ----------
hdr TRACKER
if [ "$IN_GIT" = 1 ] && [ -d "$MAIN_WT/.beads" ] && have bd; then
  echo "beads in_progress:"; (cd "$MAIN_WT" && timeout 30 bd list --status=in_progress 2>&1 | sed 's/^/  /' | head -30)
elif [ "$IN_GIT" = 1 ] && [ -f "$MAIN_WT/tasks.md" ]; then
  echo "tasks.md in-progress lines:"; grep -n -i -E 'in[ _-]?progress|\[~\]|\[/\]|WIP' "$MAIN_WT/tasks.md" | sed 's/^/  /' | head -30
else echo "tracker: none found"; fi

# ---------- deploy ----------
hdr DEPLOY
if [ "$IN_GIT" = 1 ]; then
  [ -n "$MAIN" ] && echo "main_tip: $(git rev-parse "$MAIN") ($(git log -1 --format=%s "$MAIN" | cut -c1-80))"
  [ -n "${REMOTE:-}" ] && [ -n "$MAIN" ] && echo "origin_main_tip: $(git rev-parse "$REMOTE/$MAIN" 2>/dev/null || echo none)"
  plat=""
  [ -f "$MAIN_WT/.vercel/project.json" ] || [ -f "$MAIN_WT/vercel.json" ] || [ -f "$MAIN_WT/vercel.ts" ] && plat="$plat vercel"
  [ -f "$MAIN_WT/netlify.toml" ] && plat="$plat netlify"
  [ -f "$MAIN_WT/fly.toml" ] && plat="$plat fly"
  [ -f "$MAIN_WT/wrangler.toml" ] || [ -f "$MAIN_WT/wrangler.jsonc" ] && plat="$plat cloudflare"
  echo "platforms:${plat:- none detected}"
fi

# ---------- sessions log ----------
hdr SESSION_LOG
if [ "$IN_GIT" = 1 ] && [ -d "$MAIN_WT/_sessions" ]; then
  echo "session_log_dir: $MAIN_WT/_sessions (ignored=$(git -C "$MAIN_WT" check-ignore -q _sessions && echo yes || echo no))"
else echo "session_log_dir: none"; fi
echo
echo "audit: done (read-only)"
