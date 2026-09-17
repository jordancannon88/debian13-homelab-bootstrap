#!/bin/bash
# Zabbix UserParameters for seafile-keeper:
#   keeper-age.sh age     -> seconds since the last accepted call (999999 if never)
#   keeper-age.sh status  -> outcome of the last run: "200 ok" or "<code> <reason>"
d=/var/lib/seafile-keeper
case "${1:-age}" in
  status) [ -r "$d/last_status" ] && cut -d" " -f2- "$d/last_status" || echo "never ran" ;;
  *)      [ -r "$d/last_ok" ] && echo $(( $(date +%s) - $(cat "$d/last_ok") )) || echo 999999 ;;
esac
exit 0
