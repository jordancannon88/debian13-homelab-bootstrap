#!/bin/bash
# lxcfs-loadavg.sh: make containers on this PVE node report their own load
# average instead of the node's. Without it a 1-core LXC shows the host figure
# (seafile-keeper read 6.45 at 3.5 % CPU while pve2 scrubbed, 2026-09-20).
# Same change the bootstrap's harden.sh now makes; this applies it to a node
# that is already built. Containers keep running; their /proc views switch when
# lxcfs restarts. 2026-09-20, Kan in2f71k36m7z.
set -u
DROPIN=/etc/systemd/system/lxcfs.service.d/override.conf

command -v lxcfs >/dev/null 2>&1 || { echo "no lxcfs on this host, nothing to do"; exit 0; }

FLAG=--enable-loadavg
lxcfs --help 2>&1 | grep -q -- "--enable-loadavg" || FLAG=-l
BIN="$(systemctl show -p ExecStart --value lxcfs.service | sed -n 's/.*path=\([^ ;]*\).*/\1/p')"
BIN="${BIN:-/usr/bin/lxcfs}"

if grep -qs -- "$FLAG" "$DROPIN"; then
  echo "already enabled ($FLAG)"
else
  mkdir -p "$(dirname "$DROPIN")"
  printf '[Service]\nExecStart=\nExecStart=%s %s /var/lib/lxcfs\n' "$BIN" "$FLAG" > "$DROPIN"
  chmod 0644 "$DROPIN"
  systemctl daemon-reload
  systemctl restart lxcfs.service || { echo "lxcfs restart FAILED"; exit 1; }
  echo "enabled $FLAG and restarted lxcfs"
fi
systemctl is-active lxcfs.service
systemctl show -p ExecStart --value lxcfs.service | sed -n 's/.*argv\[\]=\([^;]*\).*/argv: \1/p'
