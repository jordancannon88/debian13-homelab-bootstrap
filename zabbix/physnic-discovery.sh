#!/bin/bash
# Zabbix LLD: physical, non-wireless NICs (those with a sysfs device link).
# Backs UserParameter custom.physnic.discovery (template "Homelab physical NIC flapping").
first=1; printf '{"data":['
for d in /sys/class/net/*; do
  n=${d##*/}
  [ -e "$d/device" ] || continue
  [ -d "$d/wireless" ] && continue
  drv=$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null)
  [ $first -eq 1 ] || printf ','
  printf '{"{#IFNAME}":"%s","{#DRIVER}":"%s"}' "$n" "${drv:-unknown}"
  first=0
done
printf ']}\n'
