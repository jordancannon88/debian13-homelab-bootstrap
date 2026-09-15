#!/bin/bash
# Zabbix item: how many times this boot a PCI device fell off the bus
# ("PCIe link lost, device now detached", any driver; the Intel I225-V did this
# on pve3 on 2026-09-05 and self-fenced the node). Reads the kernel journal for
# the current boot; the zabbix user needs the systemd-journal group.
# Backs UserParameter custom.nic.pcie_detach (template "Homelab physical NIC flapping").
n=$(journalctl -k -b -q -o cat 2>/dev/null | grep -c "PCIe link lost, device now detached")
echo "${n:-0}"
exit 0
