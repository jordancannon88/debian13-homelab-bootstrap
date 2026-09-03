#!/usr/bin/env bash
# Proxmox backup-failure watch (v3 "backup" segments). Parses the PVE task
# index for vzdump tasks finished since the last run and posts one segment per
# FAILED backup. Silent when every backup succeeded. First run only primes the
# cursor (never replays history). PVE hosts only.
# Installed by monitoring.sh (debian13-homelab-bootstrap); the send_alert
# sink function is injected at install time (@@SEND_ALERT@@).
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The alert sink (how a payload leaves this host) is injected at install time
# by monitoring.sh — buzz relay (forced-command ssh) and/or ntfy (HTTP push):
@@SEND_ALERT@@

STATE=/var/lib/backup-health; mkdir -p "$STATE"
IDX=/var/log/pve/tasks/index
[ -r "$IDX" ] || exit 0

# Task index lines: "UPID:node:pid:pstart:starttime:type:id:user@realm: <endtime-hex> <status...>"
# (pure shell hex conversion — Debian's default awk is mawk, no strtonum)
newest() {
  local m=0 _u e _s v
  while read -r _u e _s; do
    case "${e:-}" in ''|*[!0-9A-Fa-f]*) continue ;; esac
    v=$(( 16#$e ))
    [ "$v" -gt "$m" ] && m=$v
  done < "$IDX"
  echo "$m"
}

CUR="$STATE/last-endtime"
if [ ! -f "$CUR" ]; then
  # First run: prime the cursor to the newest finished task — never replay
  # historical failures.
  newest > "$CUR" 2>/dev/null || echo 0 > "$CUR"
  exit 0
fi
last=$(cat "$CUR" 2>/dev/null || echo 0)
[ "$last" -ge 0 ] 2>/dev/null || last=0
new_last=$last

SEGS=""
n=0
add(){ SEGS="${SEGS:+$SEGS ; }$1"; n=$((n+1)); }

while read -r upid endhex status; do
  [ -n "${endhex:-}" ] || continue
  case "$upid" in UPID:*:*:*:*:vzdump:*) ;; *) continue ;; esac
  case "$endhex" in *[!0-9A-Fa-f]*|"") continue ;; esac
  end=$(( 16#$endhex ))
  [ "$end" -le "$last" ] && continue
  [ "$end" -gt "$new_last" ] && new_last=$end
  [ "${status:-}" = "OK" ] && continue
  vmid="$(printf '%s' "$upid" | awk -F: '{print $7}')"
  case "$vmid" in ''|*[!0-9]*) vmid="-" ;; esac
  if [ "$n" -lt 10 ]; then
    add "backup id=$vmid status=FAILED"
  fi
done < "$IDX"

echo "$new_last" > "$CUR"
[ -n "$SEGS" ] || exit 0
send_alert "$SEGS"
