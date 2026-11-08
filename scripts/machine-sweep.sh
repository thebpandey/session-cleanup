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

W=$(mktemp -d "${TMPDIR:-/tmp}/sc-sweep.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
cd "$W" || exit 1   # clean.sh runs outside any repo: only scratchpad items are allowed there

bash "$SK/audit.sh" --machine > audit.txt 2>&1; arc=$?
# The plan holds only safe scratchpads, with the fingerprint clean.sh re-checks.
python3 - audit.txt > plan.json <<'PY'
import json, re, sys
pat = re.compile(r'^  \S+ safe scratchpad: (.+) session_id=(\S+) newest_mtime=(\d+) ')
plan = [{'type': 'scratchpad', 'path': m.group(1), 'session_id': m.group(2), 'mtime': int(m.group(3))}
        for m in map(pat.match, open(sys.argv[1])) if m]
json.dump(plan, sys.stdout)
PY
if [ "$DRY" = 1 ]; then bash "$SK/clean.sh" plan.json --dry-run > clean.txt 2>&1; crc=$?
else bash "$SK/clean.sh" plan.json > clean.txt 2>&1; crc=$?; fi

{
  echo "# session-cleanup machine sweep $(date -u +%Y-%m-%dT%H:%M:%SZ)$([ "$DRY" = 1 ] && echo ' (dry-run)') audit_rc=$arc clean_rc=$crc"
  grep -E '^reclaimable_' audit.txt | sed 's/^/report: /'
  # clean.sh results: done/restore/would are automatic; a refused or changed scratchpad is the owner's call.
  awk '/^(done|would|restore): /{print "auto: " $0} /^(skipped|failed): /{print "ask: " $0}' clean.txt
  awk '/^items /{s="i"} /^dev_servers_orphaned/{s="d"} /^repos:/{s="r"} /^$/{s=""}
    s=="i" && ($2=="ask" || $2=="report") {c=$2; sub(/^  [^ ]+ [a-z]+ /, ""); print c ": " $0}
    s=="d" && /^  pid=/ {sub(/^  /, ""); print "report: orphaned dev server: " $0}
    s=="r" && /lanes: run/ {sub(/^  /, ""); print "report: " $0}' audit.txt
  [ "$arc" = 0 ] || echo "ask: audit.sh --machine exited $arc: $(tail -1 audit.txt)"
} > report.txt

if [ "$DRY" = 1 ]; then cat report.txt; exit "$crc"; fi
cp report.txt "$ST/.last-machine-sweep.tmp" && mv -f "$ST/.last-machine-sweep.tmp" "$ST/last-machine-sweep.txt"
cat report.txt
exit "$crc"
