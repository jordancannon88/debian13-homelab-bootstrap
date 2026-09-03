#!/usr/bin/env bash
# TB3 mesh auto-heal (cron, every minute). Silent when healthy; actions
# logged to syslog tag tb-mesh-heal and alerted to the buzz relay
# (v3 "tbmesh" segments). Reset = the node's existing per-port
# pve-enXX-disconnect-bug-fix.sh (PCI remove + rescan), max 1 per
# interface per 10 min. Thunderbolt-mesh nodes only.
# Escalation when a controller falls off the PCI bus entirely:
# 3 bus rescans 2 min apart, then (zero running guests only) auto-reboot
# up to 3 times, then page for manual intervention.
# Installed by monitoring.sh (debian13-homelab-bootstrap); the send_alert
# sink function is injected at install time (@@SEND_ALERT@@).
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The alert sink (how a payload leaves this host) is injected at install time
# by monitoring.sh — buzz relay (forced-command ssh) or ntfy (HTTP push):
@@SEND_ALERT@@

STATE=/var/lib/tb-mesh-heal; mkdir -p "$STATE"
FAIL_THRESHOLD=3   # consecutive minutes without adjacency before reset
COOLDOWN=600       # seconds between resets per interface

log(){ logger -t tb-mesh-heal "$*"; }
post(){
  send_alert "$1" || log "alert post failed"
}

reset_iface(){
  local IF=$1 REASON=$2 now last
  now=$(date +%s)
  last=$(cat "$STATE/$IF.lastreset" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    log "$IF: reset wanted but in cooldown ($((now-last))s since last)"
    return 1
  fi
  echo "$now" > "$STATE/$IF.lastreset"
  echo 0 > "$STATE/$IF.fails"
  log "$IF: resetting thunderbolt controller ($REASON)"
  "/usr/local/bin/pve-${IF}-disconnect-bug-fix.sh" >/dev/null 2>&1 || true
  sleep 5
  ip link set "$IF" up 2>/dev/null || true
  # alert only on actual heal actions, never on routine checks
  post "tbmesh $IF reason=$REASON"
}

frr_up=0
systemctl -q is-active frr && command -v vtysh >/dev/null && frr_up=1
if [ "$frr_up" = 1 ]; then
  NEIGH=$(vtysh -c "show openfabric neighbor" 2>/dev/null || true)
fi

for IF in en02 en03; do
  [ -x "/usr/local/bin/pve-${IF}-disconnect-bug-fix.sh" ] || continue

  if ! ip link show "$IF" >/dev/null 2>&1; then
    # Controller off the PCI bus entirely (D3cold): escalation ladder.
    # 1) 3 bus rescans, 2 min apart, per boot
    # 2) if the node has ZERO running guests: auto-reboot, up to 3 times
    #    (counter survives reboots; each boot re-runs its rescans first)
    # 3) guests running, guest check failing, or 3 reboots spent: page
    dom="domain0"; [ "$IF" = "en03" ] && dom="domain1"
    if [ ! -e "/sys/bus/thunderbolt/devices/$dom" ]; then
      now=$(date +%s)
      bootid=$(cat /proc/sys/kernel/random/boot_id)
      if [ "$(cat "$STATE/$IF.bootid" 2>/dev/null)" != "$bootid" ]; then
        echo "$bootid" > "$STATE/$IF.bootid"
        rm -f "$STATE/$IF.nobus_att" "$STATE/$IF.nobus_try"
      fi
      att=$(cat "$STATE/$IF.nobus_att" 2>/dev/null || echo 0)
      lastt=$(cat "$STATE/$IF.nobus_try" 2>/dev/null || echo 0)
      if [ "$att" -lt 3 ]; then
        if [ $((now - lastt)) -ge 120 ]; then
          att=$((att + 1))
          echo "$att" > "$STATE/$IF.nobus_att"; echo "$now" > "$STATE/$IF.nobus_try"
          log "$IF: $dom gone from PCI bus - resurrection attempt $att/3 (bus rescan)"
          post "tbmesh $IF reason=rescan att=$att"
          echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
          sleep 5
          if [ -e "/sys/bus/thunderbolt/devices/$dom" ]; then
            log "$IF: $dom back on the bus after attempt $att"
            post "tbmesh $IF reason=back att=$att"
          fi
        fi
        continue
      fi
      ratt=$(cat "$STATE/$IF.reboot_att" 2>/dev/null || echo 0)
      if [ "$ratt" -lt 3 ]; then
        guests=unknown
        if ql=$(qm list 2>/dev/null) && cl=$(pct list 2>/dev/null); then
          guests=$(printf '%s\n%s\n' "$ql" "$cl" | awk '$2=="running" || $3=="running"' | wc -l)
        fi
        if [ "$guests" = "0" ]; then
          ratt=$((ratt + 1)); echo "$ratt" > "$STATE/$IF.reboot_att"
          log "$IF: $dom still gone after rescans - AUTO-REBOOT attempt $ratt/3"
          post "tbmesh $IF reason=reboot att=$ratt"
          sleep 2
          systemctl reboot
          exit 0
        fi
        lastp=$(cat "$STATE/$IF.nobus" 2>/dev/null || echo 0)
        if [ $((now - lastp)) -ge 86400 ]; then
          echo "$now" > "$STATE/$IF.nobus"
          if [ "$guests" = "unknown" ]; then
            log "$IF: $dom gone, guest check FAILED - refusing auto-reboot, alerting"
          else
            log "$IF: $dom gone, node has $guests running guests - manual reboot needed, alerting"
          fi
          post "tbmesh $IF reason=guests"
        fi
      else
        lastp=$(cat "$STATE/$IF.nobus" 2>/dev/null || echo 0)
        if [ $((now - lastp)) -ge 86400 ]; then
          echo "$now" > "$STATE/$IF.nobus"
          log "$IF: $dom gone after 3 auto-reboots - manual intervention needed, alerting"
          post "tbmesh $IF reason=nobus"
        fi
      fi
      continue
    fi
    rm -f "$STATE/$IF.nobus" "$STATE/$IF.nobus_att" "$STATE/$IF.nobus_try" "$STATE/$IF.reboot_att" "$STATE/$IF.bootid"
    log "$IF: netdev missing"
    reset_iface "$IF" missing
    continue
  fi
  rm -f "$STATE/$IF.nobus" "$STATE/$IF.nobus_att" "$STATE/$IF.nobus_try" "$STATE/$IF.reboot_att" "$STATE/$IF.bootid"

  # idempotent; covers the boot-time ifup race
  ip link set "$IF" up 2>/dev/null || true

  [ "$frr_up" = 1 ] || continue
  if awk -v I="$IF" '$2==I && $4=="Up"{ok=1} END{exit !ok}' <<<"$NEIGH"; then
    echo 0 > "$STATE/$IF.fails"
  else
    fails=$(cat "$STATE/$IF.fails" 2>/dev/null || echo 0)
    fails=$((fails + 1))
    echo "$fails" > "$STATE/$IF.fails"
    log "$IF: no openfabric adjacency (strike $fails/$FAIL_THRESHOLD)"
    if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
      reset_iface "$IF" noadj
    fi
  fi
done
