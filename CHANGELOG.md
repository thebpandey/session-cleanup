# Changelog

## 1.1.0 — 2026-11-08

- New `scripts/clean.sh <plan.json> [--dry-run]` executes an approved plan of branches, worktrees, paths, processes and stashes. `--dry-run` prints what it would do and changes nothing.
- Before acting it re-verifies each item against its audit fingerprint: branch tip, worktree HEAD and cleanliness, path size and mtime, process start time and command, stash SHA. A mismatch is skipped as "changed since audit"; unsafe items are skipped as "refused (...)".
- Never `--force`, never `kill -9` (processes get SIGTERM), no globs. Forced branch deletion is `git update-ref -d` with the recorded tip.
- Refuses symlinks in any path component and `.env`, key and credential files anywhere (including inside build output such as `.next/standalone`). Directory path items with open files (`lsof`) are refused; single-file path items get no open-file check. A worktree is refused if it holds ignored files that do not regenerate (`coverage/` counts as one) or a process has its cwd inside; a standalone `coverage/` path item is not specially blocked.
- Restore ledger: one JSON line per completed action in `${XDG_STATE_HOME:-~/.local/state}/session-cleanup/ledger.jsonl`, with a shell-quoted restore command for branches, stashes and worktrees. A worktree restore recreates its branch from the recorded HEAD if needed.
- `audit.sh` adds `on_<remote>=yes|no` to branch and linked-worktree lines (the work is an ancestor of the remote's main, or has no missing patches and no merge commits). It adds `user_ignored_files=N` (ignored files that do not regenerate) to linked-worktree lines only.
- SKILL.md: AUTO-CLEAN and approved ASK items run through `clean.sh`, never hand-typed deletes. "Recoverable" means on the remote.
- `evals/clean-test.sh`: deterministic executor tests (25 checks, all passing).

## 1.0.1 — 2026-11-08

- The audit's LANES rows now tag a lane merged only into local main as `MERGED_NOT_ON_<remote>` (REPORT ONLY; push with `lane-finish.sh --push`). `BRANCH_MERGED` now means merged into the remote's main.
- Reason: lanes cleans a lane only after its merge is on origin/main, so the old tag let cleanup run before the push.

## 1.0.0

Baseline at commit 7b4d57c.

- Read-only audit of the repo and machine (`audit.sh` for Linux and macOS, `audit.ps1` for Windows).
- AUTO-CLEAN / ASK / REPORT ONLY classification of every finding.
- Fixed report format: already clean, cleaned, needs your call, report only, verification commands.
- Lanes-aware cleanup through the harness's own `cleanup.sh`.
- Evals: model-graded test cases and audit smoke tests.
