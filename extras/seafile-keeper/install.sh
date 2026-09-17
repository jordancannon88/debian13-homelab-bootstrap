#!/bin/bash
# install.sh: put the seafile-keeper script, unit, timer and Zabbix helper in place on a
# host that already ran the bootstrap (zabbix-agent2 present). Run as root from this dir
# or fetch the four files by curl into /root/seafile-keeper first. Does not create the
# secret file: write /etc/seafile-keeper/env by hand on the console (0600), then
#   systemctl enable --now seafile-keeper.timer && systemctl start seafile-keeper.service
set -e
d=$(dirname "$0")
install -m 0755 "$d/seafile-keeper.sh" /usr/local/bin/seafile-keeper.sh
install -m 0755 "$d/keeper-age.sh" /usr/local/bin/keeper-age.sh
install -m 0644 "$d/seafile-keeper.service" /etc/systemd/system/seafile-keeper.service
install -m 0644 "$d/seafile-keeper.timer" /etc/systemd/system/seafile-keeper.timer
install -d -m 0700 /etc/seafile-keeper
install -d -m 0755 /var/lib/seafile-keeper
if [ -d /etc/zabbix/zabbix_agent2.d ]; then
  printf 'UserParameter=custom.seafile.keeper_age,/usr/local/bin/keeper-age.sh\n' > /etc/zabbix/zabbix_agent2.d/seafile-keeper.conf
  chmod 0644 /etc/zabbix/zabbix_agent2.d/seafile-keeper.conf
  systemctl restart zabbix-agent2 2>/dev/null || true
fi
systemctl daemon-reload
echo "installed. Next: write /etc/seafile-keeper/env (SEAFILE_URL, SEAFILE_TOKEN, REPO_ID, REPO_PASSWORD), chmod 600, then:"
echo "  systemctl enable --now seafile-keeper.timer && systemctl start seafile-keeper.service && journalctl -u seafile-keeper -n 3"
