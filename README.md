# session-cleanup

A Claude Code and Codex skill that audits a git repository and the machine at the end of a work session, removes leftovers that are provably stale and recoverable, and asks before touching anything that could lose work. Licensed under [MIT](LICENSE).

**Current release: 1.1.0** · [Changelog](CHANGELOG.md)

Long agent sessions leave debris: merged branches, worktrees whose folders were deleted, dev servers still listening on a port, stashes nobody remembers, build caches, temp folders, commits that never got pushed. Cleaning that up by hand is tedious, and letting an agent do it carelessly is dangerous. This skill makes the agent **audit first, inspect every target, delete only what passes explicit safety rules, and hand everything else back to you with the facts needed to decide.**

## What it does

When triggered, the agent:

1. **Audits** the repo and machine using a bundled read-only script (`scripts/audit.sh` on Linux and macOS, `scripts/audit.ps1` on Windows), plus checks the script cannot do itself (its own background tasks, things you asked it to delete later, deploy state).
2. **Classifies** every finding as `AUTO-CLEAN`, `ASK` or `REPORT ONLY`.
3. **Cleans** only the `AUTO-CLEAN` items, after inspecting each one.
4. **Reports** in a fixed format: what was already clean, what it removed (with size, reason and how to restore it), what needs your call (with two concrete options each), and verification commands with expected output.

### Areas audited

| Area | What is checked |
|---|---|
| Working tree | `git status`; untracked junk such as `*.orig`, `*.rej`, stray logs, screenshots, scratch files |
| Sync | `git fetch` (no prune), then main vs `origin/main` ahead/behind and unpushed commits |
| Worktrees | Each linked worktree: dirty files, commits not in main, last-commit age, inside or outside the repo; `git worktree prune --dry-run` |
| Branches | Merged into main, not merged (with commit count, and a squash-merge hint via `git cherry`), upstream gone, remote-tracking refs deleted on the remote |
| Stashes | Age, older than 7 days, created during this session |
| Lanes harness | Only if present: `lanes.tsv` rows pointing at missing worktrees or merged branches, orphaned `/tmp/lanes-<uid>/` folders, relay jobs still running |
| Processes | Processes started by this session, processes running inside the repo, and their listening ports |
| Artifacts | Session scratchpad, `.next/types`, `.next/dev/types`, `coverage/`, `test-results/`, `playwright-report/`, large untracked files, `/tmp` folders created during the session |
| Task tracker | Beads (`bd list --status=in_progress`) or `tasks.md` in-progress items |
| Deploy | Main tip vs origin tip, detected platform (Vercel, Netlify, Fly, Cloudflare); the agent then compares the production deployment's commit |
| Session log | Whether the repo keeps a `_sessions/` folder for a cleanup entry |

### Classification

**AUTO-CLEAN** (safe and recoverable):
- Local branches fully merged into main, deleted with `git branch -d` (never `-D`), skipping main, the current branch and any branch checked out in a worktree.
- Worktree records whose folder is already gone (`git worktree prune`).
- Clean linked worktrees inside the repo whose branch is merged and has no commits ahead.
- Temp folders whose lane or branch no longer exists and that no process has open (`lsof +D`).
- Idle processes this session started and the agent can trace in the conversation, killed by PID.
- Gitignored build type caches that regenerate on the next build.

