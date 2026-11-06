#!/usr/bin/env bash
# smoke.sh <skill-dir>: builds the mixed-leftovers fixture in a temp dir, starts a fake
# "session" process, runs audit.sh against it, then stops the process it started (by PID).
set -u
SK="$1"; D=$(mktemp -d "${TMPDIR:-/tmp}/sc-smoke.XXXXXX"); cd "$D"
bash "$SK/evals/plain-git-mixed-leftovers/place-files.sh"
export CLAUDE_CODE_SESSION_ID=smoke-$$ ; export CLAUDE_PID=$$
(cd "$D/app" && exec sleep 300) & SP=$!
mkdir -p "$D/app/coverage" && echo 1 > "$D/app/coverage/i"
sleep 3
bash "$SK/scripts/audit.sh" --repo "$D/app" --since 2000-01-01T00:00:00Z; rc=$?
kill "$SP" 2>/dev/null
echo "smoke_rc=$rc fixture=$D"
