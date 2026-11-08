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
echo a > a; git add a; git commit -qm init
git branch merged; git branch moved
MERGED_TIP=$(git rev-parse merged); MOVED_TIP=$(git rev-parse moved)
git worktree add -q "$D/repo/.claude/worktrees/w" -b wt/w; WT_HEAD=$(git -C .claude/worktrees/w rev-parse HEAD)
echo unsaved > .claude/worktrees/w/notes.md
echo junk > junk.log; ln -s "$D/repo/a" link; echo FAKE=1 > .env
JUNK_SIZE=$(wc -c < junk.log | tr -d ' ')
cat > "$D/plan.json" <<EOF
[
  {"type": "branch", "name": "merged", "tip": "$MERGED_TIP"},
  {"type": "branch", "name": "moved", "tip": "$MOVED_TIP"},
  {"type": "worktree", "path": "$D/repo/.claude/worktrees/w", "head": "$WT_HEAD"},
  {"type": "path", "path": "$D/repo/junk.log", "kind": "file", "size_bytes": $JUNK_SIZE},
  {"type": "path", "path": "$D/repo/link", "kind": "file", "size_bytes": 2},
  {"type": "path", "path": "$D/repo/.env", "kind": "file", "size_bytes": 7}
]
EOF
# The branch moves after the plan was written: its recorded tip no longer matches.
git checkout -q moved; echo c > c; git add c; git commit -qm "new work"; git checkout -q main

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
[ ! -e junk.log ] && [ "$(grep -c . "$LEDGER")" = 2 ]
expect "matching file deleted; ledger has exactly the two completed actions" $?

cd / && rm -rf "$D"
echo "clean_test_failures=$FAILS"
[ "$FAILS" = 0 ]
