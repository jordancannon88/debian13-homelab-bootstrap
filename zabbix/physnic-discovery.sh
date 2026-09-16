#!/bin/bash
# Zabbix LLD: physical, non-wireless NICs (those with a sysfs device link).
# Backs UserParameter custom.physnic.discovery (template "Homelab physical NIC flapping").
# {#ROLE}: from /etc/zabbix/homelab-nic-roles (lines "<ifname> <role>", roles wan|lan|mesh|...),
# else "mesh" for thunderbolt-net, else "lan". WAN-facing NICs get their own, softer flap
# trigger (a bounce there is the ISP router's port, not our cable).
ROLES=/etc/zabbix/homelab-nic-roles
role_of() {
  local n="$1" drv="$2" r=""
  [ -r "$ROLES" ] && r=$(awk -v n="$n" '$1==n{print $2; exit}' "$ROLES")
  if [ -z "$r" ]; then [ "$drv" = thunderbolt-net ] && r=mesh || r=lan; fi
  printf '%s' "${r//[^A-Za-z0-9_-]/}"
}
first=1; printf '{"data":['
for d in /sys/class/net/*; do
  n=${d##*/}
  [ -e "$d/device" ] || continue
  [ -d "$d/wireless" ] && continue
  drv=$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null); drv=${drv:-unknown}
  [ $first -eq 1 ] || printf ','
  printf '{"{#IFNAME}":"%s","{#DRIVER}":"%s","{#ROLE}":"%s"}' "$n" "$drv" "$(role_of "$n" "$drv")"
  first=0
done
printf ']}\n'
