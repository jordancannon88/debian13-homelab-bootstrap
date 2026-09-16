#!/bin/sh
# isp-gw-ping.sh (OPNsense, FreeBSD sh): 1 if the firewall's default gateway (the ISP
# router) answers one ping, else 0. Exposed by net-snmp as `extend ispgw` in
# /usr/local/etc/snmp/snmpd.conf and read by the Zabbix template "Homelab internet"
# (item isp.gw.ping). Reads the gateway from the routing table, so a WAN renumber
# needs no edit here. Not part of the Debian bootstrap; kept in this repo as the
# source of truth. Kan 9yfu635gx2y4.
GW=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2; exit}')
if [ -n "$GW" ] && ping -c 1 -W 1000 -t 2 "$GW" >/dev/null 2>&1; then
  echo 1
else
  echo 0
fi
