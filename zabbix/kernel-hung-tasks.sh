#!/bin/bash
# Zabbix item: how many distinct tasks the kernel has reported as "blocked for more
# than N seconds" this boot. A hung task means something (usually a disk, sometimes
# NFS) stopped answering for minutes; on pve1 on 2026-09-17 a stalled SSD blocked
# ZFS's txg_sync and froze the firewall VM with it. Reads the kernel journal for the
# current boot; the zabbix user needs the systemd-journal group. Backs UserParameter
# custom.kernel.hung_tasks (template "Homelab kernel"). Resets to 0 on reboot.
#
# Counts TASKS, not report lines. The kernel re-reports a task that stays stuck at
# every check interval (120 s), so counting lines turned one task stuck for six
# minutes into "three tasks" and fired the High meant for a real stall.
#
# Depends on kernel.hung_task_warnings = -1 (set by monitoring.sh). The default is
# 10 reports per boot, after which the kernel stops printing and this count, and
# both triggers, freeze until reboot. If the budget is exhausted anyway, report -1
# so the "cannot see" trigger says so rather than the count reading as quiet.
w="$(cat /proc/sys/kernel/hung_task_warnings 2>/dev/null)"
if [[ "$w" == "0" ]]; then echo -1; exit 0; fi
n=$(journalctl -k -b -q -o cat 2>/dev/null \
  | sed -n 's/.*task \(.*:[0-9][0-9]*\) blocked for more than.*/\1/p' | sort -u | wc -l)
echo "${n:-0}"
exit 0
