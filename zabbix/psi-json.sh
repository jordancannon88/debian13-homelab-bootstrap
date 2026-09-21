#!/bin/bash
# psi-json.sh — pressure stall information for this machine, as one JSON document
# for the Zabbix UserParameter custom.psi (template "Homelab pressure").
#
# Utilization says how much of a resource is in use; pressure says how much time
# work spent waiting because it could not get the resource. They disagree in both
# directions, which is the point:
#   - a ZFS node can read 86 % memory used with zero memory pressure, because the
#     ARC hands its memory back on demand (pve1, 2026-09-20)
#   - a Docker host can carry load 1.2 with 98 % idle and zero IO pressure, which
#     is health checks, not waiting (dkr, 2026-09-20)
#   - the pve1 SSD stall of 2026-09-17 was an IO pressure event
#
# "some" is the share of time at least one task was stalled on the resource;
# "full" is the share of time every task was. For memory, "full" is the real
# out-of-memory signal. Each is averaged over 10, 60 and 300 seconds.
#
# Inside a container /proc/pressure is the HOST's, so this reports
# "container": 1 and leaves the values at -1 rather than reporting the node's
# numbers as the container's. Per-container pressure comes from the cgroup files
# instead, which the "Homelab LXC" template already reads.
set -u

container=0
if [[ -r /run/systemd/container ]] || grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
  container=1
fi

# field <file> <some|full> <avg10|avg60|avg300>
field() {
  local f="$1" line="$2" key="$3"
  [[ -r "$f" ]] || { printf '%s' -1; return; }
  awk -v l="$line" -v k="$key" '
    $1 == l { for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == k) { print kv[2]; exit } } }
  ' "$f" 2>/dev/null | head -1 | grep -E '^[0-9]+(\.[0-9]+)?$' || printf '%s' -1
}

emit() {   # emit <resource>
  local r="$1" f="/proc/pressure/$1"
  if (( container )) || [[ ! -r "$f" ]]; then
    printf '"%s":{"some10":-1,"some60":-1,"some300":-1,"full10":-1,"full60":-1,"full300":-1}' "$r"
    return
  fi
  printf '"%s":{"some10":%s,"some60":%s,"some300":%s,"full10":%s,"full60":%s,"full300":%s}' \
    "$r" \
    "$(field "$f" some avg10)"  "$(field "$f" some avg60)"  "$(field "$f" some avg300)" \
    "$(field "$f" full avg10)"  "$(field "$f" full avg60)"  "$(field "$f" full avg300)"
}

# Pressure is a single system-wide figure: /proc/pressure/io carries no per-device
# attribution, unlike a SMART reading which belongs to one drive. So the alert cannot
# name a disk from pressure alone. What it CAN do is say which device was busiest at
# the same moment, from the kernel's per-device busy time (field 10 of /proc/diskstats,
# io_ticks, milliseconds spent with I/O in flight). Sampled over one second and
# expressed as a percentage, that is the standard "utilisation" figure. Whole disks
# only: partitions and device-mapper nodes would double-count their parent.
busiest="none"
busiest_pct=-1
if [[ -r /proc/diskstats ]]; then
  declare -A t0
  while read -r _ _ dev rest; do
    [[ "$dev" =~ ^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)$ ]] || continue
    set -- $rest
    t0["$dev"]="${10:-0}"
  done < /proc/diskstats
  sleep 1
  while read -r _ _ dev rest; do
    [[ -n "${t0[$dev]:-}" ]] || continue
    set -- $rest
    d=$(( ${10:-0} - ${t0[$dev]} ))
    (( d > busiest_pct )) && { busiest_pct=$d; busiest="$dev"; }
  done < /proc/diskstats
  (( busiest_pct > 100 )) && busiest_pct=100
  (( busiest_pct < 0 )) && busiest_pct=0
fi

printf '{"container":%s,"busiest":"%s","busiest_pct":%s,' "$container" "$busiest" "$busiest_pct"
emit cpu;    printf ','
emit memory; printf ','
emit io
printf '}\n'
