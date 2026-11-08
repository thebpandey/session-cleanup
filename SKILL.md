---
name: session-cleanup
description: End-of-session audit and safe cleanup of a git repo and the machine. Finds leftovers (untracked junk, unpushed commits, stale or dirty worktrees, merged and unmerged branches, stashes, lane harness state, dev servers and background processes, temp and build artifacts, open tracker items, deploy drift), removes only what is provably stale and recoverable, and asks before anything that could lose work. Use whenever the user says "cleanup", "clean up", "does anything need to be cleaned up", "session cleanup", "tidy up", "end of session", "wrap up", "are we done here", or before writing a final session report, even if they do not name this skill. Works with or without the /lanes harness. Not for refactoring, lint fixes or dead-code removal.
---

# Session cleanup

Audit first, delete second, and only after inspecting the target. The goal is that the owner can walk away from the session knowing nothing is running, nothing is lost, and nothing stale is left behind. A missed leftover is cheap; a deleted unpushed commit is not. When in doubt, a finding goes to **ASK**, never to **AUTO-CLEAN**.

Works in any git repo. The lanes harness, beads and Vercel parts switch on only when they are present; skip them silently otherwise.

## Phase 1: Audit (read-only)

Run the bundled audit from the repo (any worktree of it). Use the script for your OS; the skill folder may be under `~/.claude/skills/`, `~/.codex/skills/` or `~/.agents/skills/`:

```bash
# Linux and macOS
bash <skill-dir>/scripts/audit.sh                 # add --no-fetch offline
```

```powershell
# Windows (PowerShell 5.1 or 7)
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\audit.ps1   # add -NoFetch offline
```

Both print one section per area (CONTEXT, WORKING_TREE, SYNC, WORKTREES, BRANCHES, STASHES, LANES, PROCESSES, ARTIFACTS, TRACKER, DEPLOY, SESSION_LOG). Its only write is a plain `git fetch` (never `--prune`). It never reads `.env` files or prints process environments.

