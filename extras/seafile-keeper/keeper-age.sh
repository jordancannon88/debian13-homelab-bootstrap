#!/bin/bash
# Zabbix UserParameter custom.seafile.keeper_age: seconds since the keeper last set the
# library password (from /var/lib/seafile-keeper/last_ok); 999999 when it never did.
f=/var/lib/seafile-keeper/last_ok
[ -r "$f" ] && echo $(( $(date +%s) - $(cat "$f") )) || echo 999999
exit 0
