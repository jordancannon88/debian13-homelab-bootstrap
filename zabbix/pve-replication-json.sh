#!/bin/bash
# pve-replication-json.sh: every Proxmox replication job on this node as one JSON
# document, for the Zabbix UserParameter custom.pve.replication (template
# "Homelab Proxmox events"). Runs `pvesr status` through sudo (sudoers:
# zabbix -> /usr/bin/pvesr status only).
# Test marker: if /etc/zabbix/homelab-test/replication exists, a synthetic job
# TEST-0 (target TEST) is added; file content "0" makes it healthy, anything
# else makes it fail 3 times in a row. Remove the marker after the test.
SUDO="${PVESR_SUDO-sudo -n}"
MARKER=/etc/zabbix/homelab-test/replication

epoch() { # pvesr prints 2026-09-15_17:45:01, '-' or 'pending'
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) date -d "${1/_/ }" +%s 2>/dev/null || echo 0 ;;
    *) echo 0 ;;
  esac
}
jsonstr() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; printf '%s' "${s:0:160}"; }

out="$($SUDO /usr/bin/pvesr status 2>&1)"; rc=$?
if [ $rc -ne 0 ] || ! grep -q '^JobID' <<<"$out"; then
  printf '{"error":"pvesr status rc=%d: %s","jobs":{},"job_count":0,"failing_count":0,"lld_jobs":[]}\n' "$rc" "$(jsonstr "$(tail -1 <<<"$out")")"
  exit 0
fi

jobs=""; lld=""; count=0; failing=0
while read -r job enabled target last next dur fails state; do
  [[ "$job" =~ ^[0-9]+-[0-9]+$ ]] || continue
  [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
  guest="${job%%-*}"; tgt="${target#local/}"; en=0; [ "$enabled" = "Yes" ] && en=1
  state="${state:-OK}"; [ "$fails" -eq 0 ] && state="OK"
  [[ "$dur" =~ ^[0-9.]+$ ]] || dur=0
  jobs="${jobs:+$jobs,}\"$job\":{\"target\":\"$(jsonstr "$tgt")\",\"guest\":$guest,\"enabled\":$en,\"fails\":$fails,\"state\":\"$(jsonstr "$state")\",\"last_sync\":$(epoch "$last"),\"next_sync\":$(epoch "$next"),\"duration\":$dur}"
  lld="${lld:+$lld,}{\"{#JOB}\":\"$job\",\"{#GUEST}\":\"$guest\",\"{#TARGET}\":\"$(jsonstr "$tgt")\"}"
  count=$((count+1)); [ "$fails" -gt 0 ] && failing=$((failing+1))
done < <(tail -n +2 <<<"$out")

if [ -f "$MARKER" ]; then
  tf=3; [ "$(tr -d '[:space:]' < "$MARKER")" = "0" ] && tf=0
  ts="TEST marker"; [ "$tf" -eq 0 ] && ts="OK"
  jobs="${jobs:+$jobs,}\"TEST-0\":{\"target\":\"TEST\",\"guest\":0,\"enabled\":1,\"fails\":$tf,\"state\":\"$ts\",\"last_sync\":$(date +%s),\"next_sync\":0,\"duration\":0}"
  lld="${lld:+$lld,}{\"{#JOB}\":\"TEST-0\",\"{#GUEST}\":\"TEST\",\"{#TARGET}\":\"TEST\"}"
  count=$((count+1)); [ "$tf" -gt 0 ] && failing=$((failing+1))
fi

printf '{"error":"","jobs":{%s},"job_count":%d,"failing_count":%d,"lld_jobs":[%s]}\n' "$jobs" "$count" "$failing" "$lld"
