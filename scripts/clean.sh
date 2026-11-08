#!/usr/bin/env bash
# clean.sh <plan.json> [--dry-run]
#
# Executes an approved cleanup plan (written from scripts/audit.sh output). Right before acting it
# re-checks every target against the fingerprint captured at audit time; anything changed or unsafe
# is skipped, never forced. Each completed action is appended to the ledger with its restore command.
# Plan: JSON array of {"type": "branch"|"worktree"|"path"|"process"|"stash", ...fingerprint}.
# Exit: 0 every item done or skipped, 1 a command failed or an item was invalid, 2 bad usage or plan.
# Compatible with bash 3.2 (macOS default) and GNU or BSD userland; needs python3 for JSON.
set -uo pipefail

PLAN="" DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) PLAN="$arg" ;;
  esac
done
[ -f "$PLAN" ] || { echo "usage: clean.sh <plan.json> [--dry-run]" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: run clean.sh from inside the repo" >&2; exit 2; }

OS=$(uname -s); mine=$(id -u)
if [ "$OS" = Darwin ]; then
  mtime() { stat -f %m "$1" 2>/dev/null; }
  fuid() { stat -f %u "$1" 2>/dev/null; }
  fsize() { stat -f %z "$1" 2>/dev/null; }
  dsize() { find "$1" -type f -exec stat -f %z {} + 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
  lstart2epoch() { date -j -f '%a %b %d %T %Y' "$1" +%s 2>/dev/null; }
  cwds() { lsof -a -u "$mine" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; return 0; }
else
  mtime() { stat -c %Y "$1" 2>/dev/null; }
  fuid() { stat -c %u "$1" 2>/dev/null; }
  fsize() { stat -c %s "$1" 2>/dev/null; }
  dsize() { find "$1" -type f -exec stat -c %s {} + 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
  lstart2epoch() { date -d "$1" +%s 2>/dev/null; }
  # Unreadable or vanished /proc entries are normal; return 0 so pipefail keeps the matches found.
  cwds() { for c in /proc/[0-9]*/cwd; do readlink "$c" 2>/dev/null; done; return 0; }
fi
pstart() { local s; s=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) && [ -n "$s" ] && lstart2epoch "$s"; }
q() { printf '%q' "$1"; }  # shell-quote one restore-command argument
under() { awk -v r="$1" '$0==r || index($0, r "/")==1 {f=1} END{exit !f}'; } # stdin has a path at or under $1

COMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
MAIN_WT=$(dirname "$COMMON")
# Ignored output that regenerates on the next build; same set as lanes worktree-tools.py cleanup().
REGEN='(^|/)(__pycache__|\.ruff_cache|\.pytest_cache|\.mypy_cache|node_modules|dist|build|\.next|\.turbo|coverage)(/|$)|\.(pyc|tsbuildinfo)$'
SECRET_FIND='-name .env* -o -name *.pem -o -name *.key -o -name id_rsa* -o -name id_ed25519* -o -name id_ecdsa* -o -name *.p12 -o -name *.pfx -o -name *credential* -o -name *secret*'
# has_secret <dir>: any env, key or credential file anywhere inside, including ignored build output
# (Next.js standalone copies .env). Templates such as .env.example are allowed.
has_secret() {
  # shellcheck disable=SC2086 # SECRET_FIND is a list of find predicates; set -f stops glob expansion
  [ -n "$(set -f; find "$1" \( $SECRET_FIND \) ! -name '*.example' ! -name '*.sample' ! -name '*.template' -print 2>/dev/null | head -1)" ]
}

# Paths may be deleted only strictly inside: this repo, this session's scratchpad, the user's own TMPDIR.
ROOTS="$MAIN_WT"
SID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -n "$SID" ]; then
  for s in /tmp/claude-"$mine"/*/"$SID"/scratchpad "${TMPDIR:-/tmp}"/claude-"$mine"/*/"$SID"/scratchpad; do
    [ -d "$s" ] && ROOTS="$ROOTS
$(cd "$s" && pwd -P)"
  done
fi
if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
  t=$(cd "$TMPDIR" && pwd -P)
  case "$t" in /|/tmp|/private/tmp|/var/tmp|/private/var/tmp|"$(cd "$HOME" && pwd -P)") ;;
    *) [ "$(fuid "$t")" = "$mine" ] && ROOTS="$ROOTS
