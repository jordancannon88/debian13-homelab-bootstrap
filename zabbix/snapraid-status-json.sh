#!/bin/bash
# snapraid-status-json.sh: one JSON document from `snapraid status` (and `snapraid diff`)
# for the Zabbix UserParameter custom.snapraid.status (template "Homelab snapraid").
# Runs snapraid through sudo (sudoers: zabbix -> /usr/bin/snapraid status|diff only).
# status loads only the content files (sub-second); diff walks the data disks and can
# take longer on large arrays, so it is capped with a timeout and reported as -1 when
# it does not finish.
set -o pipefail
SNAPRAID="${SNAPRAID:-/usr/bin/snapraid}"
SUDO="${SNAPRAID_SUDO-sudo -n}"   # set SNAPRAID_SUDO= (empty) to test as root or with a stub
DIFF_TIMEOUT="${DIFF_TIMEOUT:-120}"

st="$($SUDO "$SNAPRAID" status 2>&1)"; st_rc=$?
if [ $st_rc -ne 0 ] && ! grep -q "SnapRAID status report" <<<"$st"; then
  printf '{"error":"snapraid status rc=%d: %s"}\n' "$st_rc" "$(tail -1 <<<"$st" | tr -d '"\\')"
  exit 0
fi

num() { grep -oE "$1" <<<"$st" | grep -oE '[0-9]+' | head -1; }
oldest="$(num 'oldest block was scrubbed [0-9]+ days')"
median="$(grep -oE 'the median [0-9]+' <<<"$st" | grep -oE '[0-9]+' | head -1)"
newest="$(grep -oE 'the newest [0-9]+' <<<"$st" | grep -oE '[0-9]+' | head -1)"
unscrubbed="$(num '[0-9]+% of the array is not scrubbed')"
errors="$(num 'there are [0-9]+ errors')"
grep -q 'No error detected' <<<"$st" && errors=0
grep -q 'No sync is in progress' <<<"$st" && sync_in_progress=0 || sync_in_progress=1
grep -q 'No rehash is in progress or needed' <<<"$st" && rehash_needed=0 || rehash_needed=1
# The scrub graph is empty until the first sync: report 99999 so "never" is obvious.
# snapraid omits the "N% of the array is not scrubbed" line entirely once everything is scrubbed, so a missing line means 0.
: "${oldest:=99999}" "${median:=99999}" "${newest:=99999}" "${unscrubbed:=0}" "${errors:=0}"

added=-1; removed=-1; updated=-1; moved=-1; copied=-1; restored=-1; diff_rc=-1; differences=-1
if df="$(timeout "$DIFF_TIMEOUT" $SUDO "$SNAPRAID" diff -q 2>&1)"; then diff_rc=0; else diff_rc=$?; fi
if [ "$diff_rc" -eq 0 ] || [ "$diff_rc" -eq 2 ]; then
  d() { grep -oE "^ *[0-9]+ $1\$" <<<"$df" | grep -oE '[0-9]+' | head -1; }
  added="$(d added)"; removed="$(d removed)"; updated="$(d updated)"
  moved="$(d moved)"; copied="$(d copied)"; restored="$(d restored)"
  : "${added:=0}" "${removed:=0}" "${updated:=0}" "${moved:=0}" "${copied:=0}" "${restored:=0}"
  differences=$(( added + removed + updated + moved + copied + restored ))
fi

# Result of the last scheduled run (snapraid-runner.sh writes "<epoch> <rc> <phase>").
last_epoch=0; last_rc=-1; last_phase=none
if [ -r /var/lib/snapraid-runner/last ]; then
  read -r last_epoch last_rc last_phase < /var/lib/snapraid-runner/last
  : "${last_epoch:=0}" "${last_rc:=-1}" "${last_phase:=none}"
fi

printf '{"last_run_epoch":%s,"last_run_rc":%s,"last_run_phase":"%s","scrub_oldest_days":%s,"scrub_median_days":%s,"scrub_newest_days":%s,"unscrubbed_pct":%s,"errors":%s,"sync_in_progress":%s,"rehash_needed":%s,"diff_rc":%s,"differences":%s,"added":%s,"removed":%s,"updated":%s,"moved":%s,"copied":%s,"restored":%s}\n' \
  "$last_epoch" "$last_rc" "$last_phase" "$oldest" "$median" "$newest" "$unscrubbed" "$errors" "$sync_in_progress" "$rehash_needed" \
  "$diff_rc" "$differences" "$added" "$removed" "$updated" "$moved" "$copied" "$restored"
