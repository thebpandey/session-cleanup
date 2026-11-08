#!/usr/bin/env bash
# machine-test.sh: deterministic checks for audit.sh --machine, clean.sh scratchpad items and machine-sweep.sh.
# HOME and the /tmp root (SC_TMP_ROOT) are faked inside a temp dir, so the real scratch folders, ledger and
# report are never touched. Linux only: it uses GNU date/touch and a /proc environment carrier; the OS is read
# from uname, so there is no seam to run the macOS branch here.
# Why: the sweep deletes unattended; each check below guards a way it could delete a live or unproven session.
set -u
[ "$(uname -s)" = Linux ] || { echo "machine_test: skipped (Linux only)"; exit 0; }
SK=$(cd "$(dirname "$0")/.." && pwd)
D=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/sc-machine.XXXXXX")" && pwd -P)
# The /tmp root is reached through a symlink, as /tmp -> /private/tmp is on macOS; that must stay allowed.
mkdir -p "$D/tmp"; ln -s "$D/tmp" "$D/tmplink"
export HOME="$D/home" SC_TMP_ROOT="$D/tmplink"
unset XDG_STATE_HOME CLAUDE_CODE_SESSION_ID CLAUDE_PID
ST="$HOME/.local/state/session-cleanup"; LEDGER="$ST/ledger.jsonl"; REPORT="$ST/last-machine-sweep.txt"
C="$SC_TMP_ROOT/claude-$(id -u)/-proj"; TX="$HOME/.claude/projects/-proj"
RC="$D/tmp/claude-$(id -u)"   # the real scratch root
mkdir -p "$C" "$TX" "$HOME/dev" "$ST"; chmod 700 "$RC"
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

snap() { (cd "$1" && find . -exec stat -c '%n %s %Y %a' {} + | sort && find . -type f -exec sha256sum {} + | sort); }
echo prior > "$ST/keep.txt"; BEFORE=$(snap "$ST")
OUT=$(bash "$SK/scripts/machine-sweep.sh" --dry-run 2>&1)
[ -d "$C/$DEAD" ] && [ "$(snap "$ST")" = "$BEFORE" ] && has "auto: would: scratchpad $C/$DEAD"
expect "--dry-run deletes nothing and leaves the state dir byte-identical" $?
rm -f "$ST/keep.txt"

# Another run holds the lock: this run must not touch anything.
flock "$ST/machine-sweep.lock" sleep 5 & LOCK_PID=$!; sleep 0.5
OUT=$(bash "$SK/scripts/machine-sweep.sh" 2>&1)
wait "$LOCK_PID"
[ -d "$C/$DEAD" ] && has "another run is in progress"
expect "a second concurrent sweep does nothing" $?

OUT=$(bash "$SK/scripts/machine-sweep.sh" 2>&1); rc=$?
printf '%s\n' "$OUT" | sed 's/^/  | /'
[ "$rc" = 0 ] && [ ! -e "$C/$DEAD" ] && [ ! -e "$RC/-proj/$DEAD" ] && grep -qF "\"target\": \"scratchpad $C/$DEAD\"" "$LEDGER" &&
  grep -qF '"restore": "none"' "$LEDGER" && grep -qF "auto: done: scratchpad $C/$DEAD" "$REPORT" && head -1 "$REPORT" | grep -q '^# session-cleanup machine sweep 20'
expect "transcript and scratch idle 7 days with no carrier: deleted through a symlinked /tmp root, ledgered, reported" $?
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

