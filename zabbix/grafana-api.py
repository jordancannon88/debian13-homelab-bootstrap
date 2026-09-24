#!/usr/bin/env python3
"""grafana-api.py: Grafana from files, the way zbx-import.sh and zbx-dashboard.py
handle Zabbix. Every dashboard and data source is a JSON file in the repository and
reaches Grafana only through its API, so what is live can always be reviewed,
diffed and rebuilt. Kan x79x4lcj9dqt.

Layout under zabbix/grafana/:
  dashboards/<Folder name>/<name>.json   one dashboard; its folder is the directory
  datasources/<name>.json                one data source; secrets by placeholder

Dashboards
  grafana-api.py diff     [dir]           what put-all would change, per dashboard
  grafana-api.py put-all  [dir] [--apply] create folders and dashboards that differ
  grafana-api.py put      <file> [--apply]
  grafana-api.py get      <uid> <file>    save a live dashboard to a file
  grafana-api.py get-all  [dir]           save every dashboard in the managed folders
  grafana-api.py check    <file|dir>      run every panel's queries, report rows

Data sources (need the admin token, decision D2)
  grafana-api.py ds-list
  grafana-api.py ds-get   <uid> <file>
  grafana-api.py ds-put   <file> [--apply]

Writes are a dry run unless --apply is given. Nothing is ever deleted: a dashboard
removed from the repository stays in Grafana until someone removes it by hand.

Placeholders, resolved at put and check time so files hold no server-specific ids:
  ${DS_INFINITY}, ${DS_ZABBIX}, ${DS_LOKI}   the uid of the one data source of that type
  ${SECRET:name}                             ~/.config/grafana/secrets/<name>, data sources only

Tokens: ~/.config/grafana/token (service account claude, Editor) for dashboards;
~/.config/grafana/admin-token (claude-admin, Admin) for data sources only.
GRAFANA_URL overrides http://grf.internal.cannon.dev:3000, Grafana direct rather
than through NPM. Run on the laptop.
"""
import difflib, json, os, re, sys, time, urllib.error, urllib.request

URL = os.environ.get("GRAFANA_URL", "http://grf.internal.cannon.dev:3000").rstrip("/")
CONF = os.path.expanduser("~/.config/grafana")
DEFAULT_DIR = "zabbix/grafana"
TYPES = {"DS_INFINITY": "yesoreyeram-infinity-datasource",
         "DS_ZABBIX": "alexanderzobnin-zabbix-datasource",
         "DS_LOKI": "loki"}
# Fields Grafana owns or rewrites on every save. Comparing them would report a
# change on every run.
VOLATILE = {"id", "version", "iteration", "pluginVersion"}
# Query types that only run in the browser. The Zabbix plugin handles numeric
# queries (type 0) on the server; its text, problems and other modes return
# "non-metrics queries are not supported" through the API, so check says so
# instead of calling them broken.
BROWSER_ONLY = {"alexanderzobnin-zabbix-datasource": lambda t: str(t.get("queryType", "0")) != "0"}

APPLY = "--apply" in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]


def token(admin=False):
    path = os.path.join(CONF, "admin-token" if admin else "token")
    try:
        return open(path).readline().strip()
    except OSError:
        raise SystemExit(f"no token at {path}")


