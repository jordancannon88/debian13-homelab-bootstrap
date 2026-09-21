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
# attribution, unlike a SMART reading which belongs to one drive. A node here has
# up to three real disks (a boot SSD, a USB hard disk and an NVMe), and one
# pressure number covers all of them.
#
# So this reports per-device busy time as well, from field 10 of /proc/diskstats
# (io_ticks, milliseconds with at least one I/O in flight) sampled over one second.
# EVERY disk at or above PSI_BUSY_MIN is listed, not just the busiest, because two
# disks can be saturated at once and naming only the worse one hides the other.
# Read the figure as "never went idle in that second" rather than "at capacity": it
# tracks saturation on a USB disk that takes one command at a time, but an SSD
# serving many requests in parallel reads 100 % on a trickle of writes.
#
# Whole disks only. ZFS volumes (zd*), partitions and device-mapper nodes are
# excluded because they would double-count their parent.
BUSY_MIN="${PSI_BUSY_MIN:-50}"

# drive_name <dev>: name a disk by serial and size the way the homelab does,
# "V9HDUJWL 6 TB" rather than "sdb", because device letters move between boots and
# differ per node for the same model (the 6 TB disk is sdc on pve2, sdb on pve3).
# Resolved from the by-id symlink built from the ATA identity, so re-enumerating
# the USB enclosure does not change it. Falls back to the device letter.
drive_name() {
  local dev="$1" link serial size_b size_tb size_gb
  for link in /dev/disk/by-id/*; do
    [[ -e "$link" ]] || continue
    case "$link" in
      *-part[0-9]*) continue;;
      */nvme-eui.*) continue;;   # the EUI form carries no serial
      */ata-*|*/nvme-*|*/scsi-SATA*) ;;
      *) continue;;
    esac
    [[ "$(readlink -f "$link" 2>/dev/null)" == "/dev/$dev" ]] || continue
    serial="${link##*_}"
    [[ "$serial" == "$link" || -z "$serial" ]] && continue
    size_b="$(cat "/sys/block/$dev/size" 2>/dev/null || echo 0)"
    size_tb="$(awk -v s="$size_b" 'BEGIN{ printf "%.0f", s * 512 / 1000000000000 }')"
    if (( size_tb >= 1 )); then
      printf '%s %s TB' "$serial" "$size_tb"
    else
      size_gb="$(awk -v s="$size_b" 'BEGIN{ printf "%.0f", s * 512 / 1000000000 }')"
      printf '%s %s GB' "$serial" "$size_gb"
    fi
    return
  done
  printf '%s' "$dev"
}

busiest="none"; busiest_drive="none"; busiest_pct=-1
busy_list=""; all_list=""
if [[ -r /proc/diskstats ]]; then
  declare -A t0
  while read -r _ _ dev rest; do
    [[ "$dev" =~ ^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)$ ]] || continue
    set -- $rest
    t0["$dev"]="${10:-0}"
  done < /proc/diskstats
  sleep 1
  declare -A pct
  while read -r _ _ dev rest; do
    [[ -n "${t0[$dev]:-}" ]] || continue
    set -- $rest
    d=$(( ${10:-0} - ${t0[$dev]} ))
    (( d > 100 )) && d=100
    (( d < 0 )) && d=0
    pct["$dev"]=$d
  done < /proc/diskstats

  # highest first, so the busy list reads worst-to-least and the top one is obvious
  for dev in $(for k in "${!pct[@]}"; do echo "${pct[$k]} $k"; done | sort -rn | awk '{print $2}'); do
    p=${pct[$dev]}
    name="$(drive_name "$dev")"
    if (( p > busiest_pct )); then
      busiest_pct=$p; busiest="$dev"; busiest_drive="$name"
    fi
    all_list="${all_list:+$all_list, }${name} ${p}%"
    (( p >= BUSY_MIN )) && busy_list="${busy_list:+$busy_list, }${name} (${dev}) ${p}%"
  done
fi
[[ -z "$busy_list" ]] && busy_list="none at or above ${BUSY_MIN}%"
[[ -z "$all_list" ]] && all_list="no disks found"

printf '{"container":%s,"busy":"%s","disks":"%s","busiest":"%s","busiest_drive":"%s","busiest_pct":%s,' \
  "$container" "$busy_list" "$all_list" "$busiest" "$busiest_drive" "$busiest_pct"
emit cpu;    printf ','
emit memory; printf ','
emit io
printf '}\n'
