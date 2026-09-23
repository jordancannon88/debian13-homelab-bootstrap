#!/usr/bin/env python3
"""grafana-probe.py: run one query through a Grafana data source and show exactly
what comes back, so a panel's transformations are built against real frames
instead of guesses. Read-only: it only calls /api/frontend/settings and
/api/ds/query.

Written for the per-drive table (Kan bfrdv9wpggve), which pivots Zabbix items on
their `drive` and `fact` tags; how the Zabbix plugin names and labels its frames
decides how that pivot has to be built.

  python3 grafana-probe.py                          both default probes on pve2
  python3 grafana-probe.py --host '/^pms0$/'        another host (Zabbix plugin regex)
  python3 grafana-probe.py --tag 'fact: wait'       another item tag filter
  python3 grafana-probe.py --raw                    dump the full JSON response
  python3 grafana-probe.py --infinity               the drive table through Infinity:
                                                    item.get, then pivoted to a row per
                                                    drive on Grafana's side

Token in ~/.config/grafana/token (service account `claude`, role Editor).
GRAFANA_URL overrides https://grafana.local.cannon.dev. Run on the laptop; the dev
box cannot reach Grafana.
"""
import json, os, sys, time, urllib.request

URL = os.environ.get("GRAFANA_URL", "https://grafana.local.cannon.dev").rstrip("/")
TOKEN = open(os.path.expanduser("~/.config/grafana/token")).readline().strip()
PLUGIN = "alexanderzobnin-zabbix-datasource"


def call(path, body=None):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {TOKEN}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{path}: HTTP {e.code}: {e.read().decode()[:400]}")


def opt(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


INFINITY = "yesoreyeram-infinity-datasource"
ZABBIX_API = "http://zabbix.internal.cannon.dev/api_jsonrpc.php"

# Every drive item on a monitored, enabled host. Items discovery has marked lost
# (virtual disks since the filter, drives moved away) are disabled, so status 0
# drops them. The `fact` tag exists only on drive items, which is the filter.
ITEM_GET = {"jsonrpc": "2.0", "method": "item.get", "id": 1, "params": {
    "output": ["name", "key_", "lastvalue", "units"],
    "selectHosts": ["host"], "selectTags": "extend", "monitored": True,
    "filter": {"status": "0"},
    "tags": [{"tag": "fact", "operator": "4"}]}}

# Group every item by its drive tag, then turn each group into one object whose
# keys are the fact tags: one row per drive and one column per fact, built on
# Grafana's server so the panel needs no pivot of its own.
PIVOT = """$each(result{tags[tag="drive"].value: $}, function($items, $drive) {
  $merge([{"drive": $drive, "host": $items[0].hosts[0].host},
          $items{tags[tag="fact"].value: lastvalue}])
})"""


def infinity(settings, root, label):
    ids = [d for d in settings.get("datasources", {}).values() if d.get("type") == INFINITY]
    if not ids:
        raise SystemExit("no Infinity data source visible to this token")
    q = {"refId": "A", "datasource": {"type": INFINITY, "uid": ids[0]["uid"]},
         "type": "json", "source": "url", "format": "table", "parser": "backend",
         "url": ZABBIX_API,
         "url_options": {"method": "POST", "body_type": "raw",
                         "body_content_type": "application/json",
                         "data": json.dumps(ITEM_GET)},
         "root_selector": root, "columns": []}
    now = int(time.time() * 1000)
    res = call("/api/ds/query", {"from": str(now - 3600000), "to": str(now), "queries": [q]})
    r = res.get("results", {}).get("A", {})
    print(f"\n=== Infinity, {label} ===")
    if r.get("error"):
        print("  ERROR:", r["error"])
    for fr in r.get("frames", []):
        fields = [f.get("name") for f in fr.get("schema", {}).get("fields", [])]
        vals = fr.get("data", {}).get("values", [])
        rows = len(vals[0]) if vals else 0
        print(f"  {rows} row(s), {len(fields)} column(s): {fields}")
        for i in range(min(rows, 3)):
            print("   ", {fields[j]: vals[j][i] for j in range(len(fields))})
    if "--raw" in sys.argv:
        print(json.dumps(res, indent=1)[:4000])


# The data source list needs admin rights; frontend settings carry the same uid and
# type for any signed-in account, including an Editor service account.
settings = call("/api/frontend/settings")
if "--infinity" in sys.argv:
    infinity(settings, "result", "flat, one row per item")
    infinity(settings, PIVOT, "pivoted, one row per drive")
    raise SystemExit(0)
ds = [d for d in settings.get("datasources", {}).values()
      if d.get("type") == PLUGIN]
if not ds:
    raise SystemExit("no Zabbix data source visible to this token")
ds = ds[0]
print(f"data source: {ds.get('name')}  uid={ds.get('uid')}")

host = opt("--host", "/^pve2$/")
now = int(time.time() * 1000)


def query(ref, query_type, tag):
    q = {"refId": ref, "datasource": {"type": PLUGIN, "uid": ds["uid"]},
         "queryType": query_type,
         "group": {"filter": "/.*/"}, "host": {"filter": host},
         "itemTag": {"filter": tag}, "item": {"filter": "/.*/"},
         "functions": [],
         "options": {"showDisabledItems": False, "skipEmptyValues": False,
                     "disableDataAlignment": False, "useZabbixValueMapping": False}}
    return call("/api/ds/query", {"from": str(now - 15 * 60 * 1000), "to": str(now),
                                  "queries": [q]})


probes = [("metrics", "0", opt("--tag", "fact: busy")),
          ("text", "2", opt("--text-tag", "fact: link"))]
for label, qt, tag in probes:
    print(f"\n=== {label} query (queryType {qt}), host {host}, itemTag '{tag}' ===")
    res = query("A", qt, tag)
    if "--raw" in sys.argv:
        print(json.dumps(res, indent=1)[:6000])
        continue
    r = res.get("results", {}).get("A", {})
    if r.get("error"):
        print("  ERROR:", r["error"])
    frames = r.get("frames", [])
    print(f"  {len(frames)} frame(s)")
    for fr in frames[:6]:
        sch, vals = fr.get("schema", {}), fr.get("data", {}).get("values", [])
        print(f"  frame name={sch.get('name')!r}")
        for i, f in enumerate(sch.get("fields", [])):
            last = vals[i][-1] if i < len(vals) and vals[i] else None
            cfg = f.get("config", {})
            print(f"    field {f.get('name')!r} type={f.get('type')} labels={f.get('labels')} "
                  f"display={cfg.get('displayNameFromDS') or cfg.get('displayName')!r} last={last!r}")
