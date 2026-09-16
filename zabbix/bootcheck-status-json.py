#!/usr/bin/env python3
"""bootcheck-status-json.py: the post-outage boot check result (pve-outage-runbook.sh, run
once per boot by pve-outage-boot-check.service) as one JSON document for the Zabbix
UserParameter custom.bootcheck.status (template "Homelab boot check"). Reads
/var/lib/pve-outage-runbook/latest.json as the zabbix user and adds computed fields.

Fields (on top of the runbook's own host, ts, boot_id, attn, overall, log, checks):
  current_boot   1 when the file's boot_id is this boot's
  age            seconds since the run (from ts), 999999 when unknown
  uptime         seconds since boot (/proc/uptime)
  ok             count of OK checks
  fail           kebab list of CHECK rows (cluster-quorum, tb3-mesh, ...)
  attention      "<n> check(s) need eyes: <fail list>" when this boot's run is ATTENTION,
                 else "" (the High trigger keys on this one item)
  clean_recent   "<n> checks OK" for one hour after a GREEN run this boot, else ""
                 (the Information trigger keys on this one item)
  lld_checks     discovery rows, one per check
  test           1 while the test marker exists
  error          non-empty when the file is missing or unreadable

Test marker /etc/zabbix/homelab-test/bootcheck: a line "stale" reports current_boot=0
(did not run this boot). Remove it after the test.
"""
import json, os, re, time

FILE = os.environ.get("BOOTCHECK_FILE", "/var/lib/pve-outage-runbook/latest.json")
MARKER = os.environ.get("BOOTCHECK_MARKER", "/etc/zabbix/homelab-test/bootcheck")
CLEAN_WINDOW = 3600


def read(path):
    with open(path) as f:
        return f.read()


def uptime():
    try:
        return int(float(read("/proc/uptime").split()[0]))
    except (OSError, ValueError, IndexError):
        return 0


def main():
    now = int(time.time())
    out = {"host": "", "ts": "", "boot_id": "", "attn": 0, "overall": "", "log": "", "checks": [],
           "current_boot": 0, "age": 999999, "uptime": uptime(), "ok": 0, "fail": "",
           "attention": "", "clean_recent": "", "lld_checks": [], "test": 0, "error": ""}
    try:
        d = json.loads(read(FILE))
    except OSError as e:
        out["error"] = f"{FILE}: {e.strerror} (boot check never ran, or file not 0644)"
        print(json.dumps(out, separators=(",", ":")))
        return
    except ValueError as e:
        out["error"] = f"{FILE}: bad JSON: {e}"[:200]
        print(json.dumps(out, separators=(",", ":")))
        return

    for k in ("host", "ts", "boot_id", "log", "overall"):
        out[k] = str(d.get(k, ""))[:200]
    try:
        out["attn"] = int(d.get("attn", 0))
    except (TypeError, ValueError):
        out["attn"] = 0
    checks = [c for c in d.get("checks", []) if isinstance(c, dict)]
    out["checks"] = [{"check": str(c.get("check", ""))[:40], "state": str(c.get("state", ""))[:10],
                      "detail": str(c.get("detail", ""))[:200]} for c in checks]
    out["lld_checks"] = [{"{#CHECK}": c["check"]} for c in out["checks"] if c["check"]]
    out["ok"] = sum(1 for c in out["checks"] if c["state"] == "OK")
    fails = [re.sub(r"[^a-z0-9]+", "-", c["check"].lower()).strip("-") for c in out["checks"] if c["state"] != "OK"]
    out["fail"] = ",".join(fails)

    try:
        this_boot = read("/proc/sys/kernel/random/boot_id").strip()
    except OSError:
        this_boot = ""
    out["current_boot"] = 1 if this_boot and out["boot_id"] == this_boot else 0
    m = re.match(r"^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$", out["ts"])
    if m:
        t = time.mktime(tuple(int(x) for x in m.groups()) + (0, 0, -1))
        out["age"] = max(0, int(now - t))

    if os.path.exists(MARKER):
        out["test"] = 1
        try:
            if "stale" in read(MARKER).split():
                out["current_boot"] = 0
        except OSError:
            pass

    if out["current_boot"] == 1:
        n = len(fails)
        if out["overall"] == "ATTENTION" or n > 0:
            out["attention"] = f"{n} check{'s' if n != 1 else ''} need{'s' if n == 1 else ''} eyes: {out['fail'] or 'see log'}"
        elif out["overall"] == "GREEN" and out["age"] < CLEAN_WINDOW:
            out["clean_recent"] = f"{out['ok']} checks OK"
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never leave the item unsupported
        print(json.dumps({"error": f"{type(e).__name__}: {e}"[:200], "test": 0, "lld_checks": [], "checks": []}))
