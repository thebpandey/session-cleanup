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
# Next.js standalone output copies .env into ignored build output: removing the worktree would delete it.
git worktree add -q "$D/repo/.claude/worktrees/next" -b wt/next; NEXT_HEAD=$(git -C .claude/worktrees/next rev-parse HEAD)
mkdir -p .claude/worktrees/next/.next/standalone; echo FAKE=1 > .claude/worktrees/next/.next/standalone/.env
SPACED="$D/repo/.claude/worktrees/w 2"
git worktree add -q "$SPACED" -b wt/w2; W2_HEAD=$(git -C "$SPACED" rev-parse HEAD)
git worktree add -q "$D/repo/.claude/worktrees/w" -b wt/w; WT_HEAD=$(git -C .claude/worktrees/w rev-parse HEAD)
echo unsaved > .claude/worktrees/w/notes.md
echo junk > junk.log; ln -s "$D/repo/a" link; echo FAKE=1 > .env
JUNK_SIZE=$(wc -c < junk.log | tr -d ' ')
echo before > changed.log; CHANGED_SIZE=$(wc -c < changed.log | tr -d ' ')
cat > "$D/plan.json" <<EOF
[
  {"type": "branch", "name": "merged", "tip": "$MERGED_TIP"},
  {"type": "branch", "name": "moved", "tip": "$MOVED_TIP"},
  {"type": "branch", "name": "unmerged", "tip": "$UNMERGED_TIP", "force": true},
  {"type": "worktree", "path": "$D/repo/.claude/worktrees/next", "head": "$NEXT_HEAD"},
  {"type": "worktree", "path": "$SPACED", "head": "$W2_HEAD"},
  {"type": "path", "path": "$D/repo/changed.log", "kind": "file", "size_bytes": $CHANGED_SIZE},
  {"type": "worktree", "path": "$D/repo/.claude/worktrees/w", "head": "$WT_HEAD"},
  {"type": "path", "path": "$D/repo/junk.log", "kind": "file", "size_bytes": $JUNK_SIZE},
  {"type": "path", "path": "$D/repo/link", "kind": "file", "size_bytes": 2},
  {"type": "path", "path": "$D/repo/.env", "kind": "file", "size_bytes": 7}
]
EOF
# The branch moves after the plan was written: its recorded tip no longer matches.
git checkout -q moved; echo c > c; git add c; git commit -qm "new work"; git checkout -q main
echo "edited after the plan" >> changed.log

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
[ -L link ] && has "skipped: path $D/repo/link: refused (symlink)"
expect "symlinked path is refused" $?
[ -f .env ] && has "skipped: path $D/repo/.env: refused (env, key or credential file)"
expect ".env path is refused" $?
[ -f changed.log ] && has "skipped: path $D/repo/changed.log: changed since audit (size $CHANGED_SIZE is now"
expect "file changed after the plan survives" $?
[ -f .claude/worktrees/next/.next/standalone/.env ] && has "worktrees/next: refused (contains an env, key or credential file)"
expect "worktree with .env in ignored build output is refused" $?
! git show-ref -q refs/heads/unmerged && has "restore: git branch unmerged $UNMERGED_TIP"
expect "forced branch with matching tip deleted" $?
[ ! -e junk.log ] && [ "$(grep -c . "$LEDGER")" = 4 ]
expect "matching file deleted; ledger has exactly the four completed actions" $?
RESTORE=$(printf '%s\n' "$OUT" | grep -F "restore: git worktree add" | sed 's/^restore: //')
[ ! -e "$SPACED" ] && [ -n "$RESTORE" ] && eval "$RESTORE" >/dev/null 2>&1 && [ -f "$SPACED/a" ]
expect "restore line for a worktree path with a space round-trips through eval" $?

cd / && rm -rf "$D"
echo "clean_test_failures=$FAILS"
[ "$FAILS" = 0 ]
