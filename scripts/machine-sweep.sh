#!/usr/bin/env bash
# machine-sweep.sh [--dry-run]
#
# Unattended machine sweep (daily timer: install-timer.sh). Deletes only scratch folders of dead Claude Code
# sessions (audit.sh --machine class "safe": session_live=no, newest mtime over 7 days), through clean.sh so every
# guard and the ledger apply. Everything else becomes ask:/report: lines in
# ~/.local/state/session-cleanup/last-machine-sweep.txt for the next session to show.
# --dry-run changes nothing, takes no lock and writes no file; it prints the report instead.
set -uo pipefail

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "usage: machine-sweep.sh [--dry-run]" >&2; exit 2 ;;
esac
SK=$(cd "$(dirname "$0")" && pwd)
ST="${XDG_STATE_HOME:-$HOME/.local/state}/session-cleanup"
if [ "$DRY" = 0 ]; then # a dry run writes nothing, so it takes no lock
  mkdir -p "$ST" || exit 1
  command -v flock >/dev/null 2>&1 || { echo "error: flock missing" >&2; exit 2; }
  exec 9>"$ST/machine-sweep.lock"
  flock -n 9 || { echo "machine-sweep: another run is in progress"; exit 0; }
fi

# Everything is held in memory: a dry run writes nothing (audit.sh keeps one temp file under TMPDIR).
cd / || exit 1   # outside any repo, clean.sh accepts only scratchpad items
AUD=$(bash "$SK/audit.sh" --machine 2>&1); arc=$?
# The plan holds only safe scratchpads, with the fingerprint clean.sh re-checks.
PLAN=$(printf '%s\n' "$AUD" | python3 -c '
import json, re, sys
pat = re.compile(r"^  \S+ safe scratchpad: (.+) session_id=(\S+) newest_mtime=(\d+) ")
print(json.dumps([{"type": "scratchpad", "path": m.group(1), "session_id": m.group(2), "mtime": int(m.group(3))}
                  for m in map(pat.match, sys.stdin) if m]))')
if [ "$DRY" = 1 ]; then CL=$(printf '%s\n' "$PLAN" | bash "$SK/clean.sh" - --dry-run 2>&1); crc=$?
else CL=$(printf '%s\n' "$PLAN" | bash "$SK/clean.sh" - 2>&1); crc=$?; fi

REPORT=$(
  echo "# session-cleanup machine sweep $(date -u +%Y-%m-%dT%H:%M:%SZ)$([ "$DRY" = 1 ] && echo ' (dry-run)') audit_rc=$arc clean_rc=$crc"
  printf '%s\n' "$AUD" | grep -E '^reclaimable_' | sed 's/^/report: /'
  # clean.sh results: done/restore/would are automatic; a refused or changed scratchpad is the owner's call.
  printf '%s\n' "$CL" | awk '/^(done|would|restore): /{print "auto: " $0} /^(skipped|failed): /{print "ask: " $0}'
  printf '%s\n' "$AUD" | awk '/^items /{s="i"} /^dev_servers_orphaned/{s="d"} /^repos:/{s="r"} /^$/{s=""}
    s=="i" && ($2=="ask" || $2=="report") {c=$2; sub(/^  [^ ]+ [a-z]+ /, ""); print c ": " $0}
    s=="d" && /^  pid=/ {sub(/^  /, ""); print "report: orphaned dev server: " $0}
    s=="r" && /lanes: run/ {sub(/^  /, ""); print "report: " $0}'
  [ "$arc" = 0 ] || echo "ask: audit.sh --machine exited $arc: $(printf '%s\n' "$AUD" | tail -1)"
)

printf '%s\n' "$REPORT"
[ "$DRY" = 1 ] && exit "$crc"
printf '%s\n' "$REPORT" > "$ST/.last-machine-sweep.tmp" && mv -f "$ST/.last-machine-sweep.tmp" "$ST/last-machine-sweep.txt"
exit "$crc"
