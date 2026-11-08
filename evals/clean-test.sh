#!/usr/bin/env bash
# clean-test.sh: deterministic checks for scripts/clean.sh. Builds a throwaway repo under TMPDIR with
# HOME pointed at a temp dir, so the ledger and git config never touch the real ones.
# Why: clean.sh is the only code that deletes; each check below guards a way it could lose work.
set -u
SK=$(cd "$(dirname "$0")/.." && pwd)
D=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/sc-clean.XXXXXX")" && pwd -P)
export HOME="$D/home"; unset XDG_STATE_HOME CLAUDE_CODE_SESSION_ID GIT_DIR GIT_WORK_TREE; mkdir -p "$HOME"
LEDGER="$HOME/.local/state/session-cleanup/ledger.jsonl"
FAILS=0
expect() { if [ "$2" = 0 ]; then echo "ok: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

cd "$D" && git init -q -b main repo && cd repo || exit 1
git config user.email t@example.com; git config user.name tester; git config commit.gpgsign false
echo a > a; echo .next/ > .gitignore; git add a .gitignore; git commit -qm init
git branch merged; git branch moved
MERGED_TIP=$(git rev-parse merged); MOVED_TIP=$(git rev-parse moved)
git checkout -q -b unmerged; echo u > u; git add u; git commit -qm unmerged; git checkout -q main
UNMERGED_TIP=$(git rev-parse unmerged)
# origin/main gets the side commit; mergeonly's only unpublished commit is a merge, which git cherry ignores.
git init -q --bare "$D/origin.git"; git remote add origin "$D/origin.git"
git checkout -q -b side; echo s > s; git add s; git commit -qm side; git push -q origin side:main
git checkout -q -b mergeonly main; git merge -q --no-ff side -m "merge with its own resolution"; git checkout -q main
# A clean worktree that a process is using as its cwd.
git worktree add -q "$D/repo/.claude/worktrees/busy" -b wt/busy; BUSY_HEAD=$(git -C .claude/worktrees/busy rev-parse HEAD)
(cd .claude/worktrees/busy && exec sleep 60) & BUSY_PID=$!
# decoy is a symlink to another clean worktree with the same HEAD.
git worktree add -q "$D/repo/.claude/worktrees/drop" -b wt/drop; DROP_HEAD=$(git -C .claude/worktrees/drop rev-parse HEAD)
git worktree add -q "$D/repo/.claude/worktrees/adv" -b wt/adv; ADV_HEAD=$(git -C .claude/worktrees/adv rev-parse HEAD)
git worktree add -q "$D/repo/.claude/worktrees/victim" -b wt/victim; ln -s "$D/repo/.claude/worktrees/victim" .claude/worktrees/decoy
# Next.js standalone output copies .env into ignored build output: removing the worktree would delete it.
git worktree add -q "$D/repo/.claude/worktrees/next" -b wt/next; NEXT_HEAD=$(git -C .claude/worktrees/next rev-parse HEAD)
mkdir -p .claude/worktrees/next/.next/standalone; echo FAKE=1 > .claude/worktrees/next/.next/standalone/.env
SPACED="$D/repo/.claude/worktrees/w 2"
git worktree add -q "$SPACED" -b wt/w2; W2_HEAD=$(git -C "$SPACED" rev-parse HEAD)
git worktree add -q "$D/repo/.claude/worktrees/w" -b wt/w; WT_HEAD=$(git -C .claude/worktrees/w rev-parse HEAD)
echo unsaved > .claude/worktrees/w/notes.md
echo junk > junk.log; ln -s "$D/repo/a" link; echo FAKE=1 > .env
mkdir realdir; echo keep > realdir/victim.log; ln -s realdir linkdir
JUNK_SIZE=$(wc -c < junk.log | tr -d ' ')
# Processes: P_OK matches its fingerprint; P_KEEP is planned with a wrong start time and a wrong command.
pstart() { local s; s=$(LC_ALL=C ps -o lstart= -p "$1"); if [ "$(uname -s)" = Darwin ]; then date -j -f '%a %b %d %T %Y' "$s" +%s; else date -d "$s" +%s; fi; }
sleep 120 & P_OK=$!; sleep 121 & P_KEEP=$!
# Directories: idle is deletable; held has a file kept open by a background process.
mkdir idle held; echo 1 > idle/f; echo 1 > held/f
bash -c 'exec 3<held/f; exec sleep 120' & P_HELD=$!
sleep 1
P_OK_START=$(pstart "$P_OK"); P_KEEP_START=$(pstart "$P_KEEP")
dmtime() { python3 -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
IDLE_MTIME=$(dmtime idle); HELD_MTIME=$(dmtime held)
echo tweak >> a; git stash push -q -m "test stash"; STASH_SHA=$(git stash list --format=%H)
echo before > changed.log; CHANGED_SIZE=$(wc -c < changed.log | tr -d ' ')
echo old > touched.log; touch -t 202001010000 touched.log; TOUCHED_MTIME=$(cd "$D/repo" && python3 -c 'import os; print(int(os.stat("touched.log").st_mtime))')
cat > "$D/plan.json" <<EOF
[
  {"type": "branch", "name": "merged", "tip": "$MERGED_TIP"},
  {"type": "branch", "name": "moved", "tip": "$MOVED_TIP"},
  {"type": "branch", "name": "unmerged", "tip": "$UNMERGED_TIP", "force": true},
  {"type": "worktree", "path": "$D/repo/.claude/worktrees/next", "head": "$NEXT_HEAD"},
  {"type": "worktree", "path": "$SPACED", "head": "$W2_HEAD"},
  {"type": "path", "path": "$D/repo/changed.log", "kind": "file", "size_bytes": $CHANGED_SIZE},
  {"type": "path", "path": "$D/repo/touched.log", "kind": "file", "mtime": $TOUCHED_MTIME},
  {"type": "worktree", "path": "$D/repo/.claude/worktrees/busy", "head": "$BUSY_HEAD"},
  {"type": "worktree", "path": "$D/repo/.claude/worktrees/decoy", "head": "$BUSY_HEAD"},
  {"type": "worktree", "path": "$D/repo/.claude/worktrees/adv", "head": "$ADV_HEAD"},
  {"type": "worktree", "path": "$D/repo/.claude/worktrees/drop", "head": "$DROP_HEAD"},
  {"type": "branch", "name": "wt/drop", "tip": "$DROP_HEAD"},
  {"type": "process", "pid": $P_OK, "cmd": "sleep 120", "start": $P_OK_START},
  {"type": "process", "pid": $P_KEEP, "cmd": "sleep 121", "start": $((P_KEEP_START - 5))},
  {"type": "process", "pid": $P_KEEP, "cmd": "sleep 999", "start": $P_KEEP_START},
  {"type": "stash", "sha": "0000000000000000000000000000000000000000", "message": "On main: test stash"},
  {"type": "stash", "sha": "$STASH_SHA", "message": "On main: some other stash"},
  {"type": "stash", "sha": "$STASH_SHA", "message": "On main: test stash"},
  {"type": "path", "path": "$D/repo/idle", "kind": "dir", "mtime": $IDLE_MTIME},
  {"type": "path", "path": "$D/repo/held", "kind": "dir", "mtime": $HELD_MTIME},
  {"type": "worktree", "path": "$D/repo/.claude/worktrees/w", "head": "$WT_HEAD"},
  {"type": "path", "path": "$D/repo/junk.log", "kind": "file", "size_bytes": $JUNK_SIZE},
  {"type": "path", "path": "$D/repo/link", "kind": "file", "size_bytes": 2},
  {"type": "path", "path": "$D/repo/linkdir/victim.log", "kind": "file", "size_bytes": 5},
  {"type": "path", "path": "$D/repo/.env", "kind": "file", "size_bytes": 7}
]
EOF
# The branch moves after the plan was written: its recorded tip no longer matches.
git checkout -q moved; echo c > c; git add c; git commit -qm "new work"; git checkout -q main
echo "edited after the plan" >> changed.log
touch -t 202101010000 touched.log   # same size, new mtime
git -C .claude/worktrees/adv commit -q --allow-empty -m "work after the plan"

OUT=$(bash "$SK/scripts/clean.sh" "$D/plan.json" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && git show-ref -q refs/heads/merged && [ -f junk.log ] && [ ! -e "$LEDGER" ] && has "would: branch merged"
expect "--dry-run changes nothing and writes no ledger" $?

OUT=$(bash "$SK/scripts/clean.sh" "$D/plan.json" 2>&1); rc=$?
printf '%s\n' "$OUT" | sed 's/^/  | /'
expect "exit 0 when every item is done or skipped" "$rc"
! git show-ref -q refs/heads/merged && grep -qF "\"restore\": \"git branch merged $MERGED_TIP\"" "$LEDGER" && has "restore: git branch merged $MERGED_TIP"
expect "matching branch deleted, ledger holds its restore line" $?
git show-ref -q refs/heads/moved && has "skipped: branch moved: changed since audit (tip $MOVED_TIP is now"
expect "branch whose tip moved after the plan is skipped" $?
[ -d .claude/worktrees/w ] && has "skipped: worktree $D/repo/.claude/worktrees/w: refused (dirty"
expect "dirty worktree is refused" $?
[ -L link ] && has "skipped: path $D/repo/link: refused (symlink in path ($D/repo/link))"
expect "symlinked path is refused" $?
[ -f realdir/victim.log ] && has "skipped: path $D/repo/linkdir/victim.log: refused (symlink in path ($D/repo/linkdir))"
expect "path through a symlinked parent is refused and its target survives" $?
[ -f .env ] && has "skipped: path $D/repo/.env: refused (env, key or credential file)"
expect ".env path is refused" $?
[ -f touched.log ] && has "skipped: path $D/repo/touched.log: changed since audit (mtime $TOUCHED_MTIME is now"
expect "file whose mtime changed after the plan survives" $?
[ -d .claude/worktrees/busy ] && has "worktrees/busy: refused (a process has its cwd inside)"
expect "worktree used as a process cwd is refused" $?
kill "$BUSY_PID" 2>/dev/null
sleep 1
st=$(ps -o stat= -p "$P_OK" 2>/dev/null); case "$st" in ''|Z*) true ;; *) false ;; esac && has "done: process $P_OK: kill -TERM $P_OK"
expect "process with matching cmd and start time is stopped" $?
kill -0 "$P_KEEP" 2>/dev/null && has "skipped: process $P_KEEP: changed since audit (start" && has "skipped: process $P_KEEP: changed since audit (command is now"
expect "process with a different start time or command is skipped" $?
[ -z "$(git stash list)" ] && has "restore: git stash store -m On\\ main:\\ test\\ stash $STASH_SHA"
expect "stash dropped by sha with its restore line" $?
has "skipped: stash 0000000000000000000000000000000000000000: changed since audit (no stash with this sha)" &&
  has "skipped: stash $STASH_SHA: changed since audit (message is now: On main: test stash)"
expect "stash with an unknown sha or a different message is skipped" $?
[ ! -e idle ] && [ -f held/f ] && has "skipped: path $D/repo/held: refused (1 open files inside)"
expect "idle directory deleted; directory with an open file refused" $?
kill "$P_OK" "$P_KEEP" "$P_HELD" 2>/dev/null
[ -d .claude/worktrees/adv ] && has "worktrees/adv: changed since audit (HEAD $ADV_HEAD is now"
expect "worktree whose HEAD moved after the plan survives" $?
[ -d .claude/worktrees/victim ] && has "worktrees/decoy: refused (symlink in path"
expect "symlinked worktree path is refused and its target survives" $?
AUDIT=$(bash "$SK/scripts/audit.sh" --no-fetch 2>&1)
printf '%s\n' "$AUDIT" | grep -qE '^  mergeonly .* on_origin=no' && printf '%s\n' "$AUDIT" | grep -qE '^  side .* on_origin=yes'
expect "audit: branch whose only unpublished commit is a merge is on_origin=no; published branch is yes" $?
[ -f changed.log ] && has "skipped: path $D/repo/changed.log: changed since audit (size $CHANGED_SIZE is now"
expect "file changed after the plan survives" $?
[ -f .claude/worktrees/next/.next/standalone/.env ] && has "worktrees/next: refused (contains an env, key or credential file)"
expect "worktree with .env in ignored build output is refused" $?
! git show-ref -q refs/heads/unmerged && has "restore: git branch unmerged $UNMERGED_TIP"
expect "forced branch with matching tip deleted" $?
[ ! -e junk.log ] && [ "$(grep -c . "$LEDGER")" = 9 ]
expect "matching file deleted; ledger has exactly the nine completed actions" $?
# The plan removed the worktree and then its branch; the ledger's restore line must bring both back.
RESTORE=$(python3 -c 'import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["kind"] == "worktree" and e["target"].endswith("/worktrees/drop"): print(e["restore"])' "$LEDGER")
[ ! -e .claude/worktrees/drop ] && ! git show-ref -q refs/heads/wt/drop && [ -n "$RESTORE" ] && eval "$RESTORE" >/dev/null 2>&1 &&
  [ "$(git -C .claude/worktrees/drop rev-parse HEAD)" = "$DROP_HEAD" ] && [ "$(git -C .claude/worktrees/drop branch --show-current)" = wt/drop ]
expect "worktree restore line works after its branch was also deleted" $?
RESTORE=$(printf '%s\n' "$OUT" | grep -F "restore: git branch wt/w2 " | sed 's/^restore: //')
[ ! -e "$SPACED" ] && [ -n "$RESTORE" ] && eval "$RESTORE" >/dev/null 2>&1 && [ -f "$SPACED/a" ]
expect "restore line for a worktree path with a space round-trips through eval" $?

cd / && rm -rf "$D"
echo "clean_test_failures=$FAILS"
[ "$FAILS" = 0 ]
