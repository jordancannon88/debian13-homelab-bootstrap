#!/usr/bin/env bash
# fleet-check-run.sh — run fleet-check.sh --summary as root once a day and
# leave the result where the Zabbix agent can read it without privileges.
# Installed by monitoring.sh (setup_fleet_check) with fleet-check.timer.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
out=/var/lib/fleet-check
install -d -m 0755 "$out"
line="$(bash /usr/local/bin/fleet-check.sh --summary 2>/dev/null)"
[[ -n "$line" ]] || line="$(hostname) ok=0 total=0 missing=fleet-check-failed"
printf '%s\n' "$line" > "$out/summary.tmp"
date +%s > "$out/last_run.tmp"
install -m 0644 "$out/summary.tmp" "$out/summary"; install -m 0644 "$out/last_run.tmp" "$out/last_run"
rm -f "$out/summary.tmp" "$out/last_run.tmp"
