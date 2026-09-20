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
#   io_some10   io.pressure "some" avg10 of the container's cgroup
#   io_full10   io.pressure "full" avg10 (all tasks stalled on IO)
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# Age of the container's init: now minus the creation time of /proc/1, which
# the kernel stamps with wall-clock time. ps -o etimes mixes lxcfs's
# virtualised uptime with host jiffies and wrapped to 47717 days on a
# Debian 12 container (pbs, 2026-09-18).
st="$(stat -c %Y /proc/1 2>/dev/null)"; now="$(date +%s)"
if [[ -n "$st" && "$st" -gt 0 && "$st" -le "$now" ]]; then up=$(( now - st )); else up=0; fi
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
psi() { awk -v k="$1" '$1==k{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' "$2" 2>/dev/null; }
some10="$(psi some /sys/fs/cgroup/cpu.pressure)"; some10="${some10:--1}"
# io.pressure of the container's own cgroup: /proc/pressure/io inside a
# container is the host's (grf and seafile-keeper paged on pve2's scrub).
io_some10="$(psi some /sys/fs/cgroup/io.pressure)"; io_some10="${io_some10:--1}"
io_full10="$(psi full /sys/fs/cgroup/io.pressure)"; io_full10="${io_full10:--1}"

# Load average of this container alone. /proc/loadavg inside a container is the
# container's own only when lxcfs runs with --enable-loadavg (bootstrap harden.sh
# since 2026-09-20); the Zabbix agent's system.cpu.load item cannot use it, because
# it reads the figure through a system call that lxcfs does not intercept and so
# always reports the host's load. Reading the file here is what makes the number
# honest in Zabbix. Falls back to -1 where the file is the host's.
read -r l1 l5 l15 _ < /proc/loadavg 2>/dev/null || { l1=-1; l5=-1; l15=-1; }
l1="${l1:--1}"; l5="${l5:--1}"; l15="${l15:--1}"

printf '{"uptime":%s,"ncpu":%s,"cpu_pct":%s,"cpu_some10":%s,"io_some10":%s,"io_full10":%s,"load1":%s,"load5":%s,"load15":%s}\n' "$up" "$ncpu" "$pct" "$some10" "$io_some10" "$io_full10" "$l1" "$l5" "$l15"
