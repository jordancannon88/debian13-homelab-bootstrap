#!/usr/bin/env bash
# Proxmox replication-failure watch -> buzz relay over forced-command ssh
# (v3 "repl" segments). Posts on transition to failing, re-posts at most every
# 24h while failing, posts once on recovery. Silent otherwise. Nodes without
# replication jobs never post. PVE hosts only (needs pvesr).
# Installed by monitoring.sh (debian13-homelab-bootstrap); tokens substituted
# at install time: @@BUZZ_TARGET@@ (user@host), @@BUZZ_PORT@@.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
STATE_DIR=/var/lib/repl-health; mkdir -p "$STATE_DIR"
SEGS=""
add(){ SEGS="${SEGS:+$SEGS ; }$1"; }
now=$(date +%s)
while read -r job _enabled target _last _next _dur fails _state; do
  [[ "$job" =~ ^[0-9]+-[0-9]+$ ]] || continue
  [[ "$fails" =~ ^[0-9]+$ ]] || continue
  target="${target//[^A-Za-z0-9_.\/-]/_}"
  sf="$STATE_DIR/${job}.fails"; af="$STATE_DIR/${job}.alerted"
  prev=$(cat "$sf" 2>/dev/null || echo 0)
  echo "$fails" > "$sf"
  if (( fails > 0 )); then
    if (( prev == 0 )) || [ ! -f "$af" ] || (( now - $(stat -c %Y "$af") > 86400 )); then
      add "repl $job target=$target fails=$fails status=FAILING"
      touch "$af"
    fi
  elif (( prev > 0 )); then
    add "repl $job target=$target fails=0 status=RECOVERED"
    rm -f "$af"
  fi
done < <(pvesr status 2>/dev/null | tail -n +2)
[ -n "$SEGS" ] || exit 0
exec ssh -i /root/.ssh/buzz_report -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new -p @@BUZZ_PORT@@ @@BUZZ_TARGET@@ "v3 $SEGS"