How it decides "this session" (this matters for every classification):
- **Processes:** `owner=this_session` means this session (or something it launched) started the process. On Linux that is proven by the inherited `CLAUDE_CODE_SESSION_ID`, which survives `nohup`. macOS and Windows hide other processes' environments, so there it means "descendant of the Claude process" (`CLAUDE_PID`); a process that was detached and reparented shows as `started_during_session` instead, which is ASK unless you can trace it in this conversation. `owner=harness_do_not_kill` is Claude Code's own MCP servers and plugins: never touch these. `other_session_or_user` is someone else's.
- **Files, branches, stashes:** `this_session` / `pre_session` compares the timestamp to `session_start` (first timestamp in this session's transcript). Timestamps are a hint, not proof: something created during the session window could come from a parallel session. Treat an item as this session's only when the timestamp says so **and** you can trace it in this conversation (you ran the command that created it). Otherwise it is ASK.

Outside Claude Code (for example in Codex) there is no `CLAUDE_CODE_SESSION_ID` or `CLAUDE_PID`, so `session_id` is `unknown`, everything is tagged `pre_session`, and processes are matched only by `in_repo`. Pass `--since <ISO time>` (`-Since` on Windows) with the session start if you know it, and otherwise treat files and processes as ASK unless you can trace them to a command in this conversation.

Then fill the gaps the script cannot see, in parallel where possible:
1. **Your own background work.** List background Bash tasks, Monitors, subagents and scheduled wakeups you started in this conversation and which are still running. Stop finished or idle ones with the tool that started them (TaskStop, Monitor stop, etc.).
2. **Request leftovers.** Scan the conversation for anything the owner asked to delete later or keep only temporarily (an uploads folder, a debug flag, a test account, a temporary file). Check whether it still exists.
3. **Deploy state** (only if DEPLOY shows a platform). Get the commit SHA of the latest production deployment and compare it with `main_tip`. For Vercel: `vercel ls --prod` to find the latest production deployment, then `vercel inspect <url>` (or the Vercel MCP / dashboard) for its git commit. If you cannot obtain the SHA, report "deploy: unverified" with the reason. Never infer a match from timestamps.
4. **Anything outside the repo** that the session touched (another repo's worktree, a global install). Report it; do not modify it.

## Phase 2: Classify each finding

**AUTO-CLEAN** (safe and recoverable; do it, then report it):
- Local branches fully merged into main (`git branch -d`, never `-D`), excluding main, the current branch, and any branch checked out in a worktree.
- Prunable worktree records whose folder is already gone (`git worktree prune`).
- Clean linked worktrees inside this repo whose branch is merged into main and has no commits ahead of it (`git worktree remove <path>`, no `--force`; then `git branch -d`). If the lanes harness owns it, use the harness script instead (see below).
- Temp folders whose lane or branch no longer exists and that no process has open (`open_handles=0`; recheck with `lsof +D <dir>` immediately before deleting).
- Processes with `owner=this_session` that you can trace to this conversation and that are idle or no longer needed (dev servers, watchers, headless browsers). Kill by PID only (`kill <pid>` on Linux/macOS, `Stop-Process -Id <pid>` on Windows).
- Stale build type caches (`.next/types`, `.next/dev/types`) that are gitignored. These regenerate on the next build.
- This session's own scratch files in its scratchpad folder, and untracked junk in the repo (`*.orig`, `*.rej`, stray logs) that is `this_session` **and** traceable to a command you ran.

**ASK** (could lose work, or not provably this session's):
- Unmerged branches, or any commits not in main. A branch marked `PATCHES_ALREADY_IN_main` was likely squash- or rebase-merged: say so, but still ask before `-D`.
- Dirty worktrees (`dirty_files > 0`), stashes, `coverage/` and `test-results/` that may be wanted as evidence.
- Processes `other_session_or_user` or `started_during_session`, and any process you cannot trace.
- Anything `pre_session`, and any untracked file you did not create.

**REPORT ONLY** (the owner acts, or it is informational):
- Drift between main and origin (unpushed or behind). Recommend the push or pull; do not do it as part of cleanup.
- Deploy mismatches or "unverified" deploy state.
- Open tracker items (beads `in_progress`, tasks.md WIP) with no active work, and finished work whose task is still open. Name the item and what you saw.
- Worktrees or folders outside this repo, and `upstream_gone` branches that still have unique commits.

## Safety rules

These protect work that cannot be recreated. Each one exists because the obvious shortcut has destroyed work before.

- **Inspect before deleting.** For each folder, list its contents and size first. For each branch, show `git log --oneline main..<branch>` first. Put that evidence in the report.
- **Never delete unmerged commits, dirty worktrees or stashes without the owner's explicit approval** in this conversation. Approval for one item does not cover the next.
- **Kill processes only by PID**, after confirming `owner=this_session` and that you started it. Never `pkill`, `killall`, `kill -9` on a first attempt, or kill by port alone.
- **Never** use bare `git stash`, `git reset --hard`, `git clean -fdx` (or any `git clean -f`), or `rm -rf` with a glob. These have no undo. Delete named paths one at a time.
- `git branch -D`, `git stash drop` and `git worktree remove --force` run only on the single item the owner approved, after showing what will be lost (commits, diff stat). Record the branch tip SHA in the report so it can be restored.
- **Never read, print, move or delete `.env` files, keys or credentials**, even when they look like junk. Report them by path only.
- **Stay inside this repo.** Other apps' worktrees, detached checkouts or shared `/tmp` folders are reported, not touched. Never glob-delete in `/tmp`.
- **Never kill `harness_do_not_kill` processes** or the Claude process itself.

### When the lanes harness is present

Only if the LANES section shows a state dir. Otherwise skip this block.
- Remove lane worktrees, lane temp dirs, relay job dirs and `lanes.tsv` rows with the harness's own script, never with `rm`: `bash ~/.claude/skills/lanes/lane/cleanup.sh <lane-dir> <branch>` for a merged lane, then `bash ~/.claude/skills/lanes/lane/cleanup.sh --sweep`. Run it from the main worktree.
- `WORKTREE_MISSING` and `BRANCH_MERGED` (merged into origin's main) rows go through the sweep. `MERGED_NOT_ON_origin` rows are merged locally but unpushed: REPORT ONLY, recommend `lane-finish.sh --push`. Rows for unmerged lanes are ASK.
- Relay jobs still running (no `rc` file) are REPORT ONLY; the lanes watchdog owns them.
- In a `/lanes` session the main lane integrates; do not delete a lane branch whose work is not yet merged to origin/main.

Without the harness, worktrees under `.claude/worktrees/` (for example from Claude Code's EnterWorktree) follow the plain git rules above.

## Phase 3: Report

Use this structure exactly. Keep it scannable; the owner reads it at the end of a long session.

```markdown
## Session cleanup

**Already clean:** working tree, sync, worktrees, branches, stashes, processes, artifacts, tracker, deploy
(list only the areas that passed)

**Cleaned**
- `feat/login-form` branch: merged into main at a1b2c3d, 0 commits ahead. Deleted with `git branch -d` (restore: `git branch feat/login-form a1b2c3d`).
- `python3 -m http.server 3000` (PID 170308): started by this session for preview, idle. Stopped.
- `.next/types` (1.2M): gitignored, regenerates on build.

**Needs your call**
- `feat/wip` branch: 1 commit not in main ("wip: draft parser"), last commit 2h ago, linked task bd-42 in_progress.
  Resume (keep it) or abandon (`git branch -D feat/wip`)?
- `stash@{0}` "On main: sc test stash", 5d old. Apply or drop?

**Report only**
- main is 2 commits ahead of origin/main (unpushed). Push recommended.
- Production deploy: unverified (vercel CLI not logged in).

**Next Actions**
- Run `git worktree list`, expect only the main worktree.
- Run `git status --short`, expect no output.
```

Rules for the report:
- Every "Cleaned" line says what it was, its size (for files and folders) and why it was safe. For branches include the tip SHA so it can be restored.
- Every "Needs your call" item gives the facts needed to decide (age, commit count, commit subjects, linked task) and two concrete options.
- Never say an area is clean unless the audit or a command in this session showed it. If a check was skipped (offline, CLI missing, no permission), say so under Report only.
- Next Actions always includes at least one verification command with its expected output.

After the owner answers ASK items, carry out exactly what they approved, rerun the relevant audit section, and report the result.

## Logging

If the repo has a session log folder (SESSION_LOG shows `_sessions/` or similar), append a short cleanup entry: date, what was cleaned, what is waiting on the owner. Commit it only if the project's rules allow committing session logs; check CLAUDE.md or the folder's ignore status (`ignored=yes` means do not commit).

## Out of scope

Refactoring, lint fixes, dead-code removal and dependency upgrades. If you notice them, record them as backlog items (memory or tracker) and mention them in one line. Pushing, pulling and deploying are also out of scope: recommend them, do not do them.
