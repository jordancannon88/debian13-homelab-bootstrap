#!/bin/sh
# nvme-smart-json.sh <dev>: raw `smartctl -j -A` for one NVMe device.
# Backs the zabbix UserParameter custom.nvme.smart[*] (available spare is not in the stock plugin output).
case "$1" in
  /dev/nvme[0-9]|/dev/nvme[0-9][0-9]|/dev/nvme[0-9]n[0-9]|/dev/nvme[0-9][0-9]n[0-9]) ;;
  *) echo '{"error":"bad device"}'; exit 0 ;;
esac
sudo /usr/sbin/smartctl -j -A "$1"
exit 0
