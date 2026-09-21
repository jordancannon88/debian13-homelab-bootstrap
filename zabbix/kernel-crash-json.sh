#!/bin/bash
# Zabbix item custom.kernel.crash, template "Homelab kernel": did this machine crash,
# and did it crash LAST time.
#
# Why the previous boot matters. On 2026-09-21 pve1 took a NULL pointer dereference in
# the kernel's vhost wake path, CPU 12 hard-locked, and softdog reset the node about a
# hundred seconds later. Monitoring saw only "has been restarted (uptime < 10m)", which
# says the uptime reset and nothing about why, and the SMART and NIC alerts that fired
# alongside it were both consequences that pointed at the wrong causes. Nothing said
# "this node crashed". Report page 486, Kan bdfszlt5eddx.
#
# A counter for the current boot cannot detect that, because the reboot zeroes it. So
# this reports both boots: the current one, to catch an oops while the machine is still
# up, and the previous one, to say after recovery that the machine went down hard.
#
# "Unclean" is the broadest and most useful of these, and it comes from wtmp, not the
# journal. The first attempt grepped the previous boot for systemd shutdown markers and
# was WRONG: it reported all seven retained boots on pve1 as unclean, because journald
# stops before the late shutdown messages reach persistent storage. `last` already solves
# this: it writes "crash" in place of an end time for any boot that stopped without a
# shutdown record. That covers a hang, a panic, a watchdog reset and power loss alike. It
# does not say which, which is the point; it says look.
#
# The zabbix user needs the systemd-journal group, as the hung-task item already does.
# A persistent journal is needed only for the oops and lockup counts; the unclean flag
# comes from wtmp and survives regardless.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# count <boot> <pattern>
count() {
  journalctl -k -b "$1" -q -o cat 2>/dev/null | grep -cE "$2" || true
}

jstr() { printf '%s' "$1" | tr -d '\\"' | tr '\n' ' ' | cut -c1-200; }

OOPS='Oops:|BUG: kernel NULL pointer|BUG: unable to handle'
LOCK='hard LOCKUP|soft lockup - CPU'
NETWD='NETDEV WATCHDOG'

this_oops=$(count 0 "$OOPS");  this_lock=$(count 0 "$LOCK");  this_netwd=$(count 0 "$NETWD")
prev_oops=$(count -1 "$OOPS"); prev_lock=$(count -1 "$LOCK"); prev_netwd=$(count -1 "$NETWD")

# Is there a previous boot at all? A freshly installed or freshly rotated journal has
# none, and that must not read as "crashed".
# Line 1 of `last -x reboot` is the running boot; line 2 is the one before it. An end
# field of "crash" means it stopped without a shutdown record.
prev_reboot="$(last -x reboot 2>/dev/null | sed -n 2p)"
if [[ -n "$prev_reboot" ]]; then
  have_prev=1
  if printf '%s' "$prev_reboot" | grep -q 'crash'; then prev_unclean=1; else prev_unclean=0; fi
  last_line="$(journalctl -b -1 -q -o cat 2>/dev/null | tail -1)"
else
  have_prev=0; prev_unclean=0; last_line=""
fi

# One human-readable line for the alert, so the problem names the evidence instead of
# making somebody go and find it.
detail="clean"
if (( have_prev == 0 )); then
  # Seen on pve2 2026-09-21: wtmpdb exists but holds no reboot rows, so this check cannot
  # work there. That must read as "cannot see", never as "clean", which is why have is its
  # own item with its own trigger.
  detail="CANNOT CHECK: no reboot records in wtmp"
elif (( prev_unclean )); then
  detail="previous boot ended without a shutdown record"
  (( prev_oops ))  && detail="$detail; ${prev_oops} oops/BUG"
  (( prev_lock ))  && detail="$detail; ${prev_lock} lockup"
  (( prev_netwd )) && detail="$detail; ${prev_netwd} netdev watchdog"
  detail="$detail; last line: $(jstr "$last_line")"
fi

printf '{"this":{"oops":%s,"lockup":%s,"netdev_wd":%s},' \
  "${this_oops:-0}" "${this_lock:-0}" "${this_netwd:-0}"
printf '"prev":{"have":%s,"unclean":%s,"oops":%s,"lockup":%s,"netdev_wd":%s,"detail":"%s"}}\n' \
  "$have_prev" "$prev_unclean" "${prev_oops:-0}" "${prev_lock:-0}" "${prev_netwd:-0}" \
  "$(jstr "$detail")"
