#!/usr/bin/env python3
"""pve-backup-json.py: finished vzdump tasks on this Proxmox node as one JSON document,
for the Zabbix UserParameter custom.pve.backup (template "Homelab Proxmox events").

Reads `pvesh get /nodes/<host>/tasks --typefilter vzdump --source all` through sudo
(sudoers: zabbix -> that exact pvesh command). Keeps a cursor (newest task end time
seen) and a monotonic failed counter in STATE_DIR so an agent retry cannot lose or
double-count an event. First run only primes the cursor: history is never replayed.

Test marker: if /etc/zabbix/homelab-test/backup exists, one synthetic failed task
"TEST" with the marker's mtime as its end time is injected (counted once, like a real
task, thanks to the cursor). Remove the marker after the test.

Output fields:
  error           non-empty when pvesh failed (everything else then reflects state only)
  new_failed      failed tasks that finished since the previous run
  failed_total    monotonic count of failed tasks since install
  last_failed     text of the newest failed task ("vzdump guest 902 ended 2026-09-15 02:14: job errors")
  last_ok_epoch   end time of the newest successful task, 0 if none seen
  ok_24h, failed_24h  counts over the last 24 h (from the task list, not the cursor)
  running         vzdump tasks currently running
"""
import json, os, subprocess, sys, time

HOST = os.uname().nodename.split('.')[0]
STATE_DIR = os.environ.get("PVE_BACKUP_STATE", "/var/lib/zabbix/homelab")
MARKER = os.environ.get("PVE_BACKUP_MARKER", "/etc/zabbix/homelab-test/backup")
PVESH = os.environ.get("PVESH", "/usr/bin/pvesh")
SUDO = os.environ.get("PVE_BACKUP_SUDO", "sudo -n").split()
CURSOR = os.path.join(STATE_DIR, "backup-cursor")
COUNTS = os.path.join(STATE_DIR, "backup-counts")


def read_int(path, default=0):
    try:
        with open(path) as f:
            return int(f.read().strip() or default)
    except (OSError, ValueError):
        return default


def write_int(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(value) + "\n")
    os.replace(tmp, path)


def out(d):
    print(json.dumps(d, separators=(",", ":")))
    sys.exit(0)


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    cursor = read_int(CURSOR, -1)
    failed_total = read_int(COUNTS, 0)
    base = {"error": "", "new_failed": 0, "failed_total": failed_total, "last_failed": "",
            "last_ok_epoch": 0, "ok_24h": 0, "failed_24h": 0, "running": 0}
    try:
        r = subprocess.run(SUDO + [PVESH, "get", f"/nodes/{HOST}/tasks", "--typefilter", "vzdump",
                                   "--source", "all", "--limit", "500", "--output-format", "json"],
                           capture_output=True, text=True, timeout=25)
        if r.returncode != 0:
            base["error"] = f"pvesh rc={r.returncode}: {(r.stderr or r.stdout).strip()[:160]}"
            out(base)
        tasks = json.loads(r.stdout or "[]")
    except Exception as e:  # pvesh missing, timeout, bad JSON
        base["error"] = f"{type(e).__name__}: {e}"[:200]
        out(base)

    now = int(time.time())
    finished = []
    for t in tasks:
        if t.get("type") != "vzdump":
            continue
        end = t.get("endtime")
        if end is None:
            base["running"] += 1
            continue
        finished.append({"end": int(end), "id": str(t.get("id") or "-"),
                         "status": str(t.get("status") or "unknown")})

    if os.path.exists(MARKER):
        try:
            m_end = int(os.stat(MARKER).st_mtime)
        except OSError:
            m_end = now
        finished.append({"end": m_end, "id": "TEST", "status": "TEST marker (synthetic failure)"})

    finished.sort(key=lambda x: x["end"])
    newest = finished[-1]["end"] if finished else 0

    if cursor < 0:  # first run: prime, never replay history
        write_int(CURSOR, newest)
        write_int(COUNTS, failed_total)
        base["last_ok_epoch"] = max([f["end"] for f in finished if f["status"] == "OK"], default=0)
        out(base)

    new_failed = [f for f in finished if f["end"] > cursor and f["status"] != "OK"]
    if new_failed:
        failed_total += len(new_failed)
        write_int(COUNTS, failed_total)
        nf = new_failed[-1]
        base["last_failed"] = f"vzdump guest {nf['id']} ended {time.strftime('%Y-%m-%d %H:%M', time.localtime(nf['end']))}: {nf['status']}"[:200]
    else:
        # keep the previous text so the trigger's {ITEM.LASTVALUE2} stays meaningful
        try:
            with open(os.path.join(STATE_DIR, "backup-last-failed")) as f:
                base["last_failed"] = f.read().strip()
        except OSError:
            pass
    if base["last_failed"]:
        with open(os.path.join(STATE_DIR, "backup-last-failed"), "w") as f:
            f.write(base["last_failed"] + "\n")
    if newest > cursor:
        write_int(CURSOR, newest)

    base["new_failed"] = len(new_failed)
    base["failed_total"] = failed_total
    base["last_ok_epoch"] = max([f["end"] for f in finished if f["status"] == "OK"], default=0)
    base["ok_24h"] = sum(1 for f in finished if f["status"] == "OK" and now - f["end"] <= 86400)
    base["failed_24h"] = sum(1 for f in finished if f["status"] != "OK" and now - f["end"] <= 86400)
    out(base)


if __name__ == "__main__":
    main()
