#!/bin/bash
# Zabbix item: kernel link-down counter for one interface (name validated).
# Backs UserParameter custom.nic.carrier_down[*] (template "Homelab physical NIC flapping").
n="$1"
case "$n" in *[!A-Za-z0-9_.-]*|"") echo "ZBX_NOTSUPPORTED"; exit 1;; esac
f="/sys/class/net/$n/carrier_down_count"
[ -r "$f" ] && cat "$f" || { echo "ZBX_NOTSUPPORTED"; exit 1; }
