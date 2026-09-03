#!/usr/bin/env bash
# Proxmox HA event watch -> buzz relay (v3 "ha" segments). Tails pve-ha-crm
# through a journal cursor; posts one segment per recover/migrate/relocate
# event. Only the CRM master logs these lines, so exactly one node posts per
# event; install on every cluster node because the master role moves.
# Silent when nothing happened. PVE cluster hosts only.
# Installed by monitoring.sh (debian13-homelab-bootstrap); the send_alert
# sink function is injected at install time (@@SEND_ALERT@@).
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The alert sink (how a payload leaves this host) is injected at install time
# by monitoring.sh — buzz relay (forced-command ssh) or ntfy (HTTP push):
@@SEND_ALERT@@

STATE=/var/lib/ha-event; mkdir -p "$STATE"
CUR="$STATE/cursor"

# first run: set the cursor to 'now' without reporting history
if [ ! -f "$CUR" ]; then
  journalctl -u pve-ha-crm -n 1 -o cat --cursor-file="$CUR" >/dev/null 2>&1 || true
  exit 0
fi

lines=$(journalctl -u pve-ha-crm -o cat --cursor-file="$CUR" 2>/dev/null || true)
[ -n "$lines" ] || exit 0

SEGS=""
n=0
add(){ SEGS="${SEGS:+$SEGS ; }$1"; n=$((n+1)); }
flush(){
  [ -n "$SEGS" ] || return 0
  send_alert "$SEGS" || logger -t ha-event "alert post failed"
  SEGS=""; n=0
}

while IFS= read -r l; do
  case "$l" in
    *"recover service "*)
      m=$(sed -n "s/.*recover service '\([a-z]\+:[0-9]\+\)' from fenced node '\([a-zA-Z0-9-]\+\)' to node '\([a-zA-Z0-9-]\+\)'.*/\1 \2 \3/p" <<<"$l")
      set -- $m
      [ $# -eq 3 ] && add "ha $1 action=recover from=$2 to=$3"
      ;;
    *"migrate service "*)
      m=$(sed -n "s/.*migrate service '\([a-z]\+:[0-9]\+\)' to node '\([a-zA-Z0-9-]\+\)'.*/\1 \2/p" <<<"$l")
      set -- $m
      [ $# -eq 2 ] && add "ha $1 action=migrate from=- to=$2"
      ;;
    *"relocate service "*)
      m=$(sed -n "s/.*relocate service '\([a-z]\+:[0-9]\+\)' to node '\([a-zA-Z0-9-]\+\)'.*/\1 \2/p" <<<"$l")
      set -- $m
      [ $# -eq 2 ] && add "ha $1 action=relocate from=- to=$2"
      ;;
  esac
  [ "$n" -ge 10 ] && flush
done <<<"$lines"
flush
