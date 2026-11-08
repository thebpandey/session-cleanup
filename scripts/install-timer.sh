#!/usr/bin/env bash
# install-timer.sh [--remove]
#
# Linux: installs (or removes) the systemd user timer session-cleanup-machine, which runs machine-sweep.sh daily
# at 04:43 (Persistent=true: a missed run happens at next boot), logging to
# ~/.local/state/session-cleanup/machine-sweep.log. macOS and other systems: prints a scheduling hint.
set -euo pipefail
SK=$(cd "$(dirname "$0")" && pwd)
N=session-cleanup-machine
LOG="$HOME/.local/state/session-cleanup/machine-sweep.log"
if [ "$(uname -s)" != Linux ] || ! command -v systemctl >/dev/null 2>&1; then
  echo "no systemd user timers here. Schedule it daily yourself, for example with crontab -e:"
  echo "  43 4 * * * /bin/bash $SK/machine-sweep.sh >> $LOG 2>&1"
  echo "(on macOS a launchd agent with StartCalendarInterval Hour=4 Minute=43 also works)"
  exit 0
fi
D="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
if [ "${1:-}" = --remove ]; then
  systemctl --user disable --now "$N.timer" 2>/dev/null || true
  rm -f "$D/$N.service" "$D/$N.timer"
  systemctl --user daemon-reload
  echo "removed $N.timer"
  exit 0
fi
[ -z "${1:-}" ] || { echo "usage: install-timer.sh [--remove]" >&2; exit 2; }
mkdir -p "$D" "$(dirname "$LOG")"
cat > "$D/$N.service" <<EOF
[Unit]
Description=session-cleanup machine sweep (deletes only dead Claude Code session scratch folders)

[Service]
Type=oneshot
ExecStart=/bin/bash "$SK/machine-sweep.sh"
StandardOutput=append:$LOG
StandardError=append:$LOG
EOF
cat > "$D/$N.timer" <<EOF
[Unit]
Description=Run the session-cleanup machine sweep daily at 04:43

[Timer]
OnCalendar=*-*-* 04:43:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now "$N.timer" >/dev/null
echo "enabled $N.timer (daily 04:43; log: $LOG; report: ~/.local/state/session-cleanup/last-machine-sweep.txt)"
