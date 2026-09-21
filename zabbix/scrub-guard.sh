#!/bin/bash
# scrub-guard.sh — watch a scrub of local-zfs-hdd on pve3 and make sure the PBS
# datastore gets its second copy back, whichever way the scrub ends.
#
# Why this exists. The pool is a single USB-attached disk, V9HDUJWL 6 TB on pve3,
# behind an ASMedia bridge on usb-storage, which issues one command at a time. It
# holds the cluster PBS datastore that every vzdump job on the cluster writes to
# (903 at 21:00, 912 and 904 at 22:30 and 02:30, 911 at 01:00, 907 at 04:00, 908
# at 04:30, 902 every two hours). A scrub saturates that disk, and while it ran the
# replication jobs 901-0 and 901-1 had their `zfs snapshot` calls time out, so they
# were deliberately disabled. Those two jobs are the datastore's only fresh second
# copy.
#
# The thing that matters is not pausing the scrub. It is that replication is
# enabled again before the night's backups start, so new backups are not single
# copies on a single disk. So the handback runs on EVERY ending:
#   - the scrub finishes on its own, which is the likely case
#   - the clock reaches the cutoff with the scrub still running
#   - 901's fail count rises while its jobs are enabled
# An earlier version put the handback only on the clock path, which is the path
# least likely to execute. That was the bug this rewrite fixes.
#
# On a signal (a deliberate restart, a shutdown) it does NOT hand back, because a
# restart mid-scrub would re-enable the jobs and recreate the timeouts. It logs
# loudly instead. The durable backstop is a Zabbix trigger on a replication job
# left disabled, which catches this whatever happens to this script.
#
# `zpool scrub -p` keeps progress across a pause and a reboot; a later
# `zpool scrub` resumes rather than restarting.
#
# Log appended to /root/scrub-guard.log. Kan x9d5nl76f0t6.
set -u
POOL=local-zfs-hdd
JOBS=(901-0 901-1)
PAUSE_AT_H=20
PAUSE_AT_M=30
LOG=/root/scrub-guard.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

scrub_running() { zpool status "$POOL" 2>/dev/null | grep -q "scrub in progress"; }

# Minutes since midnight, so the cutoff is arithmetic rather than string order. A
# string compare of "09:00" against "20:30" happens to work, but the intent is
# clearer this way and it cannot surprise anyone after midnight.
now_minutes() { local h m; h=$(date +%H); m=$(date +%M); echo $(( 10#$h * 60 + 10#$m )); }
pause_minutes=$(( PAUSE_AT_H * 60 + PAUSE_AT_M ))

# Highest fail count among the 901 jobs that are ENABLED. Field 7 is FailCount in
# the JobID Enabled Target LastSync NextSync Duration FailCount State column order.
# Not counted from the end: when a job fails, State becomes a multi-word error and
# counting backwards reads a word out of the message instead.
repl_failcount() {
  pvesr status 2>/dev/null | awk '$1 ~ /^901-/ && $2 == "Yes" { print $7 }' | sort -rn | head -1
}

report_jobs() {
  pvesr status 2>/dev/null | awk -v p="$1" '$1 ~ /^901-/ { print p $1 " enabled=" $2 " failcount=" $7 }' >> "$LOG"
}

handback_done=0
handback() {
  local why="$1" job rc
  (( handback_done )) && return 0
  handback_done=1
  log "handback ($why): re-enabling replication so the datastore has a second copy"
  for job in "${JOBS[@]}"; do
    # Enable unconditionally. Enabling an already-enabled job is harmless, and a
    # conditional check was itself a silent failure path: if the status command
    # failed, the job stayed disabled and nothing said so.
    if pvesr enable "$job" 2>>"$LOG"; then
      log "  $job enabled"
    else
      rc=$?
      log "  $job FAILED TO ENABLE (rc=$rc). THE DATASTORE HAS NO SECOND COPY. Fix by hand: pvesr enable $job"
    fi
  done
  report_jobs "  after handback: "
}

on_signal() {
  log "SIGNALLED: exiting WITHOUT handback, because a restart mid-scrub would re-enable"
  log "the jobs and recreate the snapshot timeouts. REPLICATION IS STILL DISABLED."
  log "If this was not a restart, run: pvesr enable 901-0 ; pvesr enable 901-1"
  exit 143
}
trap on_signal TERM INT

log "=== guard started. Cutoff ${PAUSE_AT_H}:${PAUSE_AT_M}; also pauses on a rising fail count while 901's jobs are enabled."
report_jobs "  at start: "

if ! scrub_running; then
  log "no scrub in progress at startup"
  handback "no scrub running"
  exit 0
fi

while scrub_running; do
  if (( $(now_minutes) >= pause_minutes )); then
    log "reached the cutoff with the scrub still running"
    if zpool scrub -p "$POOL" 2>>"$LOG"; then
      log "scrub PAUSED, progress kept. Resume in daytime, and disable both jobs again first."
    else
      log "FAILED to pause the scrub; handing replication back anyway"
    fi
    zpool status "$POOL" 2>/dev/null | grep -E "scan:|scanned|issued" >> "$LOG"
    handback "paused at the cutoff"
    exit 0
  fi

  fc="$(repl_failcount)"
  if [[ -n "${fc:-}" && "$fc" =~ ^[0-9]+$ ]] && (( fc >= 2 )); then
    log "901 replication fail count reached $fc while enabled; the replicas matter more than the scrub"
    zpool scrub -p "$POOL" 2>>"$LOG" && log "scrub PAUSED, progress kept"
    handback "replication was failing"
    exit 0
  fi

  sleep 300
done

log "scrub is no longer running; final state:"
zpool status -v "$POOL" 2>/dev/null | grep -E "scan:|V9HDUJWL|errors:" >> "$LOG"
handback "scrub finished"
log "=== guard finished"
