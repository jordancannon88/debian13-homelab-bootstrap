#!/usr/bin/env bash
# pve-guest-volumes-json.sh — Zabbix LLD of guest volumes mounted on this PVE
# node, with the guest's name and whether the guest runs here.
#
# Every container root filesystem and mount point is a ZFS dataset mounted on
# the node (/local-zfs-*/subvol-<id>-disk-<n>, /rpool/data/subvol-...), so the
# stock filesystem discovery sees them all, including the replicas, and pages
# once per copy with only the dataset name. This rule names the guest and
# marks the copy: {#ROLE} = live (guest config lives on this node) or replica.
# The template filters to live only; the stock discovery is told to ignore
# subvol mountpoints on PVE nodes (zbx-pve-fsfilter.py).
#
# Needs root to read /etc/pve (sudoers line written by monitoring.sh):
#   UserParameter=custom.pve.guestvol.discovery,sudo /usr/local/bin/pve-guest-volumes-json.sh
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
node="$(hostname)"
first=1
printf '['
while IFS= read -r line; do
  set -- $line
  mp="$1"; ds="$2"
  [[ "$ds" =~ /subvol-([0-9]+)-disk-([0-9]+)$ ]] || continue
  id="${BASH_REMATCH[1]}"
  name=""; role="replica"
  if [[ -f "/etc/pve/nodes/$node/lxc/$id.conf" ]]; then
    role="live"
    name="$(awk -F': ' '$1=="hostname"{print $2; exit}' "/etc/pve/nodes/$node/lxc/$id.conf" 2>/dev/null)"
  else
    for c in /etc/pve/nodes/*/lxc/"$id".conf; do
      [[ -f "$c" ]] && { name="$(awk -F': ' '$1=="hostname"{print $2; exit}' "$c" 2>/dev/null)"; break; }
    done
  fi
  name="${name:-ct$id}"
  name="${name//\"/}"
  (( first )) || printf ','
  first=0
  printf '{"{#FSNAME}":"%s","{#VMID}":"%s","{#GUEST}":"%s","{#ROLE}":"%s","{#DATASET}":"%s"}' "$mp" "$id" "$name" "$role" "$ds"
done < <(findmnt -rn -t zfs -o TARGET,SOURCE 2>/dev/null)
printf ']\n'
