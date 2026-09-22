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
  python3 zbx-item.py --groups                 host groups, with ids and host counts
  python3 zbx-item.py --hosts                  every host with its id
  python3 zbx-item.py --hosts pve              only hosts whose name contains pve
  python3 zbx-item.py --name X --host pve2     restrict to one host
  python3 zbx-item.py --name X --brief         one line per item, no trigger lookup

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


a = [x for x in sys.argv[1:] if not x.startswith("--")]
opts = sys.argv[1:]
brief = "--brief" in opts
host_filter = None
if "--host" in opts:
    i = opts.index("--host")
    host_filter = opts[i + 1] if i + 1 < len(opts) else None
    if host_filter in a:
        a.remove(host_filter)

if "--hosts" in opts:
    # A Top hosts widget filters by host ID, not by a name pattern: a "hosts.0"
    # field holding "pve*" is accepted by the API, ignored by the widget, and the
    # host group ends up doing all the filtering. That cost an afternoon on
    # 2026-09-22, when adding the VMs group to the drives table pulled in dev, dkr
    # and net as well. So the ids have to be looked up, and the interface only ever
    # shows names.
    hs = api("host.get", {"output": ["hostid", "host", "status"]})
    if a:
        hs = [h for h in hs if a[0].lower() in h["host"].lower()]
    for h in sorted(hs, key=lambda h: h["host"]):
        off = "   [host DISABLED]" if h.get("status") == "1" else ""
        print(f"  {h['hostid']:>6}  {h['host']}{off}")
    print(f"\n{len(hs)} host(s)")
    raise SystemExit(0)

if "--groups" in opts:
    # Dashboard widgets address hosts by group id, so the id is what you need and
    # the interface only shows the name.
    groups = api("hostgroup.get", {"output": ["groupid", "name"],
                                   "selectHosts": ["host"]})
    for g in sorted(groups, key=lambda g: g["name"]):
        hs = sorted(h["host"] for h in g.get("hosts", []))
        if not hs:
            continue
        print(f"  {g['groupid']:>3}  {g['name']:<28} {len(hs):>3}  {', '.join(hs)}")
    raise SystemExit(0)

if not a:
    raise SystemExit(__doc__)

out = ["itemid", "key_", "name", "units", "value_type", "lastvalue", "lastclock",
       "state", "error", "status"]
# `a` holds only the positional arguments, so the search mode is read from the flags.
if "--key" in opts:
    params = {"output": out, "search": {"key_": a[0]}, "selectHosts": ["host"]}
elif "--name" in opts:
    params = {"output": out, "search": {"name": a[0]}, "selectHosts": ["host"]}
else:
    params = {"output": out, "itemids": a, "selectHosts": ["host"]}

if host_filter:
    params["host"] = host_filter
items = api("item.get", params)
if not items:
    raise SystemExit("no items matched")

if brief:
    for it in sorted(items, key=lambda i: (i["hosts"][0]["host"] if i.get("hosts") else "",
                                           i["key_"])):
        h = it["hosts"][0]["host"] if it.get("hosts") else "?"
        print(f"  {h:<16} {it['key_']:<52} {it['name']}")
    print(f"\n{len(items)} item(s)")
    raise SystemExit(0)

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
                                "output": ["description", "priority", "status", "value",
                                           "expression", "templateid", "comments"],
                                "expandDescription": True, "expandExpression": True})
    if not trigs:
        print("  triggers   NONE. Nothing alerts on this metric.")
    for t in trigs:
        state = "PROBLEM" if t.get("value") == "1" else "ok"
        dis = ", DISABLED" if t.get("status") == "1" else ""
        # templateid 0 means the trigger was made on the host by hand, so nothing
        # keeps it consistent with the same trigger on any other host.
        src = "from a template" if t.get("templateid", "0") != "0" else "host-level, by hand"
        print(f"  trigger    [{t['priority']}] {t['description']}  ({state}{dis}, {src})")
        print(f"             {t.get('expression')}")
