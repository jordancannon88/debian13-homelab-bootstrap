#!/bin/bash
# pve-ha-events-json.sh: HA recover / migrate / relocate events from the pve-ha-crm journal
# as one JSON document, for the Zabbix UserParameter custom.pve.ha (template
# "Homelab Proxmox events"). Tails the unit through a cursor file (first run only primes
# it: history is never replayed); counters are monotonic since install so an agent retry
# cannot lose an event. Only the CRM master logs these lines, so one node reports per
# event; install on every cluster node because the master role moves.
# Needs: zabbix user in the systemd-journal group; STATE_DIR writable by zabbix.
# Test marker: /etc/zabbix/homelab-test/ha-event; its lines are parsed as if they were
# new journal lines and the event text is prefixed TEST. Remove it after the test.
STATE_DIR="${PVE_HA_STATE:-/var/lib/zabbix/homelab}"
MARKER="${PVE_HA_MARKER:-/etc/zabbix/homelab-test/ha-event}"
JOURNALCTL="${JOURNALCTL:-journalctl}"
CUR="$STATE_DIR/ha-cursor"; CNT="$STATE_DIR/ha-counts"; LAST="$STATE_DIR/ha-last"
mkdir -p "$STATE_DIR" 2>/dev/null

recover_total=0; move_total=0
[ -r "$CNT" ] && read -r recover_total move_total < "$CNT"
: "${recover_total:=0}" "${move_total:=0}"
last_recover=""; last_move=""
[ -r "$LAST" ] && { last_recover=$(sed -n 1p "$LAST"); last_move=$(sed -n 2p "$LAST"); }
jsonstr() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s:0:200}"; }
emit() {
  printf '{"error":"%s","new_recover":%d,"new_move":%d,"recover_total":%d,"move_total":%d,"last_recover":"%s","last_move":"%s"}\n' \
    "$(jsonstr "$1")" "$2" "$3" "$recover_total" "$move_total" "$(jsonstr "$last_recover")" "$(jsonstr "$last_move")"
}

if [ ! -f "$CUR" ]; then  # prime: newest line only, no report
  if ! $JOURNALCTL -u pve-ha-crm -n 1 -o cat --cursor-file="$CUR" >/dev/null 2>&1; then
    emit "journalctl failed on prime (journal group?)" 0 0; exit 0
  fi
  printf '%s %s\n' "$recover_total" "$move_total" > "$CNT"
  emit "" 0 0; exit 0
fi

lines=$($JOURNALCTL -u pve-ha-crm -o cat --cursor-file="$CUR" 2>/dev/null); rc=$?
if [ $rc -ne 0 ]; then emit "journalctl rc=$rc" 0 0; exit 0; fi
prefix=""
if [ -f "$MARKER" ]; then lines="$lines"$'\n'"$(cat "$MARKER")"; prefix="TEST "; fi

new_recover=0; new_move=0; now=$(date "+%Y-%m-%d %H:%M")
while IFS= read -r l; do
  [ -n "$l" ] || continue
  case "$l" in
    *"recover service "*)
      m=$(sed -n "s/.*recover service '\([a-z]\+:[0-9]\+\)' from fenced node '\([a-zA-Z0-9-]\+\)' to node '\([a-zA-Z0-9-]\+\)'.*/\1 \2 \3/p" <<<"$l"); set -- $m
      [ $# -eq 3 ] && { new_recover=$((new_recover+1)); last_recover="${prefix}$1 from fenced $2 to $3 at $now"; } ;;
    *"migrate service "*)
      m=$(sed -n "s/.*migrate service '\([a-z]\+:[0-9]\+\)' to node '\([a-zA-Z0-9-]\+\)'.*/\1 \2/p" <<<"$l"); set -- $m
      [ $# -eq 2 ] && { new_move=$((new_move+1)); last_move="${prefix}migrate $1 to $2 at $now"; } ;;
    *"relocate service "*)
      m=$(sed -n "s/.*relocate service '\([a-z]\+:[0-9]\+\)' to node '\([a-zA-Z0-9-]\+\)'.*/\1 \2/p" <<<"$l"); set -- $m
      [ $# -eq 2 ] && { new_move=$((new_move+1)); last_move="${prefix}relocate $1 to $2 at $now"; } ;;
  esac
done <<<"$lines"
recover_total=$((recover_total+new_recover)); move_total=$((move_total+new_move))
printf '%s %s\n' "$recover_total" "$move_total" > "$CNT"
printf '%s\n%s\n' "$last_recover" "$last_move" > "$LAST"
emit "" "$new_recover" "$new_move"
