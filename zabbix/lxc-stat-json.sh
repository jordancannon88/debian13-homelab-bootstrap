#!/usr/bin/env bash
# lxc-stat-json.sh — the container's OWN uptime and CPU use, for Zabbix.
#
# Inside an LXC container /proc/uptime and /proc/loadavg are the host kernel's
# numbers, so the stock "has been restarted" trigger never fires for a
# container restart and "load average is too high" fires for the host's work
# (pbs0 paged twice on 2026-09-17 while idle). What is honest inside the
# container: the age of its own init process (PID 1 in its PID namespace) and
# the cgroup v2 cpu.stat of its own cgroup, which the cgroup namespace exposes
# at /sys/fs/cgroup.
#
# Output (one JSON object, master item custom.lxc.stat):
#   uptime      seconds since the container's init started
#   ncpu        CPUs the container may use
#   cpu_pct     CPU used over a 1 s sample, percent of ncpu (0..100)
#   cpu_some10  cpu.pressure "some" avg10 (percent of time a task waited for CPU)
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

up="$(ps -o etimes= -p 1 2>/dev/null | tr -d ' ')"; up="${up:-0}"
ncpu="$(nproc 2>/dev/null || echo 1)"

read_usage() { awk '/^usage_usec/{print $2}' /sys/fs/cgroup/cpu.stat 2>/dev/null; }
u1="$(read_usage)"
if [[ -n "$u1" ]]; then
  sleep 1
  u2="$(read_usage)"
  # usec used per 1 s wall, over ncpu cores -> percent. Guard the divisor.
  pct="$(awk -v a="$u1" -v b="$u2" -v n="$ncpu" 'BEGIN{ if(n<1)n=1; p=(b-a)/10000/n; if(p<0)p=0; if(p>100)p=100; printf "%.1f", p }')"
else
  pct="-1"
fi
some10="$(awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /sys/fs/cgroup/cpu.pressure 2>/dev/null)"
some10="${some10:--1}"

printf '{"uptime":%s,"ncpu":%s,"cpu_pct":%s,"cpu_some10":%s}\n' "$up" "$ncpu" "$pct" "$some10"
