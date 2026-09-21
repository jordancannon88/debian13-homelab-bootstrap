#!/usr/bin/env python3
"""zbx-item.py: what is this item, and does anything alert on it?

Written because the five CPU temperature gauges on the Homelab dashboard reference
items by numeric id, which says nothing about what they measure, and because a
dashboard colour is not monitoring: a red gauge warns whoever happens to be looking
at it. Before writing a trigger for a metric, you need the item's real key, its
units and whether a trigger already exists.

  python3 zbx-item.py 59480 55544 50816        by item id
  python3 zbx-item.py --key cpu_temp           by key substring, any host
  python3 zbx-item.py --name 'Temperature'     by visible name substring

For each item it prints the host, key, name, units, value type, last value with its
age, and every trigger whose expression references it. "no triggers" means nothing
alerts on that metric, whatever the dashboard shows.

Read-only. Run it from a machine that can reach the Zabbix frontend (the laptop; the
dev box is firewalled off). Needs the token in ~/.config/zabbix/token and the
methods item.get and trigger.get on the API role.
"""
import json, os, sys, time, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))
VTYPE = {"0": "float", "1": "character", "2": "log", "3": "unsigned", "4": "text"}


def api(method, params):
    tok = open(TOKEN_FILE).readline().strip()
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(URL, data=body, headers={
        "Content-Type": "application/json-rpc", "Authorization": f"Bearer {tok}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.loads(r.read())
    if "error" in out:
        raise SystemExit(f"{method}: {out['error'].get('data') or out['error']}")
    return out["result"]


def ago(clock):
    try:
        d = int(time.time()) - int(clock)
    except (TypeError, ValueError):
        return "never"
    if d < 90:
        return f"{d}s ago"
    if d < 5400:
        return f"{d // 60}m ago"
    return f"{d / 3600:.1f}h ago"


a = sys.argv[1:]
if not a:
    raise SystemExit(__doc__)

out = ["itemid", "key_", "name", "units", "value_type", "lastvalue", "lastclock",
       "state", "error", "status"]
if a[0] == "--key":
    params = {"output": out, "search": {"key_": a[1]}, "selectHosts": ["host"]}
elif a[0] == "--name":
    params = {"output": out, "search": {"name": a[1]}, "selectHosts": ["host"]}
else:
    params = {"output": out, "itemids": a, "selectHosts": ["host"]}

items = api("item.get", params)
if not items:
    raise SystemExit("no items matched")

for it in sorted(items, key=lambda i: (i["hosts"][0]["host"] if i.get("hosts") else "",
                                       i["key_"])):
    host = it["hosts"][0]["host"] if it.get("hosts") else "?"
    print(f"\n{host}  itemid {it['itemid']}")
    print(f"  key        {it['key_']}")
    print(f"  name       {it['name']}")
    print(f"  units      {it.get('units') or '(none)'}   type {VTYPE.get(it.get('value_type'), '?')}")
    flags = []
    if it.get("state") == "1":
        flags.append("UNSUPPORTED")
    if it.get("status") == "1":
        flags.append("item DISABLED")
    print(f"  last value {it.get('lastvalue')}  {ago(it.get('lastclock'))}"
          + (f"   [{', '.join(flags)}]" if flags else ""))
    if it.get("error"):
        print(f"  error      {it['error']}")

    trigs = api("trigger.get", {"itemids": [it["itemid"]],
                                "output": ["description", "priority", "status", "value"],
                                "expandDescription": True, "expandExpression": True,
                                "selectFunctions": "extend"})
    if not trigs:
        print("  triggers   NONE. Nothing alerts on this metric.")
    for t in trigs:
        state = "PROBLEM" if t.get("value") == "1" else "ok"
        dis = ", DISABLED" if t.get("status") == "1" else ""
        print(f"  trigger    [{t['priority']}] {t['description']}  ({state}{dis})")
