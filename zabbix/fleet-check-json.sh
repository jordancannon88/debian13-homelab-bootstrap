#!/usr/bin/env bash
# fleet-check-json.sh — the Zabbix side of the fleet check: reads the daily
# summary written by fleet-check-run.sh and prints one JSON object.
#   {"ok":19,"total":21,"missing":"aide baseline,alloy","age":3600}
# missing = "none" when the host matches the standard; age = seconds since the
# last run (the template warns when it is older than a day and a half).
set -u
d=/var/lib/fleet-check
if [[ ! -r "$d/summary" ]]; then printf '{"ok":0,"total":0,"missing":"never-run","age":-1}\n'; exit 0; fi
line="$(cat "$d/summary")"
ok="$(sed -nE 's/.* ok=([0-9]+).*/\1/p' <<<"$line")"; total="$(sed -nE 's/.* total=([0-9]+).*/\1/p' <<<"$line")"
missing="$(sed -nE 's/.* missing=(.*)$/\1/p' <<<"$line")"
last="$(cat "$d/last_run" 2>/dev/null || echo 0)"; age=$(( $(date +%s) - last ))
missing="${missing//\"/}"
printf '{"ok":%s,"total":%s,"missing":"%s","age":%s}\n' "${ok:-0}" "${total:-0}" "${missing:-unknown}" "$age"
