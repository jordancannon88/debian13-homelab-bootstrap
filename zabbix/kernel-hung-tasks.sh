#!/bin/bash
# Zabbix item: how many "task X blocked for more than N seconds" kernel lines this
# boot. A hung task means something (usually a disk, sometimes NFS) stopped answering
# for minutes; on pve1 on 2026-09-17 a stalled SSD blocked ZFS's txg_sync and froze
# the firewall VM with it. Reads the kernel journal for the current boot; the zabbix
# user needs the systemd-journal group. Backs UserParameter custom.kernel.hung_tasks
# (template "Homelab kernel"). The counter resets to 0 on reboot.
n=$(journalctl -k -b -q -o cat 2>/dev/null | grep -c "blocked for more than")
echo "${n:-0}"
exit 0
