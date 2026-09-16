#!/usr/bin/env bash
# TB3 mesh auto-heal (cron, every minute). Silent when healthy. Every action is
# logged to syslog (tag tb-mesh-heal) and appended as '<epoch> <segment>' to
# /var/lib/tb-mesh-heal/events.log, which tb-mesh-status-json.py turns into the
# Zabbix item custom.tbmesh.status (template "Homelab TB3 mesh"). No network
# posting of any kind. Two regimes: single-link (per-interface ladder: missing
# netdev / no adjacency -> PCI reset, gone-from-bus -> rescan/reboot ladder,
# stale-tunnel wedge -> coordinated both-ends reset -> linkstuck) and
# whole-mesh-down (cluster-serialised recovery through a lock in /etc/pve,
# opt-in evacuate-and-reboot via AUTO_MESH_REBOOT=1 in /etc/default/tb-mesh-heal).
# Source of truth: zabbix/tb-mesh-heal.sh in debian13-homelab-bootstrap.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin   # cron's PATH lacks /usr/sbin (qm, pct)
STATE=/var/lib/tb-mesh-heal; mkdir -p "$STATE"
# The Zabbix collector reads the state dir as the zabbix user: keep it world-readable
# even on hosts whose login.defs UMASK is 027 (existing files get fixed too).
umask 022
chmod 0755 "$STATE" 2>/dev/null || true; chmod 0644 "$STATE"/* 2>/dev/null || true
# Non-reentrant: a run that does resets (sleeps) can outlast the 1-min cron
# interval; without this, two runs would act concurrently.
if exec 9>/run/tb-mesh-heal.run.lock 2>/dev/null; then
  flock -n 9 2>/dev/null || { logger -t tb-mesh-heal "previous run still active; skipping"; exit 0; }
fi   # if the lock file can't be opened, run anyway (fail open, not disabled)
# Heartbeat for the "heal not running" trigger. Written after the lock on purpose: a
# run wedged for over 10 min (ssh hang, stuck reset) must show up as not running.
date +%s > "$STATE/last_run"
FAIL_THRESHOLD=3   # consecutive minutes without adjacency before a single-link reset
COOLDOWN=600       # seconds between resets per interface
MISS_THRESHOLD=6   # single-ended resets of a MISSING netdev (TB domain still on the bus) before escalating to a coordinated both-ends reset — a stale-tunnel wedge cannot be cleared from one end

# --- whole-mesh recovery tunables ---
MESH_GRACE=300        # seconds of sustained whole-mesh-down before we act (skip boot-race)
MESH_CONVERGE=180     # seconds to hold after a coordinated reset before the next round
MESH_REBOOT_AFTER=1200 # seconds of whole-mesh-down before stage-2 (migrate+reboot) is considered
LOCK=/etc/pve/tb-mesh-recovery.lock   # cluster-wide (pmxcfs) serialisation lock
LOCK_TTL=900          # a held lock older than this is considered stale and stealable
LAN_MIGRATION_CIDR=192.168.5.0/24     # migrate over the MAN VLAN when the mesh is down
# Opt-in: auto-migrate guests off and reboot to self-heal. DEFAULT OFF (page instead).
AUTO_MESH_REBOOT=${AUTO_MESH_REBOOT:-0}
[ -r /etc/default/tb-mesh-heal ] && . /etc/default/tb-mesh-heal

log(){ logger -t tb-mesh-heal "$*"; }
event(){
  # One line per action for the Zabbix collector: "<epoch> <segment>", the same
  # segment text the buzz renderer used to get (tbmesh <if> reason=... / meshwide ...).
  printf '%s %s\n' "$(date +%s)" "$1" >> "$STATE/events.log"
  log "event: $1"
  # keep the log bounded (the collector only needs this boot plus the newest line)
  if [ "$(wc -l < "$STATE/events.log" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 1000 "$STATE/events.log" > "$STATE/events.log.tmp" 2>/dev/null && mv -f "$STATE/events.log.tmp" "$STATE/events.log"
  fi
}

# ---- mesh peer discovery (convention: mesh 10.0.0.<octet> == MAN 192.168.5.<octet>)
my_mesh_ip(){ ip -4 -o addr show lo 2>/dev/null | grep -oE '10\.0\.0\.[0-9]+' | head -1; }
mesh_peers(){
  local me; me="$(my_mesh_ip)"
  # ring0_addr lines in the local corosync config (available even if pmxcfs is degraded)
  grep -oE 'ring0_addr:[[:space:]]*192\.168\.5\.[0-9]+' /etc/corosync/corosync.conf 2>/dev/null \
    | grep -oE '[0-9]+$' | while read -r oct; do
        local ip="10.0.0.${oct}"
        [ "$ip" = "$me" ] || echo "$ip"
      done | sort -u
}
peer_reachable(){ ping -c1 -W1 "$1" >/dev/null 2>&1; }

# ---- cluster serialisation lock in /etc/pve (mkdir is atomic on pmxcfs) ----
lock_acquire(){
  # returns 0 if we now hold it. Steals a stale lock (holder unresponsive / TTL).
  local now holder ts
  now=$(date +%s)
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s %s\n' "$(hostname)" "$now" > "$LOCK/holder" 2>/dev/null || true
    return 0
  fi
  # already held — is it ours, or stale?
  read -r holder ts < "$LOCK/holder" 2>/dev/null || { holder=""; ts=0; }
  if [ "$holder" = "$(hostname)" ]; then
    printf '%s %s\n' "$(hostname)" "$now" > "$LOCK/holder" 2>/dev/null || true
    return 0
  fi
  if [ $((now - ${ts:-0})) -gt "$LOCK_TTL" ]; then
    log "mesh recovery lock held by ${holder:-?} is stale (${ts}); stealing"
    rm -rf "$LOCK" 2>/dev/null || true
    if mkdir "$LOCK" 2>/dev/null; then
      printf '%s %s\n' "$(hostname)" "$now" > "$LOCK/holder" 2>/dev/null || true
      return 0
    fi
  fi
  return 1
}
lock_holder(){ read -r h _ < "$LOCK/holder" 2>/dev/null && echo "$h"; }
lock_release(){ [ -d "$LOCK" ] && { read -r h _ < "$LOCK/holder" 2>/dev/null; [ "$h" = "$(hostname)" ] && rm -rf "$LOCK" 2>/dev/null; }; return 0; }

# ---- running guests (VMID list) ----
running_vmids(){
  { qm list 2>/dev/null; pct list 2>/dev/null; } \
    | awk 'NR>1 && ($2=="running" || $3=="running"){print $1}' | grep -E '^[0-9]+$' || true
}
running_count(){ running_vmids | wc -l | tr -d ' '; }

reset_both_controllers(){
  log "coordinated reset: resetting BOTH TB controllers"
  /usr/local/bin/pve-en02-disconnect-bug-fix.sh >/dev/null 2>&1 || true
  /usr/local/bin/pve-en03-disconnect-bug-fix.sh >/dev/null 2>&1 || true
  sleep 5
  ip link set en02 up 2>/dev/null || true
  ip link set en03 up 2>/dev/null || true
}

reset_iface(){
  local IF=$1 REASON=$2 QUIET=${3:-} now last
  now=$(date +%s)
  last=$(cat "$STATE/$IF.lastreset" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    log "$IF: reset wanted but in cooldown ($((now-last))s since last)"
    return 1
  fi
  echo "$now" > "$STATE/$IF.lastreset"
  echo 0 > "$STATE/$IF.fails"
  echo $(( $(cat "$STATE/$IF.resets" 2>/dev/null || echo 0) + 1 )) > "$STATE/$IF.resets"   # monotonic, for the Zabbix reset-rate trigger
  log "$IF: resetting thunderbolt controller ($REASON)"
  "/usr/local/bin/pve-${IF}-disconnect-bug-fix.sh" >/dev/null 2>&1 || true
  sleep 5
  ip link set "$IF" up 2>/dev/null || true
  # QUIET=quiet suppresses the event (used for the repeated single-ended resets
  # of a missing-netdev episode, which reports only at state transitions).
  [ "$QUIET" = quiet ] || event "tbmesh $IF reason=$REASON"
  return 0
}

# coordinated_edge_reset <IF> — clear a stale TB-tunnel wedge that a single-ended
# reset cannot: reset BOTH controllers on THIS node AND on the peer at the far end
# of IF, serialised by the cluster lock, then poll for IF's netdev to return. The
# far-end peer name is learned into $STATE/$IF.peer while the adjacency is up; if
# unknown, every cluster peer is reset (heavier but robust). Inter-node ssh is
# root-to-root over the MAN VLAN (pmxcfs-managed keys), so resetting TB does not
# cut it. Returns 0 if IF's netdev came back, 1 otherwise (caller then pages).
# Proven need (2026-09-04): the pve3<->pve4 edge only re-formed when BOTH ends
# were reset/cold-cycled together; one end alone leaves the peer's stale half.
coordinated_edge_reset(){
  local IF=$1 peer targets t i rc=1
  if ! timeout 8 pvecm status 2>/dev/null | grep -qi 'Quorate: *Yes'; then
    log "$IF: coordinated reset wanted but cluster not quorate — skipping"
    return 1
  fi
  lock_acquire || { log "$IF: coordinated reset deferred — $(lock_holder) is recovering"; return 1; }
  event "tbmesh $IF reason=coordreset"
  peer=$(cat "$STATE/$IF.peer" 2>/dev/null || true)
  if [ -n "$peer" ]; then
    targets="$peer"
  else
    targets=$(grep -oE 'name:[[:space:]]*[A-Za-z0-9._-]+' /etc/corosync/corosync.conf 2>/dev/null | grep -oE '[A-Za-z0-9._-]+$' | sort -u)
  fi
  log "$IF: coordinated both-ends reset (far end: $(echo $targets | tr ' ' ','))"
  for t in $targets; do
    [ "$t" = "$(hostname)" ] && continue
    timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$t" \
      '/usr/local/bin/pve-en02-disconnect-bug-fix.sh >/dev/null 2>&1; sleep 2; /usr/local/bin/pve-en03-disconnect-bug-fix.sh >/dev/null 2>&1; ip link set en02 up 2>/dev/null; ip link set en03 up 2>/dev/null' \
      >/dev/null 2>&1 || log "$IF: peer $t coordinated-reset ssh failed"
  done
  reset_both_controllers
  for ((i=0; i<12; i++)); do
    sleep 5
    ip link show "$IF" >/dev/null 2>&1 && { rc=0; break; }
  done
  lock_release
  return $rc
}

# evacuate_and_reboot <reason> — shed running guests to a quorate LAN-reachable
# peer, then reboot to cold-init Thunderbolt. Shared by the whole-mesh stage-2
# and the single-link "gone from PCI bus, guests present" case. Reboots on
# success (does not return); returns 1 without rebooting on any guard failure so
# the caller can fall back to paging. Serialised via the cluster lock so no two
# nodes reboot at once (double reboot = quorum loss). Gated by the CALLER on
# AUTO_MESH_REBOOT.
evacuate_and_reboot(){
  local reason="$1" target="" tname="" cand oct id fail=0
  if ! timeout 8 pvecm status 2>/dev/null | grep -qi 'Quorate: *Yes'; then
    log "evac+reboot ($reason): cluster NOT quorate — refusing"
    event "meshwide host=$(hostname) event=noquorum"
    return 1
  fi
  # serialise (idempotent if we already hold the lock from the whole-mesh path)
  lock_acquire || { log "evac+reboot ($reason): another node recovering — deferring"; return 1; }
  for oct in $(grep -oE 'ring0_addr:[[:space:]]*192\.168\.5\.[0-9]+' /etc/corosync/corosync.conf 2>/dev/null | grep -oE '[0-9]+$'); do
    cand="192.168.5.${oct}"
    ip -4 -o addr show 2>/dev/null | grep -q " ${cand}/" && continue   # skip self
    ping -c1 -W1 "$cand" >/dev/null 2>&1 && { target="$cand"; break; }
  done
  [ -n "$target" ] && tname=$(grep -B2 "ring0_addr: *$target" /etc/corosync/corosync.conf 2>/dev/null | grep -oE 'name:[[:space:]]*[A-Za-z0-9._-]+' | grep -oE '[A-Za-z0-9._-]+$' | tail -1)
  if [ -z "$tname" ]; then
    log "evac+reboot ($reason): no reachable LAN target peer — paging"
    event "meshwide host=$(hostname) event=notarget"
    lock_release; return 1
  fi
  # Choose the migration network: PREFER the mesh when the target is reachable
  # over it (fast 20G path, and it works in the single-link case where the mesh
  # is only degraded/routed), else use the MAN LAN. The mesh loopbacks are /32
  # in 10.0.0.0/24, so that CIDR selects the mesh; 192.168.5.0/24 selects MAN.
  local toct mesh_ok=0 pref_net pref_name
  toct="${target##*.}"
  timeout 3 ping -c1 -W1 "10.0.0.${toct}" >/dev/null 2>&1 && mesh_ok=1
  if [ "$mesh_ok" = 1 ]; then pref_net="10.0.0.0/24"; pref_name="mesh"; else pref_net="$LAN_MIGRATION_CIDR"; pref_name="LAN"; fi
  log "evac+reboot ($reason): migrating guests to ${tname} over ${pref_name} (fallback LAN), then rebooting"
  event "meshwide host=$(hostname) event=evacuate target=${tname}"
  mapfile -t VMIDS < <(running_vmids)
  # migrate_one <vmid> <net-cidr> — try one guest over one network; 0 on success
  migrate_one(){
    local id="$1" net="$2"
    if pct status "$id" >/dev/null 2>&1; then
      timeout 300 pct migrate "$id" "$tname" --restart --migration_network "$net" >/dev/null 2>&1
    else
      timeout 600 qm migrate "$id" "$tname" --online --migration_network "$net" >/dev/null 2>&1 \
        || timeout 600 qm migrate "$id" "$tname" --migration_network "$net" >/dev/null 2>&1
    fi
  }
  for id in "${VMIDS[@]}"; do
    if migrate_one "$id" "$pref_net"; then
      :
    elif [ "$pref_name" = "mesh" ] && migrate_one "$id" "$LAN_MIGRATION_CIDR"; then
      log "evac+reboot ($reason): guest $id fell back to LAN (mesh migration failed)"
    else
      fail=1
    fi
  done
  if [ "$fail" = 1 ] || [ "$(running_count)" != 0 ]; then
    log "evac+reboot ($reason): evacuation incomplete ($(running_count) guests still local) — NOT rebooting"
    event "meshwide host=$(hostname) event=evac_failed left=$(running_count)"
    lock_release; return 1
  fi
  log "evac+reboot ($reason): evacuation complete — rebooting"
  event "meshwide host=$(hostname) event=rebooting"
  trap - EXIT   # keep the lock across reboot; stale TTL covers a node that never returns
  sleep 2
  systemctl reboot
  exit 0
}

# =============================================================================
#  WHOLE-MESH-DOWN detection and coordinated recovery (runs before per-link)
# =============================================================================
mapfile -t PEERS < <(mesh_peers)
any_peer_up=0
for p in "${PEERS[@]}"; do peer_reachable "$p" && { any_peer_up=1; break; }; done

now=$(date +%s)
if [ "${#PEERS[@]}" -gt 0 ] && [ "$any_peer_up" = 0 ]; then
  # No mesh peer reachable at all. Record since-when; act only once sustained.
  since=$(cat "$STATE/mesh_down_since" 2>/dev/null || echo 0)
  [ "$since" = 0 ] && { since=$now; echo "$since" > "$STATE/mesh_down_since"; }
  downfor=$((now - since))

  if [ "$downfor" -lt "$MESH_GRACE" ]; then
    log "whole mesh unreachable for ${downfor}s (< grace ${MESH_GRACE}s) — waiting, not resetting"
    exit 0
  fi

  # Sustained whole-mesh-down. Prefer cluster-serialised recovery via the
  # /etc/pve lock, but that only works when quorate (pmxcfs is read-only
  # otherwise). If not quorate, fall back to LOCAL cooldown-spaced resets so a
  # lone/partitioned node still recovers itself without storming.
  quorate=0
  timeout 8 pvecm status 2>/dev/null | grep -qi 'Quorate: *Yes' && quorate=1
  if [ "$quorate" = 1 ]; then
    if ! lock_acquire; then
      log "whole mesh down; recovery in progress by $(lock_holder) — standing by"
      exit 0
    fi
    trap 'lock_release' EXIT
  else
    log "whole mesh down but cluster NOT quorate — local recovery (no cluster lock)"
  fi

  # Have we already done our coordinated reset this episode?
  last_creset=$(cat "$STATE/mesh_creset_at" 2>/dev/null || echo 0)
  if [ "$((now - last_creset))" -ge "$MESH_CONVERGE" ]; then
    # Stage 1: one coordinated both-ends reset, then hold the lock's convergence window.
    if [ "$last_creset" = 0 ]; then
      event "meshwide host=$(hostname) event=detected downfor=${downfor}"
    fi
    echo "$now" > "$STATE/mesh_creset_at"
    log "whole mesh down ${downfor}s — coordinated recovery round (serialised)"
    event "meshwide host=$(hostname) event=creset downfor=${downfor}"
    # Cheap step 0: if FRR's fabricd is wedged (seen 2026-09-03: Status
    # "restarting fabricd"), restart FRR once before touching the hardware.
    if timeout 5 systemctl show -p StatusText frr 2>/dev/null | grep -qi 'restarting'; then
      log "FRR appears wedged (restarting fabricd) — restarting frr"
      timeout 60 systemctl restart frr >/dev/null 2>&1 || true
      sleep 8
      for p in "${PEERS[@]}"; do peer_reachable "$p" && { echo 0 > "$STATE/mesh_down_since"; rm -f "$STATE/mesh_creset_at"; log "peer $p reachable after frr restart"; lock_release; exit 0; }; done
    fi
    reset_both_controllers
    sleep 10
    # Re-check: did any peer come back?
    for p in "${PEERS[@]}"; do peer_reachable "$p" && { echo 0 > "$STATE/mesh_down_since"; rm -f "$STATE/mesh_creset_at"; log "mesh peer $p reachable after coordinated reset"; lock_release; exit 0; }; done
    lock_release   # release so the next node can take its turn next minute
    exit 0
  fi

  # Stage 2 (opt-in): resets haven't fixed it after long enough — migrate + reboot.
  if [ "$downfor" -ge "$MESH_REBOOT_AFTER" ]; then
    if [ "${AUTO_MESH_REBOOT}" != "1" ]; then
      lastp=$(cat "$STATE/mesh_page" 2>/dev/null || echo 0)
      if [ $((now - lastp)) -ge 3600 ]; then
        echo "$now" > "$STATE/mesh_page"
        log "whole mesh down ${downfor}s; coordinated resets ineffective — paging (AUTO_MESH_REBOOT off)"
        event "meshwide host=$(hostname) event=manual downfor=${downfor}"
      fi
      lock_release; exit 0
    fi
    # AUTO_MESH_REBOOT=1: evacuate over LAN, then reboot (we hold the lock).
    evacuate_and_reboot "mesh-down ${downfor}s"   # reboots on success
    lock_release; exit 0   # only reached if evac failed / deferred
  fi

  lock_release
  exit 0
else
  # Mesh has at least one reachable peer (or no peers configured): clear the
  # whole-mesh-down episode state and fall through to per-link healing.
  if [ -f "$STATE/mesh_down_since" ] && [ "$(cat "$STATE/mesh_down_since")" != 0 ]; then
    log "whole-mesh-down episode cleared (a peer is reachable)"
    event "meshwide host=$(hostname) event=up"
  fi
  echo 0 > "$STATE/mesh_down_since"
  rm -f "$STATE/mesh_creset_at" "$STATE/mesh_page"
  lock_release
fi

# =============================================================================
#  SINGLE-LINK healing (original, unchanged) — runs when the mesh is not wholly
#  down, i.e. at least one peer is reachable.
# =============================================================================
frr_up=0
systemctl -q is-active frr && command -v vtysh >/dev/null && frr_up=1
if [ "$frr_up" = 1 ]; then
  NEIGH=$(timeout 8 vtysh -c "show openfabric neighbor" 2>/dev/null || true)
fi

for IF in en02 en03; do
  [ -x "/usr/local/bin/pve-${IF}-disconnect-bug-fix.sh" ] || continue

  if ! ip link show "$IF" >/dev/null 2>&1; then
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
          event "tbmesh $IF reason=rescan att=$att"
          echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
          sleep 5
          if [ -e "/sys/bus/thunderbolt/devices/$dom" ]; then
            log "$IF: $dom back on the bus after attempt $att"
            event "tbmesh $IF reason=back att=$att"
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
          event "tbmesh $IF reason=reboot att=$ratt"
          sleep 2
          systemctl reboot
          exit 0
        fi
        # Guests present. If AUTO_MESH_REBOOT is on, shed them to a peer over
        # the LAN and reboot to self-heal (same primitive as whole-mesh stage-2),
        # counting against the reboot cap. Otherwise page for a manual reboot.
        if [ "$guests" != "unknown" ] && [ "${AUTO_MESH_REBOOT}" = "1" ]; then
          ratt=$((ratt + 1)); echo "$ratt" > "$STATE/$IF.reboot_att"
          log "$IF: $dom gone, $guests guests present - AUTO evacuate+reboot attempt $ratt/3"
          evacuate_and_reboot "$IF nobus"   # reboots on success; returns on failure
          # evac failed / deferred: fall through to the page below
        fi
        lastp=$(cat "$STATE/$IF.nobus" 2>/dev/null || echo 0)
        if [ $((now - lastp)) -ge 86400 ]; then
          echo "$now" > "$STATE/$IF.nobus"
          if [ "$guests" = "unknown" ]; then
            log "$IF: $dom gone, guest check FAILED - refusing auto-reboot, alerting"
          else
            log "$IF: $dom gone, node has $guests running guests - manual reboot needed, alerting"
          fi
          event "tbmesh $IF reason=guests"
        fi
      else
        lastp=$(cat "$STATE/$IF.nobus" 2>/dev/null || echo 0)
        if [ $((now - lastp)) -ge 86400 ]; then
          echo "$now" > "$STATE/$IF.nobus"
          log "$IF: $dom gone after 3 auto-reboots - manual intervention needed, alerting"
          event "tbmesh $IF reason=nobus"
        fi
      fi
      continue
    fi
    rm -f "$STATE/$IF.nobus" "$STATE/$IF.nobus_att" "$STATE/$IF.nobus_try" "$STATE/$IF.reboot_att" "$STATE/$IF.bootid"
    # netdev missing but the TB domain IS on the bus == a stale-tunnel wedge.
    # A single-ended reset fixes the simple boot-race/disconnect bug, but NOT a
    # wedge where the peer holds its half of the tunnel (proven 2026-09-04: only a
    # simultaneous reset/cold-cycle of BOTH ends re-forms the edge). So escalate:
    # MISS_THRESHOLD single-ended resets -> ONE coordinated both-ends reset ->
    # page 'linkstuck' hourly. Re-armed on a new boot (a reboot/cold-cycle may fix
    # it). Only the first single-ended reset posts; the rest are quiet.
    now=$(date +%s)
    bootid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo x)
    if [ "$(cat "$STATE/$IF.miss_bootid" 2>/dev/null)" != "$bootid" ]; then
      echo "$bootid" > "$STATE/$IF.miss_bootid"
      rm -f "$STATE/$IF.miss_att" "$STATE/$IF.miss_coord" "$STATE/$IF.linkstuck"
    fi
    miss_att=$(cat "$STATE/$IF.miss_att" 2>/dev/null || echo 0)
    if [ "$miss_att" -lt "$MISS_THRESHOLD" ]; then
      if [ "$miss_att" = 0 ]; then
        log "$IF: netdev missing — single-ended reset 1/$MISS_THRESHOLD"
        reset_iface "$IF" missing && echo 1 > "$STATE/$IF.miss_att"
      else
        log "$IF: netdev still missing — single-ended reset $((miss_att+1))/$MISS_THRESHOLD"
        reset_iface "$IF" missing quiet && echo "$((miss_att+1))" > "$STATE/$IF.miss_att"
      fi
      continue
    fi
    if [ "$(cat "$STATE/$IF.miss_coord" 2>/dev/null || echo 0)" = 0 ]; then
      if coordinated_edge_reset "$IF"; then
        log "$IF: edge recovered after coordinated both-ends reset"
        rm -f "$STATE/$IF.miss_att" "$STATE/$IF.miss_coord" "$STATE/$IF.linkstuck"
        event "tbmesh $IF reason=back"
      else
        echo 1 > "$STATE/$IF.miss_coord"
      fi
      continue
    fi
    # Coordinated reset also failed: the edge is stuck and needs a SIMULTANEOUS
    # cold power cycle of both ends (a human/power action). Page once an hour and
    # take no further action until a reboot (new boot_id) re-arms the ladder.
    lastp=$(cat "$STATE/$IF.linkstuck" 2>/dev/null || echo 0)
    if [ $((now - lastp)) -ge 3600 ]; then
      echo "$now" > "$STATE/$IF.linkstuck"
      log "$IF: edge STUCK after coordinated reset — needs a simultaneous cold cycle of both ends; paging"
      event "tbmesh $IF reason=linkstuck"
    fi
    continue
  fi
  rm -f "$STATE/$IF.nobus" "$STATE/$IF.nobus_att" "$STATE/$IF.nobus_try" "$STATE/$IF.reboot_att" "$STATE/$IF.bootid"
  # netdev is back: if we were mid-escalation on a missing episode, announce the
  # recovery once and clear the ladder state.
  if [ "$(cat "$STATE/$IF.miss_att" 2>/dev/null || echo 0)" != 0 ]; then
    log "$IF: netdev back — clearing missing-episode escalation state"
    event "tbmesh $IF reason=back"
  fi
  rm -f "$STATE/$IF.miss_att" "$STATE/$IF.miss_coord" "$STATE/$IF.linkstuck" "$STATE/$IF.miss_bootid"

  ip link set "$IF" up 2>/dev/null || true

  [ "$frr_up" = 1 ] || continue
  if awk -v I="$IF" '$2==I && $4=="Up"{ok=1} END{exit !ok}' <<<"$NEIGH"; then
    echo 0 > "$STATE/$IF.fails"
    # learn the far-end peer name for this interface while the adjacency is up, so
    # a later coordinated_edge_reset knows which node to reset alongside this one.
    peer=$(awk -v I="$IF" '$2==I && $4=="Up"{print $1; exit}' <<<"$NEIGH")
    [ -n "$peer" ] && echo "$peer" > "$STATE/$IF.peer"
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