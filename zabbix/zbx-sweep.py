#!/usr/bin/env python3
"""zbx-sweep.py: monitoring that is not monitoring anything.

Two questions, both raised by the CPU temperature work of 2026-09-21, where five
items sat on hosts that could never produce them and ten triggers watched those
items. Nothing in Zabbix reports that state: an unsupported item is not a problem,
and a trigger over a dead item is silent rather than wrong. You have to go looking.

  strays   Host-level items whose key names a DIFFERENT host, for example
           pve4.cpuTemperature sitting on pms0. This is what host cloning in the
           interface produces, because a clone carries host-level items and triggers
           with it. Only cpuTemperature was checked by hand; this checks every key
           against every host name.

  dead     Items that are unsupported, or that have never returned a value, with the
           triggers that depend on them. A trigger over an item with no data cannot
           fire, so a dead item is silently missing coverage rather than a visible
           fault. Templated and host-level are reported separately: a templated one
           is usually a template linked where it does not apply, a host-level one is
           usually something made by hand and forgotten.

  python3 zbx-sweep.py strays
  python3 zbx-sweep.py dead
  python3 zbx-sweep.py dead --host-level-only

Read-only. It deletes nothing and changes nothing; it only tells you where to look.
Run from a machine that can reach the Zabbix frontend (the laptop; the dev box is
firewalled off). Needs host.get, item.get and trigger.get on the API role.
"""
import json, os, re, sys, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))


def api(method, params):
    tok = open(TOKEN_FILE).readline().strip()
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(URL, data=body, headers={
        "Content-Type": "application/json-rpc", "Authorization": f"Bearer {tok}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        out = json.loads(r.read())
    if "error" in out:
        raise SystemExit(f"{method}: {out['error'].get('data') or out['error']}")
    return out["result"]


def triggers_on(itemid):
    return api("trigger.get", {"itemids": [itemid], "output": ["description", "status"],
                               "expandDescription": True})


def label(it):
    return "templated" if it.get("templateid", "0") != "0" else "host-level"


cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd not in ("strays", "dead"):
    raise SystemExit(__doc__)

hosts = {h["hostid"]: h["host"] for h in api("host.get", {"output": ["hostid", "host"]})}
print(f"{len(hosts)} monitored hosts\n")

items = api("item.get", {
    "output": ["itemid", "key_", "name", "lastvalue", "lastclock", "state", "error",
               "status", "templateid"],
    "selectHosts": ["host"], "monitored": True})

if cmd == "strays":
    # A key "names" a host when the host's name appears as a whole word in it, so
    # pve4.cpuTemperature names pve4 but vfs.fs.size[/pve4data] does not match on a
    # partial. Word boundaries matter: pve1 must not match inside pve10.
    names = sorted(set(hosts.values()), key=len, reverse=True)
    pats = {n: re.compile(rf"(?<![A-Za-z0-9]){re.escape(n)}(?![A-Za-z0-9])") for n in names}
    found = 0
    for it in sorted(items, key=lambda i: (i["hosts"][0]["host"], i["key_"])):
        host = it["hosts"][0]["host"]
        named = [n for n in names if n != host and pats[n].search(it["key_"])]
        if not named:
            continue
        found += 1
        state = "UNSUPPORTED" if it.get("state") == "1" else (
            "no data, ever" if str(it.get("lastclock", "0")) == "0" else
            f"collecting, last {it.get('lastvalue')!r}")
        print(f"{host}: {it['key_']}")
        print(f"    names {', '.join(named)} instead of {host}   ({label(it)}, {state})")
        if it.get("error"):
            print(f"    {it['error']}")
        for t in triggers_on(it["itemid"]):
            dis = " DISABLED" if t.get("status") == "1" else " enabled"
            print(f"    trigger: {t['description']}{dis}")
    print(f"\n{found} item(s) whose key names another host." if found else
          "\nno items name a host other than their own.")
    print("An item still collecting despite a misnamed key is a naming problem, not a"
          "\nstray: something else is answering that key. Read before deleting.")

else:
    host_only = "--host-level-only" in sys.argv
    by_host = {}
    for it in items:
        if it.get("status") == "1":
            continue                      # item disabled on purpose, not a fault
        if host_only and it.get("templateid", "0") != "0":
            continue
        why = None
        if it.get("state") == "1":
            why = "UNSUPPORTED"
        elif str(it.get("lastclock", "0")) == "0":
            why = "no data, ever"
        if why:
            by_host.setdefault(it["hosts"][0]["host"], []).append((it, why))
    total = sum(len(v) for v in by_host.values())
    for host in sorted(by_host):
        rows = by_host[host]
        print(f"{host}  ({len(rows)})")
        for it, why in sorted(rows, key=lambda r: r[0]["key_"]):
            trigs = triggers_on(it["itemid"])
            live = [t for t in trigs if t.get("status") != "1"]
            note = (f"  <- {len(live)} enabled trigger(s) over it, none can fire"
                    if live else "")
            print(f"    {why:<14} {label(it):<10} {it['key_']}{note}")
            if it.get("error"):
                print(f"                   {it['error']}")
    print(f"\n{total} item(s) across {len(by_host)} host(s) are collecting nothing.")
    print("Templated ones are usually a template linked where it does not apply."
          "\nHost-level ones are usually something made by hand and forgotten."
          "\nAn enabled trigger over one of them is coverage that cannot ever fire.")
