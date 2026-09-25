#!/bin/bash
# lxcfs-loadavg.sh: make containers on this PVE node report their own load
# average instead of the node's. Without it a 1-core LXC shows the host figure
# (seafile-keeper read 6.45 at 3.5 % CPU while pve2 scrubbed, 2026-09-20).
# Same change the bootstrap's harden.sh now makes; this applies it to a node
# that is already built. 2026-09-20, Kan in2f71k36m7z.
#
# WARNING: restarting lxcfs breaks every lxcfs file inside RUNNING containers
# (/proc/loadavg, meminfo, cpuinfo, stat, uptime: "Transport endpoint is not
# connected") until each container is restarted. The first run on 2026-09-20
# forced a reboot of all eight containers. So with containers running this writes
# the drop-in and stops; the flag takes effect at the next node reboot. Set
# FORCE=1 to restart now, and then restart every running container yourself.
set -u
DROPIN=/etc/systemd/system/lxcfs.service.d/override.conf

command -v lxcfs >/dev/null 2>&1 || { echo "no lxcfs on this host, nothing to do"; exit 0; }

FLAG=--enable-loadavg
lxcfs --help 2>&1 | grep -q -- "--enable-loadavg" || FLAG=-l
BIN="$(systemctl show -p ExecStart --value lxcfs.service | sed -n 's/.*path=\([^ ;]*\).*/\1/p')"
BIN="${BIN:-/usr/bin/lxcfs}"

if grep -qsE -- "(--enable-loadavg|[[:space:]]-l[[:space:]])" "$DROPIN"; then
  echo "already in the drop-in"
else
  mkdir -p "$(dirname "$DROPIN")"
  printf '[Service]\nExecStart=\nExecStart=%s %s /var/lib/lxcfs\n' "$BIN" "$FLAG" > "$DROPIN"
  chmod 0644 "$DROPIN"
  systemctl daemon-reload
  running="$(pct list 2>/dev/null | awk 'NR>1 && $2=="running"' | wc -l)"
  if [[ "${running:-0}" != "0" && "${FORCE:-0}" != "1" ]]; then
    echo "drop-in written, lxcfs NOT restarted: $running container(s) running. Takes effect at the next node reboot (or FORCE=1, then restart every container)."
  else
    systemctl restart lxcfs.service || { echo "lxcfs restart FAILED"; exit 1; }
    echo "enabled $FLAG and restarted lxcfs"
  fi
fi
systemctl is-active lxcfs.service
systemctl show -p ExecStart --value lxcfs.service | sed -n 's/.*argv\[\]=\([^;]*\).*/argv: \1/p'
