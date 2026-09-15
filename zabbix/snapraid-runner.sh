#!/bin/bash
# snapraid-runner.sh: the scheduled snapraid job (systemd snapraid-runner.timer, daily).
#   1. refuse to sync when more than DEL_THRESHOLD files were removed (mass-delete guard)
#   2. snapraid sync
#   3. snapraid scrub -p SCRUB_PCT -o SCRUB_OLDER   (a slice of the oldest blocks each day)
# Writes "<epoch> <rc> <phase>" to /var/lib/snapraid-runner/last for the Zabbix watch:
#   rc 0 = all good; 2 = diff refused (mass delete, sync NOT run); other = sync/scrub failed.
set -o pipefail
SNAPRAID=/usr/bin/snapraid
DEL_THRESHOLD="${DEL_THRESHOLD:-100}"
SCRUB_PCT="${SCRUB_PCT:-8}"
SCRUB_OLDER="${SCRUB_OLDER:-10}"
STATE=/var/lib/snapraid-runner/last
mkdir -p "$(dirname "$STATE")"
finish() { printf '%s %s %s\n' "$(date +%s)" "$1" "$2" > "$STATE"; chmod 644 "$STATE"; exit "$1"; }

echo "snapraid-runner: diff"
diff_out="$($SNAPRAID diff -q 2>&1)"; diff_rc=$?
if [ "$diff_rc" -ne 0 ] && [ "$diff_rc" -ne 2 ]; then echo "$diff_out" | tail -3; finish 1 diff; fi
removed="$(grep -oE '^ *[0-9]+ removed$' <<<"$diff_out" | grep -oE '[0-9]+')"; removed="${removed:-0}"
if [ "$removed" -gt "$DEL_THRESHOLD" ]; then
  echo "snapraid-runner: REFUSING sync, $removed files removed (> $DEL_THRESHOLD). Check the array, then run 'snapraid sync' by hand."
  finish 2 diff
fi

if [ "$diff_rc" -eq 2 ]; then
  echo "snapraid-runner: sync"
  $SNAPRAID sync 2>&1 | tail -5 || finish 3 sync
  [ "${PIPESTATUS[0]}" -eq 0 ] || finish 3 sync
else
  echo "snapraid-runner: nothing to sync"
fi

echo "snapraid-runner: scrub -p $SCRUB_PCT -o $SCRUB_OLDER"
$SNAPRAID scrub -p "$SCRUB_PCT" -o "$SCRUB_OLDER" 2>&1 | tail -5
[ "${PIPESTATUS[0]}" -eq 0 ] || finish 4 scrub
finish 0 scrub
