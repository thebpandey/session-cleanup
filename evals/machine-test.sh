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
# Fixed ids: glob order is the reverse of size order, so the ranking check fails without the sort.
DEAD=ffffffff-0000-4000-8000-000000000001     # 3 MB; transcript and scratch idle 8 days, no carrier: deletable
NOTX=dddddddd-0000-4000-8000-000000000002     # no transcript: unknown
LIVE_ENV=cccccccc-0000-4000-8000-000000000003 # a readable process carries its id
LIVE_TX=bbbbbbbb-0000-4000-8000-000000000004  # transcript written just now
RECENT=00000000-0000-4000-8000-000000000005   # 1 MB; transcript idle 8 days, but scratch changed 2 days ago
TXMID=aaaaaaaa-0000-4000-8000-000000000007    # transcript idle 3 days: neither live nor proven dead
LINKED=eeeeeeee-0000-4000-8000-000000000006   # the scratch path is a symlink
transcript() { echo '{}' > "$TX/$1.jsonl"; touch -d "@$2" "$TX/$1.jsonl"; } # transcript <id> <mtime>
# scratch <id> <kb> <epoch>: a scratch folder whose every entry has mtime <epoch>
scratch() { local id="$1" kb="$2" t="$3"; mkdir -p "$C/$id/scratchpad"; head -c "$((kb * 1024))" /dev/zero > "$C/$id/scratchpad/out.bin"; find "$C/$id" -exec touch -d "@$t" {} +; }
for id in "$NOTX" "$LIVE_ENV" "$LIVE_TX" "$TXMID"; do scratch "$id" 8 "$OLD"; done
scratch "$DEAD" 3072 "$OLD"; scratch "$RECENT" 1024 "$RECENT_T"
for id in "$DEAD" "$LIVE_ENV" "$RECENT"; do transcript "$id" "$OLD"; done
transcript "$LIVE_TX" "$now"; transcript "$TXMID" $((now - 3 * 86400))
mkdir -p "$D/victim/$LINKED/scratchpad"; echo keep > "$D/victim/$LINKED/scratchpad/f"; find "$D/victim" -exec touch -d "@$OLD" {} +
ln -s "$D/victim/$LINKED" "$C/$LINKED"; transcript "$LINKED" "$OLD"

env CLAUDE_CODE_SESSION_ID="$LIVE_ENV" sleep 300 & LIVE_PID=$!
sleep 1

OUT=$(bash "$SK/scripts/audit.sh" --machine 2>&1); AUD=$OUT
printf '%s\n' "$OUT" | grep -E 'reclaimable|scratchpad:' | sed 's/^/  | /'
order=$(printf '%s\n' "$OUT" | grep -oE "/($DEAD|$RECENT|$NOTX) " | tr -d '/ ' | tr '\n' ' ')
[ "$order" = "$DEAD $RECENT $NOTX " ] && has "reclaimable_safe: 3.0M in 1 items"
expect "audit ranks items largest first; only the dead old scratchpad counts as safe" $?

OUT=$(bash "$SK/scripts/machine-sweep.sh" --dry-run 2>&1)
[ -d "$C/$DEAD" ] && [ ! -e "$LEDGER" ] && [ ! -e "$REPORT" ] && [ ! -e "$ST/machine-sweep.lock" ] && has "auto: would: scratchpad $C/$DEAD"
expect "--dry-run changes nothing and writes no ledger or report" $?

# Another run holds the lock: this run must not touch anything.
flock "$ST/machine-sweep.lock" sleep 5 & LOCK_PID=$!; sleep 0.5
OUT=$(bash "$SK/scripts/machine-sweep.sh" 2>&1)
wait "$LOCK_PID"
[ -d "$C/$DEAD" ] && has "another run is in progress"
expect "a second concurrent sweep does nothing" $?

OUT=$(bash "$SK/scripts/machine-sweep.sh" 2>&1); rc=$?
printf '%s\n' "$OUT" | sed 's/^/  | /'
[ "$rc" = 0 ] && [ ! -e "$C/$DEAD" ] && grep -qF "\"target\": \"scratchpad $C/$DEAD\"" "$LEDGER" &&
  grep -qF '"restore": "none"' "$LEDGER" && grep -qF "auto: done: scratchpad $C/$DEAD" "$REPORT" && head -1 "$REPORT" | grep -q '^# session-cleanup machine sweep 20'
expect "transcript and scratch idle 7 days with no carrier: deleted, ledgered and reported" $?
[ -d "$C/$LIVE_ENV" ] && [ -d "$C/$LIVE_TX" ] && printf '%s\n' "$AUD" | grep -q "in_use scratchpad: $C/$LIVE_ENV .*session_live=yes" &&
  printf '%s\n' "$AUD" | grep -q "in_use scratchpad: $C/$LIVE_TX .*session_live=yes"
expect "readable process carrying the id, or transcript changed in 24h: kept as live" $?
[ -d "$C/$NOTX" ] && grep -q "^ask: scratchpad: $C/$NOTX .*session_live=unknown" "$REPORT"
expect "no transcript: unknown, kept and asked about" $?
[ -d "$C/$TXMID" ] && grep -q "^ask: scratchpad: $C/$TXMID .*session_live=unknown" "$REPORT"
expect "transcript idle under 7 days: unknown and kept" $?
[ -d "$C/$RECENT" ] && grep -q "^ask: scratchpad: $C/$RECENT .*session_live=unknown" "$REPORT"
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
 {"type": "scratchpad", "path": "$C/$NOTX", "session_id": "$NOTX", "mtime": $OLD}]
EOF
OUT=$(cd "$D" && bash "$SK/scripts/clean.sh" "$D/plan.json" 2>&1)
printf '%s\n' "$OUT" | sed 's/^/  | /'
[ -L "$C/$LINKED" ] && [ -f "$D/victim/$LINKED/scratchpad/f" ] && has "scratchpad $C/$LINKED: refused (symlink in path ($C/$LINKED))"
expect "symlinked scratchpad path is refused" $?
[ -f "$D/elsewhere/$DEAD/f" ] && has "linkproj/$DEAD: refused (symlink in path ($SC_TMP_ROOT/claude-$(id -u)/-linkproj))"
expect "scratchpad under a symlinked project folder is refused" $?
[ -d "$C/$RECENT" ] && has "scratchpad $C/$RECENT: refused (session_live=unknown)" &&
  [ -d "$C/$NOTX" ] && has "scratchpad $C/$NOTX: refused (session_live=unknown)"
expect "clean.sh re-checks age and liveness itself" $?

kill "$LIVE_PID" 2>/dev/null
cd / && rm -rf "$D"
echo "machine_test_failures=$FAILS"
[ "$FAILS" = 0 ]