**ASK** (could lose work, or not provably this session's):
- Unmerged branches or commits, dirty worktrees, stashes, `coverage/` and `test-results/` that may be wanted as evidence.
- Processes from other sessions or users, and anything created before this session.

**REPORT ONLY**:
- Drift between main and origin (the skill recommends a push, it never pushes).
- Deploy mismatches, or deploy state it could not verify.
- Open tracker items, and worktrees or folders outside the repo.

**Lanes rows.** A `lanes.tsv` row tagged `BRANCH_MERGED` is merged into the remote's main and goes through the lanes sweep. A row tagged `MERGED_NOT_ON_<remote>` (for example `MERGED_NOT_ON_origin`) is merged only into local main: REPORT ONLY, push it with `lane-finish.sh --push` first.

### Safety rules

These are non-negotiable in the skill:

- Inspect before deleting: list folder contents and size; show `git log main..<branch>` for branches.
- Never delete unmerged commits, dirty worktrees or stashes without explicit approval for that specific item.
- Kill processes only by PID, after confirming this session started them. Never `pkill` or `killall`.
- Never use bare `git stash`, `git reset --hard`, `git clean -fdx` or glob `rm -rf`.
- Never read, print, move or delete `.env` files, keys or credentials.
- Never touch worktrees or folders outside the repo; report them.
- Never kill Claude Code's own MCP servers, plugins or the Claude process.
- With the lanes harness, remove lane worktrees through its `cleanup.sh`, never with `rm`.

## How cleanup is executed

The agent never deletes by hand. It writes an approved plan (a JSON array of branch, worktree, path, process and stash items, each with the fingerprint the audit captured) and runs the bundled executor from the repo:

```bash
bash ~/.agents/skills/session-cleanup/scripts/clean.sh plan.json --dry-run   # prints what it would do, changes nothing
bash ~/.agents/skills/session-cleanup/scripts/clean.sh plan.json
```

- **Re-verification.** Right before acting, each item is checked against its fingerprint (branch tip, worktree HEAD and cleanliness, path size and mtime, process start time and command, stash SHA). Anything that moved is skipped as `changed since audit`; anything unsafe is skipped as `refused (...)`.
- **Hard limits.** No `--force`, no `kill -9`, no globs. Forced branch deletion is `git update-ref -d` with the recorded tip. It refuses symlinks in any path component, `.env`, key and credential files anywhere (even inside build output such as `.next/standalone`), open files (`lsof`), and `coverage/`.
- **Ledger and restore.** Each completed action appends one JSON line to `${XDG_STATE_HOME:-~/.local/state}/session-cleanup/ledger.jsonl`, with a shell-quoted restore command for branches, stashes and worktrees. A worktree restore recreates its branch from the recorded HEAD if needed.
- **Recoverable means on the remote.** The audit tags branches and worktrees with `on_<remote>=yes|no` (an ancestor of the remote's main, or no missing patches and no merge commits), and worktrees with `user_ignored_files=N` (ignored files that do not regenerate).

## How it knows what "this session" created

Ownership decides whether something is `AUTO-CLEAN` or `ASK`, so the skill uses the strongest signals available:

- **Processes.** Claude Code sets `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID` in its environment, and every process it launches inherits them.
  - **Linux:** the audit greps each process's environment (`/proc/<pid>/environ`) for the exact session ID, never printing it. This survives `nohup` and `setsid` reparenting.
  - **macOS and Windows:** neither OS lets you read another process's environment (macOS 27 strips it even for your own processes), so the audit uses ancestry: a descendant of `CLAUDE_PID` is `this_session`. A process that was detached and reparented, but started after the session began, is tagged `started_during_session` and treated as `ASK`.
  - Claude Code's own MCP servers and plugins also match, so they are tagged `owner=harness_do_not_kill`. Everything else is `other_session_or_user`.
- **Files, branches and stashes.** Timestamps are compared to the session start, taken from the first timestamp in the session transcript (`~/.claude/projects/*/<session-id>.jsonl`), falling back to the Claude process start time. Items are tagged `this_session` or `pre_session`.
- **Timestamps are a hint, not proof.** A parallel session could create files in the same window. The skill treats an item as this session's only when the timestamp agrees **and** the agent can trace its creation to a command in the current conversation. Anything else goes to `ASK`.

## Install

The skill is a folder with `SKILL.md` at its root. Clone it once and link it wherever your agent looks for skills.

### Claude Code (Linux, macOS)

```bash
git clone https://github.com/thebpandey/session-cleanup.git ~/.agents/skills/session-cleanup
mkdir -p ~/.claude/skills && ln -s ~/.agents/skills/session-cleanup ~/.claude/skills/session-cleanup
```

### Codex (Linux, macOS)

Codex reads user skills from `~/.codex/skills/` (newer releases also read `~/.agents/skills/`):

```bash
mkdir -p ~/.codex/skills && ln -s ~/.agents/skills/session-cleanup ~/.codex/skills/session-cleanup
```

Or ask Codex: `Use $skill-installer to install session-cleanup from https://github.com/thebpandey/session-cleanup.`

### Windows (PowerShell)

```powershell
git clone https://github.com/thebpandey/session-cleanup.git "$HOME\.agents\skills\session-cleanup"
New-Item -ItemType Junction -Path "$HOME\.claude\skills\session-cleanup" -Target "$HOME\.agents\skills\session-cleanup" -Force
New-Item -ItemType Junction -Path "$HOME\.codex\skills\session-cleanup"  -Target "$HOME\.agents\skills\session-cleanup" -Force
```

Update later with `git -C ~/.agents/skills/session-cleanup pull`. Start a new session; `session-cleanup` appears in the skills list.

### Requirements

| Platform | Script | Needs |
|---|---|---|
| Linux | `audit.sh` | bash, git 2.31+, coreutils, `ss`, optional `lsof` |
| macOS | `audit.sh` | stock bash 3.2 and BSD tools are enough; git 2.31+ (Xcode CLT), `lsof` |
| Windows | `audit.ps1` | Windows PowerShell 5.1 or PowerShell 7, Git for Windows |

Optional everywhere: `bd` (Beads tracker), `vercel` CLI (deploy check), the [lanes](https://github.com/thebpandey) harness.

## Use

Say any of these in a Claude Code session:

```text
cleanup
clean up
does anything need to be cleaned up?
session cleanup
tidy up
end of session
wrap up
```

It can also run before a final session report. You can invoke it explicitly with `/session-cleanup`.

### Running the audit by hand

The scripts are useful on their own. They are read-only apart from a plain `git fetch`:

```bash
bash ~/.agents/skills/session-cleanup/scripts/audit.sh             # from anywhere inside the repo
bash ~/.agents/skills/session-cleanup/scripts/audit.sh --no-fetch  # fully offline, no writes at all
bash ~/.agents/skills/session-cleanup/scripts/audit.sh --repo ~/dev/myapp --big-mb 100
bash ~/.agents/skills/session-cleanup/scripts/audit.sh --since 2026-11-06T09:00:00Z
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.agents\skills\session-cleanup\scripts\audit.ps1" -NoFetch
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.agents\skills\session-cleanup\scripts\audit.ps1" -Repo C:\dev\myapp -BigMB 100
```

The PowerShell flags are `-NoFetch`, `-Repo`, `-Since` and `-BigMB`, with the same meaning as below.

| Flag | Meaning |
|---|---|
| `--no-fetch` | Skip `git fetch`; sync results may be stale |
| `--repo <path>` | Audit this repo instead of the current directory |
| `--since <ISO-8601>` | Override the detected session start |
| `--big-mb <N>` | Size threshold for the large-file scan (default 50) |

Output is one section per area with `key: value` lines, for example:

```text
=== BRANCHES ===
merged_into_main:
  feat/merged last=0m
not_merged_into_main:
  feat/wip commits=1 last=2h this_session
upstream_gone:
  feat/wip

=== PROCESSES ===
  pid=164662 owner=this_session in_repo=yes elapsed=12m cpu=0.0% cmd=npm run dev
  pid=146303 owner=harness_do_not_kill in_repo=no elapsed=3h cpu=0.0% cmd=node .../mcp.mjs
listening_ports (only for the processes above):
  pid=164662 listen=127.0.0.1:3000
```

Branch and worktree lines also carry `on_origin=yes|no`, and worktree lines `user_ignored_files=N`.

Outside a Claude Code session the session ID is unknown, so ownership tags fall back to `in_repo` only and timestamps are tagged `pre_session`.

## Example report

```markdown
## Session cleanup

**Already clean:** working tree, worktrees, stashes, processes, tracker, deploy

**Cleaned**
- `fix/typo` branch: merged into main, 0 commits ahead. Deleted with `git branch -d`
  (restore: `git branch fix/typo 04b0582`).
- `.next/types` (8K): gitignored, regenerates on the next build.

**Needs your call**
- `feat/parser` branch: 1 commit not in main ("wip: draft parser"), last commit 2h ago.
  Keep it, or abandon it (`git branch -D feat/parser`)?

**Report only**
- main is 2 commits ahead of origin/main (unpushed). Push recommended.

**Next Actions**
- Run `git worktree list`, expect only the main worktree.
- Run `git status --short`, expect no output.
```

## Repository layout

```text
session-cleanup/
├── SKILL.md              # skill instructions: phases, classification, safety rules, report format
├── scripts/
│   ├── audit.sh          # read-only audit, Linux and macOS (bash 3.2+)
│   ├── clean.sh          # executes an approved plan with re-verification and a restore ledger
│   └── audit.ps1         # read-only audit, Windows (PowerShell 5.1+)
└── evals/                # test cases in the `claude plugin eval` format
    ├── plain-git-mixed-leftovers/
    ├── mostly-clean-repo/
    ├── benchmark-iteration-1.md  # first eval run: with vs without the skill
    ├── clean-test.sh     # deterministic executor tests
    ├── smoke.sh          # builds a fixture and runs audit.sh against it (Linux, macOS)
    └── smoke.ps1         # same for audit.ps1 (Windows)
```

## Evaluation

Each test case has a `place-files.sh` that builds a throwaway repo (with a local bare remote) full of planted leftovers, a prompt, and one grader file per assertion.

- **plain-git-mixed-leftovers**: merged and unmerged branches, a dirty worktree, a worktree whose folder was deleted, a stash, `.rej` and log junk, an untracked `.env.local`, unpushed commits. No lanes harness.
- **mostly-clean-repo**: one merged branch and a gitignored `.next/types` cache, otherwise clean and pushed.

First iteration, Claude Sonnet, one run per configuration, graded on the fixture's final git state:

| Case | With skill | Without skill |
|---|---|---|
| plain-git-mixed-leftovers | 8/8 | 5/8 |
| mostly-clean-repo | 4/4 | 1/4 |

Without the skill the model was already cautious (it kept unmerged work and did not read `.env.local`), but it cleaned nothing, not even branches git confirms are merged, and gave no verification commands. With the skill it removed only the provably safe items, recorded restore SHAs, and ended with verification commands. The skill added about 15 seconds per run at equal token cost.

Full numbers (pass rate, time and tokens, with spread): [evals/benchmark-iteration-1.md](evals/benchmark-iteration-1.md).

The audit scripts also have a smoke test that builds the mixed-leftovers fixture, starts a fake session process and runs the audit. Verified on Ubuntu 24.04 (bash 5), macOS 27 on Apple silicon (bash 3.2, about 4 seconds), and Windows 11 (PowerShell 5.1):

```bash
bash evals/smoke.sh "$PWD"                                                    # Linux, macOS
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File evals\smoke.ps1 -Skill $PWD   # Windows
```

Run the cases yourself with Claude Code v2.1.269 or later, from the repo root:

```bash
claude plugin eval . --allow-tools Write,Edit,Bash --scaffold
```

These are real, billed model runs.

## Limitations

- On macOS and Windows, process ownership relies on ancestry from the Claude process, so a dev server started with `nohup` and reparented is only `started_during_session`, never auto-cleaned.
- On Windows, "in repo" for a process means its command line mentions the repo path; Windows does not expose another process's working directory.
- Outside Claude Code (for example Codex) there is no session ID, so ownership tags fall back to timestamps you pass with `--since`, and the agent asks more often.
- The model-graded tests cover git leftovers only; process, lanes, tracker and deploy checks are covered by the smoke tests and manual runs.
- Deploy verification depends on the platform CLI being installed and logged in; when the production commit cannot be determined, the skill reports `deploy: unverified` rather than guessing.
- The temp-folder scan lists any folder you own that was created during the session window, which can include another session's folders. Those always go to `ASK`.

## License

[MIT](LICENSE) © 2026 Bhaskar Pandey, Almora Technology