def call(path, body=None, method=None, admin=False, ok404=False):
    req = urllib.request.Request(
        URL + path, data=json.dumps(body).encode() if body is not None else None,
        method=method, headers={"Authorization": f"Bearer {token(admin)}",
                                "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or "null")
    except urllib.error.HTTPError as e:
        if ok404 and e.code == 404:
            return None
        raise SystemExit(f"{method or ('POST' if body is not None else 'GET')} {path}: "
                         f"HTTP {e.code}: {e.read().decode()[:600]}")


_ds_cache = None


def datasources():
    global _ds_cache
    if _ds_cache is None:
        # Frontend settings list every data source with uid and type for any signed-in
        # account; /api/datasources would need Admin.
        _ds_cache = list(call("/api/frontend/settings").get("datasources", {}).values())
    return _ds_cache


def resolve(text, secrets="forbid"):
    """Swap placeholders for real values. Data source uids always; secrets per mode:
    "forbid" for dashboards, which must never hold one, "keep" for a data source dry
    run, which shows the placeholder rather than the value, and "resolve" for a data
    source write."""
    def ds(m):
        t = TYPES.get(m.group(1))
        found = [d for d in datasources() if d.get("type") == t]
        if len(found) != 1:
            raise SystemExit(f"${{{m.group(1)}}}: {len(found)} data sources of type {t}, need exactly 1")
        return found[0]["uid"]
    text = re.sub(r"\$\{(DS_[A-Z]+)\}", ds, text)
    if secrets == "resolve":
        def sec(m):
            p = os.path.join(CONF, "secrets", m.group(1))
            try:
                return open(p).readline().strip()
            except OSError:
                raise SystemExit(f"${{SECRET:{m.group(1)}}}: no file {p}")
        text = re.sub(r"\$\{SECRET:([A-Za-z0-9_.-]+)\}", sec, text)
    elif secrets == "forbid" and "${SECRET:" in text:
        raise SystemExit("secrets are only allowed in data source files")
    return text


def unresolve(text):
    for name, t in TYPES.items():
        for d in datasources():
            if d.get("type") == t:
                text = text.replace(f'"{d["uid"]}"', f'"${{{name}}}"')
    return text


def strip(obj):
    """Drop fields Grafana owns, at every depth, for comparison."""
    if isinstance(obj, dict):
        return {k: strip(v) for k, v in obj.items() if k not in VOLATILE}
    if isinstance(obj, list):
        return [strip(v) for v in obj]
    return obj


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


# ---- dashboards ------------------------------------------------------------------

def dash_files(root):
    base = os.path.join(root, "dashboards")
    if os.path.isfile(root):
        return [(os.path.basename(os.path.dirname(root)), root)]
    out = []
    for folder in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        fdir = os.path.join(base, folder)
        if os.path.isdir(fdir):
            out += [(folder, os.path.join(fdir, f)) for f in sorted(os.listdir(fdir))
                    if f.endswith(".json")]
    return out


def load_dash(path):
    d = json.loads(resolve(open(path).read()))
    if not d.get("uid"):
        raise SystemExit(f"{path}: no uid; every managed dashboard carries a fixed uid")
    return d


def live_dash(uid):
    r = call(f"/api/dashboards/uid/{uid}", ok404=True)
    return (r["dashboard"], r.get("meta", {})) if r else (None, {})


def folder_uid(title, create):
    for f in call("/api/folders?limit=1000") or []:
        if f.get("title") == title:
            return f["uid"]
    if not create:
        return None
    uid = f"homelab-{slug(title)}" if slug(title) != "homelab" else "homelab"
    r = call("/api/folders", {"uid": uid, "title": title})
    print(f"  folder {title!r} created (uid {r['uid']})")
    return r["uid"]


def compare(folder, path):
    want = load_dash(path)
    have, meta = live_dash(want["uid"])
    a = json.dumps(strip(want), indent=1, sort_keys=True).splitlines()
    b = json.dumps(strip(have), indent=1, sort_keys=True).splitlines() if have else []
    moved = have is not None and meta.get("folderTitle") not in (folder, None)
    return want, have, meta, a, b, moved


def cmd_diff(root, show=True):
    changes = []
    for folder, path in dash_files(root):
        want, have, meta, a, b, moved = compare(folder, path)
        name = f"{folder}/{os.path.basename(path)}"
        if have is None:
            print(f"  NEW      {name}  uid {want['uid']}")
            changes.append((folder, path, want))
        elif a != b or moved:
            d = [l for l in difflib.unified_diff(b, a, "live", "file", lineterm="", n=1)]
            n = sum(1 for l in d if l[:1] in "+-" and l[:3] not in ("+++", "---"))
            where = f", folder {meta.get('folderTitle')!r} -> {folder!r}" if moved else ""
            print(f"  CHANGED  {name}  {n} line(s){where}")
            if show and "--full" in sys.argv:
                print("\n".join(d))
            changes.append((folder, path, want))
        else:
            print(f"  same     {name}")
    return changes


def cmd_put_all(root):
    changes = cmd_diff(root, show=False)
    if not changes:
        print("nothing to do")
        return
    if not APPLY:
        print(f"\n{len(changes)} dashboard(s) would change. Re-run with --apply.")
        return
    for folder, path, want in changes:
        fuid = folder_uid(folder, create=True)
        want.pop("id", None)
        r = call("/api/dashboards/db", {"dashboard": want, "folderUid": fuid, "overwrite": True,
                                        "message": f"grafana-api.py {os.path.basename(path)}"})
        print(f"  {r.get('status')}: {folder}/{os.path.basename(path)} -> {URL}{r.get('url')} "
              f"(version {r.get('version')})")


def cmd_get(uid, path):
    have, meta = live_dash(uid)
    if not have:
        raise SystemExit(f"no dashboard {uid}")
    for k in VOLATILE - {"pluginVersion"}:
        have.pop(k, None)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    open(path, "w").write(unresolve(json.dumps(have, indent=2)) + "\n")
    print(f"  saved {uid} ({meta.get('folderTitle', 'General')}) -> {path}")


def cmd_get_all(root):
    managed = {folder for folder, _ in dash_files(root)} or {"Homelab"}
    for hit in call("/api/search?type=dash-db&limit=5000") or []:
        folder = hit.get("folderTitle") or "General"
        if folder in managed:
            cmd_get(hit["uid"], os.path.join(root, "dashboards", folder, slug(hit["title"]) + ".json"))


def cmd_check(target):
    files = [p for _, p in dash_files(target)] if os.path.isdir(target) else [target]
    now = int(time.time() * 1000)
    for path in files:
        d = load_dash(path)
        print(f"{os.path.basename(path)} ({d.get('title')})")
        panels = []
        for p in d.get("panels", []):
            panels += p.get("panels", []) if p.get("type") == "row" else [p]
        for p in panels:
            server, browser = [], []
            for t in p.get("targets", []):
                ds = (t.get("datasource") or p.get("datasource") or {})
                t = {**t, "datasource": ds}
                (browser if BROWSER_ONLY.get(ds.get("type"), lambda _t: False)(t) else server).append(t)
            if browser:
                print(f"  {p.get('title')!r}: {len(browser)} browser-only quer{'y' if len(browser) == 1 else 'ies'}, check by eye")
            if not server:
                continue
            res = call("/api/ds/query", {"from": str(now - 3600000), "to": str(now), "queries": server})
            for ref, r in (res or {}).get("results", {}).items():
                if r.get("error"):
                    print(f"  {p.get('title')!r} {ref}: ERROR {r['error']}")
                    continue
                rows = sum(len(fr["data"]["values"][0]) if fr.get("data", {}).get("values") else 0
                           for fr in r.get("frames", []))
                flag = "" if rows else "   <- no data"
                print(f"  {p.get('title')!r} {ref}: {len(r.get('frames', []))} frame(s), {rows} row(s){flag}")


# ---- data sources ----------------------------------------------------------------

DS_OWNED = {"id", "orgId", "version", "readOnly", "secureJsonFields", "typeLogoUrl"}


def cmd_ds_list():
    for d in call("/api/datasources", admin=True):
        print(f"  {d['uid']:<16} {d['type']:<36} {d['name']}{'  (default)' if d.get('isDefault') else ''}")


def cmd_ds_get(uid, path):
    d = call(f"/api/datasources/uid/{uid}", admin=True)
    # Grafana never returns secrets, only which ones are set. Read that list before
    # the owned fields are stripped; the file then names where each secret comes from.
    names = sorted(k for k, v in (d.get("secureJsonFields") or {}).items() if v)
    for k in DS_OWNED:
        d.pop(k, None)
    if names:
        d["secureJsonData"] = {n: f"${{SECRET:{slug(d['name'])}-{n}}}" for n in names}
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    open(path, "w").write(json.dumps(d, indent=2) + "\n")
    print(f"  saved data source {d['name']!r} -> {path}")
    if names:
        print(f"  secrets referenced, never saved: {', '.join(names)}")


def cmd_ds_put(path):
    raw = open(path).read()
    want = json.loads(resolve(raw, secrets="resolve" if APPLY else "keep"))
    have = call(f"/api/datasources/uid/{want['uid']}", admin=True, ok404=True)
    shown = {k: v for k, v in want.items() if k != "secureJsonData"}
    before = {k: v for k, v in (have or {}).items() if k not in DS_OWNED}
    a = json.dumps(shown, indent=1, sort_keys=True).splitlines()
    b = json.dumps(before, indent=1, sort_keys=True).splitlines()
    print("\n".join(difflib.unified_diff(b, a, "live", "file", lineterm="", n=1)) or "  no change outside secrets")
    if want.get("secureJsonData"):
        print(f"  secrets that would be written: {', '.join(sorted(want['secureJsonData']))}")
    if not APPLY:
        print("dry run. Re-run with --apply.")
        return
    if have:
        r = call(f"/api/datasources/uid/{want['uid']}", want, method="PUT", admin=True)
    else:
        r = call("/api/datasources", want, admin=True)
    print(f"  {r.get('message', 'done')}: {want['name']}")


def main():
    if not ARGS:
        raise SystemExit(__doc__)
    cmd, rest = ARGS[0], ARGS[1:]
    root = rest[0] if rest else DEFAULT_DIR
    if cmd == "diff":
        cmd_diff(root)
    elif cmd == "put-all":
        cmd_put_all(root)
    elif cmd == "put" and rest:
        cmd_put_all(rest[0])
    elif cmd == "get" and len(rest) == 2:
        cmd_get(*rest)
    elif cmd == "get-all":
        cmd_get_all(root)
    elif cmd == "check" and rest:
        cmd_check(rest[0])
    elif cmd == "ds-list":
        cmd_ds_list()
    elif cmd == "ds-get" and len(rest) == 2:
        cmd_ds_get(*rest)
    elif cmd == "ds-put" and rest:
        cmd_ds_put(rest[0])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
