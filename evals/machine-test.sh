#!/usr/bin/env bash
# machine-test.sh: deterministic checks for audit.sh --machine, clean.sh scratchpad items and machine-sweep.sh.
# HOME and the /tmp root (SC_TMP_ROOT) are faked inside a temp dir, so the real scratch folders, ledger and
# report are never touched. Linux only: liveness reads /proc, and macOS always reports unknown.
# Why: the sweep deletes unattended; each check below guards a way it could delete a live or unproven session.
set -u
[ "$(uname -s)" = Linux ] || { echo "machine_test: skipped (Linux only)"; exit 0; }
SK=$(cd "$(dirname "$0")/.." && pwd)
D=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/sc-machine.XXXXXX")" && pwd -P)
export HOME="$D/home" SC_TMP_ROOT="$D/tmp"
unset XDG_STATE_HOME CLAUDE_CODE_SESSION_ID CLAUDE_PID
ST="$HOME/.local/state/session-cleanup"; LEDGER="$ST/ledger.jsonl"; REPORT="$ST/last-machine-sweep.txt"
C="$SC_TMP_ROOT/claude-$(id -u)/-proj"; TX="$HOME/.claude/projects/-proj"
mkdir -p "$C" "$TX" "$HOME/dev" "$ST"
FAILS=0
expect() { if [ "$2" = 0 ]; then echo "ok: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
now=$(date +%s); OLD=$((now - 8 * 86400)); RECENT_T=$((now - 2 * 86400))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
# Fixed ids: glob order is the reverse of size order, so the ranking check fails without the sort.
DEAD=ffffffff-0000-4000-8000-000000000001     # 3 MB, dead, 8 days old: the only one the sweep may delete
UNKNOWN=dddddddd-0000-4000-8000-000000000002  # an unreadable orphan environment could hold it
LIVE_ENV=cccccccc-0000-4000-8000-000000000003 # a running process carries its id
LIVE_TX=bbbbbbbb-0000-4000-8000-000000000004  # transcript written just now
RECENT=00000000-0000-4000-8000-000000000005   # 1 MB, dead, but changed 2 days ago
LINKED=eeeeeeee-0000-4000-8000-000000000006   # the scratch path is a symlink
# transcript <id> <first timestamp epoch> <mtime epoch>
transcript() { printf '{"timestamp":"%s"}\n' "$(iso "$2")" > "$TX/$1.jsonl"; touch -d "@$3" "$TX/$1.jsonl"; }
# scratch <id> <kb> <epoch>: a scratch folder whose every entry has mtime <epoch>
scratch() { local id="$1" kb="$2" t="$3"; mkdir -p "$C/$id/scratchpad"; head -c "$((kb * 1024))" /dev/zero > "$C/$id/scratchpad/out.bin"; find "$C/$id" -exec touch -d "@$t" {} +; }
scratch "$DEAD" 3072 "$OLD"; scratch "$UNKNOWN" 8 "$OLD"; scratch "$LIVE_ENV" 8 "$OLD"; scratch "$LIVE_TX" 8 "$OLD"; scratch "$RECENT" 1024 "$RECENT_T"
# A first entry two days in the future keeps real orphan processes on this machine from making these unknown.
FUTURE=$((now + 2 * 86400))
transcript "$DEAD" "$FUTURE" "$OLD"; transcript "$LIVE_ENV" "$FUTURE" "$OLD"; transcript "$RECENT" "$FUTURE" "$OLD"
transcript "$LIVE_TX" "$FUTURE" "$now"
transcript "$UNKNOWN" $((now - 3600)) "$OLD"
mkdir -p "$D/victim/$LINKED/scratchpad"; echo keep > "$D/victim/$LINKED/scratchpad/f"; find "$D/victim" -exec touch -d "@$OLD" {} +
ln -s "$D/victim/$LINKED" "$C/$LINKED"; transcript "$LINKED" "$FUTURE" "$OLD"

env CLAUDE_CODE_SESSION_ID="$LIVE_ENV" sleep 300 & LIVE_PID=$!
# An orphan (reparented to init) whose environment is unreadable: non-dumpable, as codex and ssh-agent are.
ORPHAN=$(python3 -c '
import ctypes, os, time
r, w = os.pipe()
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        ctypes.CDLL(None).prctl(4, 0)  # PR_SET_DUMPABLE 0
        os.write(w, str(os.getpid()).encode()); os.close(w)
        for fd in (0, 1, 2): os.close(fd)
        time.sleep(300); os._exit(0)
    os._exit(0)
os.close(w); print(os.read(r, 20).decode())')
sleep 1

OUT=$(bash "$SK/scripts/audit.sh" --machine 2>&1); AUD=$OUT
printf '%s\n' "$OUT" | grep -E 'reclaimable|scratchpad:' | sed 's/^/  | /'
order=$(printf '%s\n' "$OUT" | grep -oE "/($DEAD|$RECENT|$UNKNOWN) " | tr -d '/ ' | tr '\n' ' ')
[ "$order" = "$DEAD $RECENT $UNKNOWN " ] && has "reclaimable_safe: 3.0M in 1 items"
expect "audit ranks items largest first; only the dead old scratchpad counts as safe" $?

# Another run holds the lock: this run must not touch anything.
flock "$ST/machine-sweep.lock" sleep 5 & LOCK_PID=$!; sleep 0.5
OUT=$(bash "$SK/scripts/machine-sweep.sh" 2>&1)
wait "$LOCK_PID"
[ -d "$C/$DEAD" ] && has "another run is in progress"
expect "a second concurrent sweep does nothing" $?

OUT=$(bash "$SK/scripts/machine-sweep.sh" --dry-run 2>&1)
[ -d "$C/$DEAD" ] && [ ! -e "$LEDGER" ] && [ ! -e "$REPORT" ] && has "auto: would: scratchpad $C/$DEAD"
expect "--dry-run changes nothing and writes no ledger or report" $?

OUT=$(bash "$SK/scripts/machine-sweep.sh" 2>&1); rc=$?
printf '%s\n' "$OUT" | sed 's/^/  | /'
[ "$rc" = 0 ] && [ ! -e "$C/$DEAD" ] && grep -qF "\"target\": \"scratchpad $C/$DEAD\"" "$LEDGER" &&
  grep -qF '"restore": "none"' "$LEDGER" && grep -qF "auto: done: scratchpad $C/$DEAD" "$REPORT" && head -1 "$REPORT" | grep -q '^# session-cleanup machine sweep 20'
expect "dead scratchpad older than 7 days is deleted, ledgered and reported" $?
[ -d "$C/$LIVE_ENV" ] && [ -d "$C/$LIVE_TX" ] && printf '%s\n' "$AUD" | grep -q "in_use scratchpad: $C/$LIVE_ENV .*session_live=yes" &&
  printf '%s\n' "$AUD" | grep -q "in_use scratchpad: $C/$LIVE_TX .*session_live=yes"
expect "scratchpads of live sessions (process env, fresh transcript) are kept" $?
[ -d "$C/$UNKNOWN" ] && grep -q "^ask: scratchpad: $C/$UNKNOWN .*session_live=unknown" "$REPORT"
expect "scratchpad whose liveness is unknown is kept and asked about" $?
[ -d "$C/$RECENT" ] && grep -q "^ask: scratchpad: $C/$RECENT .*session_live=no" "$REPORT"
expect "dead scratchpad changed within 7 days is kept" $?
[ "$(grep -c . "$LEDGER")" = 1 ]
expect "ledger has exactly the one deletion" $?

# Direct plans: the audit never lists these, so clean.sh's own guards must refuse them.
nm() { find "$1" -exec stat -c %Y {} + | sort -n | tail -1; }
mkdir -p "$D/elsewhere/$DEAD"; echo keep > "$D/elsewhere/$DEAD/f"; find "$D/elsewhere" -exec touch -d "@$OLD" {} +
ln -s "$D/elsewhere" "$SC_TMP_ROOT/claude-$(id -u)/-linkproj"
cat > "$D/plan.json" <<EOF
[{"type": "scratchpad", "path": "$C/$LINKED", "session_id": "$LINKED", "mtime": $(nm "$C/$LINKED")},
 {"type": "scratchpad", "path": "$SC_TMP_ROOT/claude-$(id -u)/-linkproj/$DEAD", "session_id": "$DEAD", "mtime": $OLD},
 {"type": "scratchpad", "path": "$C/$RECENT", "session_id": "$RECENT", "mtime": $RECENT_T},
 {"type": "scratchpad", "path": "$C/$UNKNOWN", "session_id": "$UNKNOWN", "mtime": $OLD}]
EOF
OUT=$(cd "$D" && bash "$SK/scripts/clean.sh" "$D/plan.json" 2>&1)
printf '%s\n' "$OUT" | sed 's/^/  | /'
[ -L "$C/$LINKED" ] && [ -f "$D/victim/$LINKED/scratchpad/f" ] && has "scratchpad $C/$LINKED: refused (symlink in path ($C/$LINKED))"
expect "symlinked scratchpad path is refused" $?
[ -f "$D/elsewhere/$DEAD/f" ] && has "linkproj/$DEAD: refused (symlink in path ($SC_TMP_ROOT/claude-$(id -u)/-linkproj))"
expect "scratchpad under a symlinked project folder is refused" $?
[ -d "$C/$RECENT" ] && has "scratchpad $C/$RECENT: refused (changed within 7 days)" &&
  [ -d "$C/$UNKNOWN" ] && has "scratchpad $C/$UNKNOWN: refused (session_live=unknown)"
expect "clean.sh re-checks age and liveness itself" $?

kill "$LIVE_PID" "$ORPHAN" 2>/dev/null
cd / && rm -rf "$D"
echo "machine_test_failures=$FAILS"
[ "$FAILS" = 0 ]
