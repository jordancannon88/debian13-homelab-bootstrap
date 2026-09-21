#!/usr/bin/env python3
"""zbx-sweep.py: monitoring that is not monitoring anything.

Two questions, both raised by the CPU temperature work of 2026-09-21, where five
items sat on hosts that could never produce them and ten triggers watched those
items. Nothing in Zabbix reports that state: an unsupported item is not a problem,
and a trigger over a dead item is silent rather than wrong. You have to go looking.

  strays   Items whose key names a DIFFERENT host, for example pve4.cpuTemperature
           sitting on pms0. This is what host cloning in the interface produces,
           because a clone carries host-level items and triggers with it.

  dead     Items that are unsupported, or that have never returned a value, with the
           triggers that depend on them. A trigger over an item with no data cannot
           fire, so a dead item is silently missing coverage rather than a visible
           fault.

Without a host it prints one line per host, a count only. Name a host to see the
detail for that host alone. Nothing here is worth reading as a wall of text, and the
counts tell you which host to look at first.

  python3 zbx-sweep.py strays              counts per host
  python3 zbx-sweep.py strays pve2         detail for one host
  python3 zbx-sweep.py dead                counts per host
  python3 zbx-sweep.py dead pve1           detail for one host
  python3 zbx-sweep.py dead pve1 --templated   include templated items too

By default `dead` shows host-level items only, because a templated item that is
unsupported is usually one template linked where it does not apply, which is a
different and less urgent problem than something made by hand and forgotten.

Read-only. It deletes nothing; it only tells you where to look. Run from a machine
that can reach the Zabbix frontend (the laptop; the dev box is firewalled off).
Needs host.get, item.get and trigger.get on the API role.
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


def label(it):
    return "templated" if it.get("templateid", "0") != "0" else "host-level"


def why_dead(it):
    if it.get("state") == "1":
        return "UNSUPPORTED"
    if str(it.get("lastclock", "0")) == "0":
        return "no data, ever"
    return None


args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = {a for a in sys.argv[1:] if a.startswith("--")}
cmd = args[0] if args else ""
only = args[1] if len(args) > 1 else None
if cmd not in ("strays", "dead"):
    raise SystemExit(__doc__)

hosts = sorted({h["host"] for h in api("host.get", {"output": ["host"]})})
items = api("item.get", {
    "output": ["itemid", "key_", "name", "lastvalue", "lastclock", "state", "error",
               "status", "templateid"],
    "selectHosts": ["host"], "monitored": True})

# Collect the findings first, then decide how much of them to print.
found = {}
if cmd == "strays":
    # A key "names" a host when the name appears as a whole word: pve4.cpuTemperature
    # names pve4, while vfs.fs.size[/pve4data] does not, and pve1 must not match
    # inside pve10.
    pats = {n: re.compile(rf"(?<![A-Za-z0-9]){re.escape(n)}(?![A-Za-z0-9])") for n in hosts}
    for it in items:
        host = it["hosts"][0]["host"]
        named = [n for n in hosts if n != host and pats[n].search(it["key_"])]
        if named:
            found.setdefault(host, []).append((it, ", ".join(named)))
else:
    for it in items:
        if it.get("status") == "1":
            continue                                  # disabled on purpose
        if "--templated" not in flags and it.get("templateid", "0") != "0":
            continue
        w = why_dead(it)
        if w:
            found.setdefault(it["hosts"][0]["host"], []).append((it, w))

if not found:
    print(f"{len(hosts)} hosts checked, nothing found." if cmd == "strays" else
          f"{len(hosts)} hosts checked, no dead items.")
    raise SystemExit(0)

if only is None:
    width = max(len(h) for h in found)
    total = sum(len(v) for v in found.values())
    for host in sorted(found, key=lambda h: (-len(found[h]), h)):
        print(f"  {host:<{width}}  {len(found[host]):>3}")
    scope = "" if "--templated" in flags or cmd == "strays" else " host-level"
    print(f"\n{total}{scope} item(s) across {len(found)} of {len(hosts)} hosts.")
    print(f"Detail for one host:  python3 zbx-sweep.py {cmd} <host>"
          + ("  [--templated]" if cmd == "dead" else ""))
    raise SystemExit(0)

if only not in found:
    print(f"{only}: nothing found" if only in hosts else f"{only}: not a monitored host")
    raise SystemExit(0)

print(f"{only}\n")
for it, note in sorted(found[only], key=lambda r: r[0]["key_"]):
    state = why_dead(it) or (f"collecting, last {it.get('lastvalue')!r}")
    if cmd == "strays":
        print(f"  {it['key_']}")
        print(f"      names {note} instead of {only}   ({label(it)}, {state})")
    else:
        print(f"  {it['key_']}")
        print(f"      {note}   ({label(it)})")
    if it.get("error"):
        print(f"      {it['error']}")
    live = [t for t in api("trigger.get", {"itemids": [it["itemid"]],
                                           "output": ["description", "status"],
                                           "expandDescription": True})
            if t.get("status") != "1"]
    for t in live:
        print(f"      trigger over it, cannot fire: {t['description']}")