$t" ;; esac
fi
in_roots() { # strictly inside a root, never the root itself
  local r
  while IFS= read -r r; do case "$1" in "$r"/*) return 0 ;; esac; done <<EOF
$ROOTS
EOF
  return 1
}
# symlink_in <path>: prints the first symlink component from the leaf up to its allowed root. A symlink
# anywhere could redirect the delete to another target that has the same fingerprint, so check before resolving.
symlink_in() {
  local x="${1%/}" r
  while [ -n "$x" ] && [ "$x" != / ] && [ "$x" != . ]; do
    [ -L "$x" ] && { echo "$x"; return 0; }
    r=$(cd "$x" 2>/dev/null && pwd -P) && printf '%s\n' "$ROOTS" | grep -qxF -- "$r" && return 1
    x=$(dirname "$x")
  done
  return 1
}

LEDGER="${XDG_STATE_HOME:-$HOME/.local/state}/session-cleanup/ledger.jsonl"
ledger() { # ledger <target> <restore>
  mkdir -p "$(dirname "$LEDGER")" && python3 -c '
import json, sys, time
repo, kind, target, item, restore = sys.argv[1:]
print(json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "repo": repo, "kind": kind,
                  "target": target, "fingerprint": json.loads(item), "restore": restore}))' \
    "$MAIN_WT" "$type" "$1" "$item" "$2" >> "$LEDGER"
}

FAIL=0
skip() { echo "skipped: $1: changed since audit ($2)"; }
refuse() { echo "skipped: $1: refused ($2)"; }
act() { # act <target> <restore> cmd...
  local target="$1" restore="$2"; shift 2
  if [ "$DRY" = 1 ]; then echo "would: $target: $*"; return; fi
  if "$@"; then
    echo "done: $target: $*"; echo "restore: $restore"
    ledger "$target" "$restore" || { echo "failed: $target: could not write ledger $LEDGER"; FAIL=1; }
  else echo "failed: $target: $*"; FAIL=1; fi
}

do_branch() {
  local name="$a" tip="$b" force="$c" t="branch $a" cur
  git check-ref-format "refs/heads/$name" || { refuse "$t" "invalid branch name"; return; }
  cur=$(git rev-parse --verify -q "refs/heads/$name") || { skip "$t" "branch is gone"; return; }
  [ "$cur" = "$tip" ] || { skip "$t" "tip $tip is now $cur"; return; }
  if git worktree list --porcelain | grep -qxF "branch refs/heads/$name"; then refuse "$t" "checked out in a worktree"; return; fi
  # Forced delete is a compare-and-delete on the recorded tip, so a move after the check cannot be lost.
  if [ "$force" = 1 ]; then act "$t" "git branch $(q "$name") $tip" git update-ref -d "refs/heads/$name" "$tip"
  else act "$t" "git branch $(q "$name") $tip" git branch -d "$name"; fi
}

do_worktree() {
  local p="$a" head="$b" t="worktree $a" res k v cur="" found=0 br="" n x
  x=$(symlink_in "$p") && { refuse "$t" "symlink in path ($x)"; return; }
  [ -d "$p" ] || { skip "$t" "folder is gone"; return; }
  res=$(cd "$p" && pwd -P)
  case "$res" in "$MAIN_WT"/*) ;; *) refuse "$t" "outside this repo"; return ;; esac
  while read -r k v; do
    case "$k" in
      worktree) cur=$(cd "$v" 2>/dev/null && pwd -P); [ "$cur" = "$res" ] && found=1 ;;
      branch) [ "$cur" = "$res" ] && br="${v#refs/heads/}" ;;
    esac
  done < <(git worktree list --porcelain)
  [ "$found" = 1 ] || { refuse "$t" "not a linked worktree of this repo"; return; }
  cur=$(git -C "$res" rev-parse HEAD 2>/dev/null)
  [ "$cur" = "$head" ] || { skip "$t" "HEAD $head is now $cur"; return; }
  n=$(GIT_OPTIONAL_LOCKS=0 git -C "$res" status --porcelain --untracked-files=all | wc -l | tr -d ' ')
  [ "$n" = 0 ] || { refuse "$t" "dirty: $n changed or untracked files"; return; }
  n=$(GIT_OPTIONAL_LOCKS=0 git -C "$res" status --porcelain --ignored=matching --untracked-files=all | sed -n 's/^!! //p' | sed 's#/$##' | grep -Ecv "$REGEN")
  [ "$n" = 0 ] || { refuse "$t" "$n ignored files that do not regenerate"; return; }
  if has_secret "$res"; then refuse "$t" "contains an env, key or credential file"; return; fi
  if [ "$OS" = Darwin ] && ! command -v lsof >/dev/null 2>&1; then refuse "$t" "cannot check process cwds: lsof missing"; return; fi
  if cwds | under "$res"; then refuse "$t" "a process has its cwd inside"; return; fi
  act "$t" "git worktree add $(q "$res") $(q "${br:-$head}")" git worktree remove "$res"
}

do_path() {
  local p="$a" kind="$b" size="$c" mt="$d" t="path $a" base res n x
  case "$p" in /*) ;; *) refuse "$t" "not an absolute path"; return ;; esac
  x=$(symlink_in "$p") && { refuse "$t" "symlink in path ($x)"; return; }
  [ -e "$p" ] || { skip "$t" "path is gone"; return; }
  base=$(basename "$p")
  case "$base" in .env*|*.pem|*.key|id_rsa*|id_ed25519*|id_ecdsa*|*.p12|*.pfx|*credential*|*secret*)
    refuse "$t" "env, key or credential file"; return ;; esac
  res="$(cd "$(dirname "$p")" && pwd -P)/$base"
  in_roots "$res" || { refuse "$t" "outside this repo, the session scratchpad and your TMPDIR"; return; }
  case "$res/" in */.git/*) refuse "$t" "inside .git"; return ;; esac
  [ "$(fuid "$res")" = "$mine" ] || { refuse "$t" "not owned by you"; return; }
  case "$kind" in
    file) [ -f "$res" ] || { skip "$t" "no longer a file"; return; }
      [ -z "$(git -C "$(dirname "$res")" ls-files -- "$base" 2>/dev/null)" ] || { refuse "$t" "tracked by git"; return; }
      [ "$size" = - ] || [ "$(fsize "$res")" = "$size" ] || { skip "$t" "size $size is now $(fsize "$res")"; return; } ;;
    dir) [ -d "$res" ] || { skip "$t" "no longer a directory"; return; }
      if has_secret "$res"; then refuse "$t" "contains an env, key or credential file"; return; fi
      [ -z "$(find "$res" -name .git -print 2>/dev/null | head -1)" ] || { refuse "$t" "contains a git checkout"; return; }
      [ -z "$(git -C "$res" ls-files 2>/dev/null | head -1)" ] || { refuse "$t" "contains tracked files"; return; }
      [ "$size" = - ] || [ "$(dsize "$res")" = "$size" ] || { skip "$t" "size $size is now $(dsize "$res")"; return; } ;;
    *) refuse "$t" "kind must be file or dir"; return ;;
  esac
  [ "$mt" = - ] || [ "$(mtime "$res")" = "$mt" ] || { skip "$t" "mtime $mt is now $(mtime "$res")"; return; }
  if [ "$kind" = dir ]; then # mtime does not change when a process opens an existing file, so ask lsof
    command -v lsof >/dev/null 2>&1 || { refuse "$t" "cannot check open files: lsof missing"; return; }
    n=$(lsof +D "$res" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    [ "$n" = 0 ] || { refuse "$t" "$n open files inside"; return; }
    act "$t" none rm -rf -- "$res"
  else act "$t" none rm -f -- "$res"; fi
}

do_process() {
  local pid="$a" cmd="$b" start="$c" t="process $a" now
  case "$pid" in ''|*[!0-9]*) refuse "$t" "invalid pid"; return ;; esac
  if [ "$pid" -le 1 ] || [ "$pid" = $$ ] || [ "$pid" = "$PPID" ] || [ "$pid" = "${CLAUDE_PID:-x}" ]; then
    refuse "$t" "protected process"; return; fi
  now=$(ps -o command= -p "$pid" 2>/dev/null)
  [ -n "$now" ] || { skip "$t" "process is gone"; return; }
  [ "$(ps -o uid= -p "$pid" | tr -d ' ')" = "$mine" ] || { refuse "$t" "not your process"; return; }
  # audit.sh prints the first 140 characters of the command
  [ "$(printf '%s' "$now" | cut -c1-140)" = "$(printf '%s' "$cmd" | cut -c1-140)" ] || { skip "$t" "command is now: $now"; return; }
  now=$(pstart "$pid")
  [ "$now" = "$start" ] || { skip "$t" "start $start is now $now (PID reused)"; return; }
  act "$t" none kill -TERM "$pid"
}

do_stash() {
  local sha="$a" msg="$b" t="stash $a" row ref
  row=$(git stash list --format='%gd%x09%H%x09%s' | awk -F'\t' -v s="$sha" '$2==s {print $1 "\t" $3; exit}')
  [ -n "$row" ] || { skip "$t" "no stash with this sha"; return; }
  ref="${row%%$'\t'*}"
  [ "${row#*$'\t'}" = "$msg" ] || { skip "$t" "message is now: ${row#*$'\t'}"; return; }
  act "$t" "git stash store -m $(q "$msg") $sha" git stash drop -q "$ref"
}

# One tab-separated line per item: type, four fields ("-" when empty, since read collapses tabs), item JSON.
ITEMS=$(python3 - "$PLAN" <<'PY'
import json, sys
FIELDS = {'branch': ('name', 'tip'), 'worktree': ('path', 'head'), 'path': ('path', 'kind'),
          'process': ('pid', 'cmd', 'start'), 'stash': ('sha', 'message')}
try:
    plan = json.load(open(sys.argv[1]))
except (OSError, ValueError) as e:
    sys.exit('error: cannot read plan: %s' % e)
if not isinstance(plan, list):
    sys.exit('error: plan must be a JSON array')
for i, it in enumerate(plan):
    raw = json.dumps(it, separators=(',', ':'))
    kind = it.get('type') if isinstance(it, dict) else None
    if kind not in FIELDS:
        print('invalid\titem %d\tunknown type\t-\t-\t%s' % (i, raw)); continue
    vals = [it.get(f) for f in FIELDS[kind]]
    if kind == 'branch':
        vals.append('1' if it.get('force') is True else '0')
    if kind == 'path':
        vals += [it.get('size_bytes', '-'), it.get('mtime', '-')]
        if vals[2] == '-' and vals[3] == '-':
            vals[2] = None
    vals = [str(v) if isinstance(v, (str, int)) and not isinstance(v, bool) else None for v in vals]
    if any(v is None or v == '' or '\t' in v or '\n' in v for v in vals):
        print('invalid\titem %d\tmissing or malformed fields for %s\t-\t-\t%s' % (i, kind, raw)); continue
    print('\t'.join([kind] + (vals + ['-'] * 4)[:4] + [raw]))
PY
) || exit 2

while IFS=$'\t' read -r type a b c d item; do
  [ -n "$type" ] || continue
  case "$type" in
    branch) do_branch ;;
    worktree) do_worktree ;;
    path) do_path ;;
    process) do_process ;;
    stash) do_stash ;;
    invalid) echo "skipped: $a: invalid plan item ($b)"; FAIL=1 ;;
  esac
done <<EOF
$ITEMS
EOF
[ "$DRY" = 1 ] && echo "dry-run: nothing changed"
exit "$FAIL"