# Direct plans: the audit never lists these, so clean.sh's own guards must refuse them. Each target is otherwise
# deletable (transcript and scratch idle 8 days, no carrier), so removing its guard deletes it.
nm() { find "$1" -exec stat -c %Y {} + | sort -n | tail -1; }
mkdir -p "$D/elsewhere/$DEAD"; echo keep > "$D/elsewhere/$DEAD/f"; find "$D/elsewhere" -exec touch -d "@$OLD" {} +
ln -s "$D/elsewhere" "$SC_TMP_ROOT/claude-$(id -u)/-linkproj"
MOVED=11111111-0000-4000-8000-000000000008; HELD=22222222-0000-4000-8000-000000000009
for id in "$MOVED" "$HELD"; do scratch "$id" 8 "$OLD"; transcript "$id" "$OLD"; done
bash -c 'exec 3<"$1"; exec sleep 120' _ "$C/$HELD/scratchpad/out.bin" & HOLD_PID=$!; sleep 0.5
cat > "$D/plan.json" <<EOF
[{"type": "scratchpad", "path": "$C/$MOVED", "session_id": "$MOVED", "mtime": $((OLD - 100))},
 {"type": "scratchpad", "path": "$C/$HELD", "session_id": "$HELD", "mtime": $OLD},
 {"type": "scratchpad", "path": "$C/$LINKED", "session_id": "$LINKED", "mtime": $(nm "$C/$LINKED")},
 {"type": "scratchpad", "path": "$SC_TMP_ROOT/claude-$(id -u)/-linkproj/$DEAD", "session_id": "$DEAD", "mtime": $OLD},
 {"type": "scratchpad", "path": "$C/$RECENT", "session_id": "$RECENT", "mtime": $RECENT_T},
 {"type": "scratchpad", "path": "$C/$NOTX", "session_id": "$NOTX", "mtime": $OLD}]
EOF
OUT=$(cd "$D" && bash "$SK/scripts/clean.sh" "$D/plan.json" 2>&1)
printf '%s\n' "$OUT" | sed 's/^/  | /'
[ -L "$C/$LINKED" ] && [ -f "$D/victim/$LINKED/scratchpad/f" ] && has "scratchpad $C/$LINKED: refused (symlink in path ($RC/-proj/$LINKED))"
expect "symlinked scratchpad below the real root is refused" $?
[ -f "$D/elsewhere/$DEAD/f" ] && has "linkproj/$DEAD: refused (symlink in path ($RC/-linkproj))"
expect "scratchpad under a symlinked project folder is refused" $?
[ -d "$C/$MOVED" ] && has "scratchpad $C/$MOVED: changed since audit (newest mtime $((OLD - 100)) is now $OLD)"
expect "scratchpad whose newest mtime differs from the plan is skipped" $?
[ -d "$C/$HELD" ] && has "scratchpad $C/$HELD: refused (1 open files inside)"
expect "scratchpad with a file held open is refused" $?
[ -d "$C/$RECENT" ] && has "scratchpad $C/$RECENT: refused (session_live=unknown)" &&
  [ -d "$C/$NOTX" ] && has "scratchpad $C/$NOTX: refused (session_live=unknown)"
expect "clean.sh re-checks age and liveness itself" $?
kill "$HOLD_PID" 2>/dev/null

# Ownership (SC_TEST_UID makes clean.sh treat this user's files as another user's) and a writable root.
OWN=33333333-0000-4000-8000-00000000000a; MODE=44444444-0000-4000-8000-00000000000b
mkdir -p "$D/tmp/claude-99999/-proj"; chmod 700 "$D/tmp/claude-99999"
for id in "$OWN" "$MODE"; do transcript "$id" "$OLD"; done
scratch "$MODE" 8 "$OLD"
mkdir -p "$D/tmp/claude-99999/-proj/$OWN"; echo x > "$D/tmp/claude-99999/-proj/$OWN/f"; find "$D/tmp/claude-99999/-proj/$OWN" -exec touch -d "@$OLD" {} +
OUT=$(printf '[{"type": "scratchpad", "path": "%s", "session_id": "%s", "mtime": %s}]' "$SC_TMP_ROOT/claude-99999/-proj/$OWN" "$OWN" "$OLD" |
  SC_TEST_UID=99999 bash "$SK/scripts/clean.sh" - 2>&1)
[ -d "$D/tmp/claude-99999/-proj/$OWN" ] && has "refused (not owned by you"
expect "scratchpad not owned by the user is refused" $?
chmod g+w "$RC"
OUT=$(printf '[{"type": "scratchpad", "path": "%s", "session_id": "%s", "mtime": %s}]' "$C/$MODE" "$MODE" "$OLD" | bash "$SK/scripts/clean.sh" - 2>&1)
chmod 700 "$RC"
[ -d "$C/$MODE" ] && has "scratchpad $C/$MODE: refused (scratch root $RC is group or world writable)"
expect "scratchpad under a group-writable root is refused" $?

kill "$LIVE_PID" 2>/dev/null
cd / && rm -rf "$D"
echo "machine_test_failures=$FAILS"
[ "$FAILS" = 0 ]
