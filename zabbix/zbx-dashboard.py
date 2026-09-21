#!/usr/bin/env python3
"""zbx-dashboard.py: capture Zabbix dashboards to files, and put them back.

Zabbix has no import or export for global dashboards in its interface, so a
dashboard built by hand exists in one place only: the server's database. This
reads them through the API into JSON files that can live in a repository, and
writes them back when needed.

Why it matters here: on 2026-09-20 and 21 several widget columns were wrong in
ways nothing recorded. Columns aggregated with "max" over fifteen minutes held
brief spikes as standing values, so grf read 99 % memory and seafile-keeper 99 %
CPU when both were idle. The fix was to set each column to last value. Nothing
in the system says a column must be built that way, so the next person to add
one repeats the mistake. A dashboard kept as a file is reviewable, diffable and
restorable.

  python3 zbx-dashboard.py list                       what exists, with ids
  python3 zbx-dashboard.py get <name-or-id> <dir>     save one to <dir>/<slug>.json
  python3 zbx-dashboard.py get-all <dir>              save every dashboard
  python3 zbx-dashboard.py put <file>                 create or update from a file
  python3 zbx-dashboard.py diff <file>                show what would change

Reads the API token from ~/.config/zabbix/token, the same one the template
imports use. The role needs dashboard.get, and dashboard.create plus
dashboard.update for `put`.
"""
import json, os, re, sys, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))

# Fields the server owns and that must not be sent back on a write.
STRIP_DASHBOARD = {"dashboardid", "userid", "templateid", "uuid"}
STRIP_PAGE = {"dashboard_pageid", "dashboardid"}
STRIP_WIDGET = {"widgetid", "dashboard_pageid"}
STRIP_FIELD = {"widget_fieldid", "widgetid"}


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


def fetch(dashboardids=None):
    params = {"output": "extend", "selectPages": "extend", "selectUsers": "extend",
              "selectUserGroups": "extend"}
    if dashboardids:
        params["dashboardids"] = dashboardids
    return api("dashboard.get", params)


def clean(d):
    """Strip server-owned ids so the result can be written back or compared."""
    out = {k: v for k, v in d.items() if k not in STRIP_DASHBOARD}
    pages = []
    for p in d.get("pages", []):
        page = {k: v for k, v in p.items() if k not in STRIP_PAGE}
        widgets = []
        for w in p.get("widgets", []):
            widget = {k: v for k, v in w.items() if k not in STRIP_WIDGET}
            widget["fields"] = sorted(
                ({k: v for k, v in f.items() if k not in STRIP_FIELD} for f in w.get("fields", [])),
                key=lambda f: (str(f.get("name", "")), str(f.get("value", ""))))
            widgets.append(widget)
        page["widgets"] = sorted(widgets, key=lambda w: (int(w.get("y", 0)), int(w.get("x", 0))))
        pages.append(page)
    out["pages"] = pages
    return out


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "dashboard"


def main():
    a = sys.argv[1:]
    if not a:
        raise SystemExit(__doc__)
    cmd = a[0]

    if cmd == "list":
        for d in sorted(fetch(), key=lambda d: d["name"]):
            pages = len(d.get("pages", []))
            widgets = sum(len(p.get("widgets", [])) for p in d.get("pages", []))
            print(f"{d['dashboardid']:>5}  {d['name']}  ({pages} page(s), {widgets} widget(s))")

    elif cmd in ("get", "get-all"):
        if cmd == "get":
            key, outdir = a[1], a[2]
            got = [d for d in fetch() if d["name"] == key or d["dashboardid"] == key]
            if not got:
                raise SystemExit(f"no dashboard named or numbered {key!r}")
        else:
            outdir = a[1]
            got = fetch()
        os.makedirs(outdir, exist_ok=True)
        for d in got:
            path = os.path.join(outdir, slug(d["name"]) + ".json")
            body = clean(d)
            with open(path, "w") as fh:
                json.dump(body, fh, indent=2, sort_keys=True)
                fh.write("\n")
            widgets = sum(len(p["widgets"]) for p in body["pages"])
            print(f"saved {d['name']!r} -> {path} ({widgets} widgets)")

    elif cmd in ("put", "diff"):
        path = a[1]
        want = json.load(open(path))
        name = want["name"]
        existing = [d for d in fetch() if d["name"] == name]
        if cmd == "diff":
            if not existing:
                print(f"{name!r} does not exist on the server; put would create it")
                return
            import difflib
            have = json.dumps(clean(existing[0]), indent=2, sort_keys=True).splitlines()
            mine = json.dumps(want, indent=2, sort_keys=True).splitlines()
            delta = list(difflib.unified_diff(have, mine, "server", path, lineterm="", n=1))
            print("\n".join(delta) if delta else f"{name!r} matches the server")
            return
        if existing:
            want2 = dict(want)
            want2["dashboardid"] = existing[0]["dashboardid"]
            api("dashboard.update", want2)
            print(f"updated {name!r} (id {existing[0]['dashboardid']})")
        else:
            r = api("dashboard.create", want)
            print(f"created {name!r} (id {r['dashboardids'][0]})")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
