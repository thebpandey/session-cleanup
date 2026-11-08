# Changelog

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
