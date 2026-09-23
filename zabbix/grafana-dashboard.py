#!/usr/bin/env python3
"""grafana-dashboard.py: put a Grafana dashboard from a file, and take one back.

The Grafana twin of zbx-dashboard.py: a dashboard built in the interface exists
only in Grafana's database, so it is kept as a file in the repository and written
back from there. Data sources are referenced by placeholder, ${DS_INFINITY} or
${DS_ZABBIX}, and resolved to this Grafana's uids at put time, so the file does not
hard-code an id that means nothing on a rebuilt server.

  python3 grafana-dashboard.py put <file>        create or replace, by the file's uid
  python3 grafana-dashboard.py get <uid> <file>  save the live dashboard to a file
  python3 grafana-dashboard.py check <file>      run every panel's queries, report rows

Token in ~/.config/grafana/token (service account `claude`, role Editor).
GRAFANA_URL overrides http://grf.internal.cannon.dev:3000, which is Grafana direct;
the public name goes through NPM. Run on the laptop.
"""
import json, os, re, sys, time, urllib.request

URL = os.environ.get("GRAFANA_URL", "http://grf.internal.cannon.dev:3000").rstrip("/")
TOKEN = open(os.path.expanduser("~/.config/grafana/token")).readline().strip()
TYPES = {"DS_INFINITY": "yesoreyeram-infinity-datasource",
         "DS_ZABBIX": "alexanderzobnin-zabbix-datasource"}


def call(path, body=None, method=None):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode() if body else None,
                                 method=method, headers={"Authorization": f"Bearer {TOKEN}",
                                                         "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{path}: HTTP {e.code}: {e.read().decode()[:600]}")


def resolve(text):
    have = {d.get("type"): d.get("uid") for d in
            call("/api/frontend/settings").get("datasources", {}).values()}
    def sub(m):
        t = TYPES.get(m.group(1))
        if not t or t not in have:
            raise SystemExit(f"no data source of type {t} for ${{{m.group(1)}}}")
        return have[t]
    return re.sub(r"\$\{(DS_[A-Z]+)\}", sub, text)


a = sys.argv[1:]
if not a:
    raise SystemExit(__doc__)
if a[0] == "put" and len(a) == 2:
    dash = json.loads(resolve(open(a[1]).read()))
    dash.pop("id", None)
    r = call("/api/dashboards/db", {"dashboard": dash, "overwrite": True,
                                    "message": "grafana-dashboard.py put"})
    print(f"{r.get('status')}: {URL}{r.get('url')}  (version {r.get('version')})")
elif a[0] == "get" and len(a) == 3:
    d = call(f"/api/dashboards/uid/{a[1]}")["dashboard"]
    for k in ("id", "version"):
        d.pop(k, None)
    text = json.dumps(d, indent=2)
    for name, t in TYPES.items():
        for ds in call("/api/frontend/settings").get("datasources", {}).values():
            if ds.get("type") == t:
                text = text.replace(f'"{ds["uid"]}"', f'"${{{name}}}"')
    open(a[2], "w").write(text + "\n")
    print(f"saved {a[1]} to {a[2]}")
elif a[0] == "check" and len(a) == 2:
    dash = json.loads(resolve(open(a[1]).read()))
    now = int(time.time() * 1000)
    for p in dash.get("panels", []):
        res = call("/api/ds/query", {"from": str(now - 3600000), "to": str(now),
                                     "queries": p.get("targets", [])})
        for ref, r in res.get("results", {}).items():
            if r.get("error"):
                print(f"  {p['title']}: ERROR {r['error']}")
            for fr in r.get("frames", []):
                fields = [f.get("name") for f in fr["schema"]["fields"]]
                vals = fr["data"]["values"]
                rows = len(vals[0]) if vals else 0
                print(f"  {p['title']}: {rows} rows, columns {fields}")
                for i in range(rows):
                    print("     ", " | ".join(str(vals[j][i]) for j in range(len(fields))))
else:
    raise SystemExit(__doc__)
