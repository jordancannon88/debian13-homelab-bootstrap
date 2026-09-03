#!/usr/bin/env bash
# Daily disk-health collector -> buzz relay dev box over forced-command ssh
# (v3 protocol). Auto-discovers NVMe + SATA disks via smartctl and appends
# zpool segments only for pools with something wrong. The dev-box dispatcher
# decides what is worth posting; steady days are silent.
# Installed by monitoring.sh (debian13-homelab-bootstrap); tokens substituted
# at install time: @@BUZZ_TARGET@@ (user@host), @@BUZZ_PORT@@.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
STATE_DIR=/var/lib/disk-health; mkdir -p "$STATE_DIR"
SEGS=""
add(){ SEGS="${SEGS:+$SEGS ; }$1"; }
while read -r dev; do
  case "$dev" in
  /dev/nvme*)
    out=$(smartctl -iA "$dev" || true)
    model=$(awk -F': *' '/^Model Number:/{print $2;exit}' <<<"$out"); model=${model:-unknown}
    model=${model// /_}; model=${model//[^A-Za-z0-9_.-]/_}
    spare=$(awk -F': *' '/^Available Spare:/{gsub(/%/,"",$2);print $2;exit}' <<<"$out")
    used=$(awk -F': *' '/^Percentage Used:/{gsub(/%/,"",$2);print $2;exit}' <<<"$out")
    media=$(awk -F': *' '/^Media and Data Integrity Errors:/{gsub(/[, ]/,"",$2);print $2;exit}' <<<"$out")
    [ -n "$spare" ] || { echo "skip $dev: no SMART spare" >&2; continue; }
    sf="$STATE_DIR/$(basename "$dev").spare"
    prev=$(cat "$sf" 2>/dev/null || echo none)
    echo "$spare" > "$sf"
    add "nvme $model spare=$spare prev=$prev media=${media:-0} used=${used:-0}"
    ;;
  /dev/sd*)
    inf=$(smartctl -iHA "$dev" || true)
    model=$(awk -F': *' '/^Device Model:|^Product:/{print $2;exit}' <<<"$inf"); model=${model:-unknown}
    model=${model// /_}; model=${model//[^A-Za-z0-9_.-]/_}
    health=PASSED; grep -q 'test result: FAILED' <<<"$inf" && health=FAILED
    re=$(awk '$2=="Reallocated_Sector_Ct"{print $NF;exit}' <<<"$inf")
    pe=$(awk '$2=="Current_Pending_Sector"{print $NF;exit}' <<<"$inf")
    of=$(awk '$2=="Offline_Uncorrectable"{print $NF;exit}' <<<"$inf")
    add "sata $model health=$health realloc=${re:-0} pending=${pe:-0} offline=${of:-0}"
    ;;
  esac
done < <(smartctl --scan | awk '{print $1}' | sort -u)
# zpool segments: sent ONLY when a pool has something wrong (health, error
# counters, scrub-found errors, or permanent errors). Clean pools are silent.
for p in $(zpool list -H -o name 2>/dev/null); do
  health=$(zpool list -H -o health "$p")
  st=$(zpool status -p "$p" 2>/dev/null || true)
  read -r r w c < <(awk -v P="$p" '$1==P && $3 ~ /^[0-9]+$/ {print $3,$4,$5; exit}' <<<"$st") || true
  r=${r:-0}; w=${w:-0}; c=${c:-0}
  serr=$(awk '/scan:/ && /with [0-9]+ errors/ {for(i=1;i<=NF;i++) if($i=="with"){print $(i+1); exit}}' <<<"$st"); serr=${serr:-0}
  perm=0; grep -q '^errors: No known data errors' <<<"$st" || perm=1
  if [ "$health" != "ONLINE" ] || [ "$((r+w+c))" -gt 0 ] || [ "$serr" -gt 0 ] || [ "$perm" -eq 1 ]; then
    add "zpool $p health=$health rwc=$r/$w/$c scruberr=$serr perm=$perm"
  fi
done
[ -n "$SEGS" ] || { echo "no disks found" >&2; exit 1; }
exec ssh -i /root/.ssh/buzz_report -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new -p @@BUZZ_PORT@@ @@BUZZ_TARGET@@ "v3 $SEGS"
