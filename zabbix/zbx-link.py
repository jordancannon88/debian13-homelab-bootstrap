#!/usr/bin/env python3
"""zbx-link.py: link a template to hosts, without the interface.

Linking is the step that turns an imported template into monitoring, and it is
easy to do to the wrong hosts or to forget on one. This prints exactly what it
would change and changes nothing until --apply.

  python3 zbx-link.py 'Homelab drives' pve0 pve1            what would change
  python3 zbx-link.py 'Homelab drives' pve0 pve1 --apply    link them
  python3 zbx-link.py 'Homelab drives' --unlink pve0        unlink, keeping items
  python3 zbx-link.py 'Homelab drives' --unlink-clear pve0  unlink and delete items

host.update replaces a host's template list rather than adding to it, so the
current list is read first and the change applied to that. Writing the new
template alone would silently unlink everything else on the host.

--unlink leaves the items behind as host-level copies, which is how the fleet
grew stray items before; --unlink-clear removes them. Prefer --unlink-clear
unless the history is wanted.

Needs host.get, template.get and host.update on the API role. Run from a machine
that can reach the frontend (the laptop; the dev box is firewalled off).
"""
import json, os, sys, urllib.request

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


flags = {a for a in sys.argv[1:] if a.startswith("--")}
args = [a for a in sys.argv[1:] if not a.startswith("--")]
if len(args) < 2:
    raise SystemExit(__doc__)
tname, hostnames = args[0], args[1:]
apply_it = "--apply" in flags
unlink = "--unlink" in flags or "--unlink-clear" in flags
clear = "--unlink-clear" in flags

tpl = api("template.get", {"output": ["templateid", "host"], "filter": {"host": [tname]}})
if not tpl:
    tpl = api("template.get", {"output": ["templateid", "host"], "search": {"host": tname}})
if len(tpl) != 1:
    raise SystemExit(f"{tname}: matched {len(tpl)} templates, name it exactly")
tid, tlabel = tpl[0]["templateid"], tpl[0]["host"]

hosts = api("host.get", {"output": ["hostid", "host"], "filter": {"host": hostnames},
                         "selectParentTemplates": ["templateid", "host"]})
missing = sorted(set(hostnames) - {h["host"] for h in hosts})
for m in missing:
    print(f"  {m:<16} NOT A HOST, skipped")

changes = []
for h in sorted(hosts, key=lambda h: h["host"]):
    cur = {t["templateid"]: t["host"] for t in h.get("parentTemplates", [])}
    if unlink:
        if tid not in cur:
            print(f"  {h['host']:<16} not linked, nothing to do")
            continue
        print(f"  {h['host']:<16} UNLINK{' and clear' if clear else ''} {tlabel}")
    else:
        if tid in cur:
            print(f"  {h['host']:<16} already linked")
            continue
        print(f"  {h['host']:<16} link {tlabel}   (keeps {len(cur)} existing)")
    changes.append((h, cur))

if not changes:
    print("\nnothing to do")
    raise SystemExit(0)
if not apply_it:
    print(f"\n{len(changes)} host(s) would change. Re-run with --apply to do it.")
    raise SystemExit(0)

for h, cur in changes:
    if unlink:
        key = "templates_clear" if clear else "templates"
        if clear:
            api("host.update", {"hostid": h["hostid"], "templates_clear": [{"templateid": tid}]})
        else:
            keep = [{"templateid": t} for t in cur if t != tid]
            api("host.update", {"hostid": h["hostid"], "templates": keep})
    else:
        keep = [{"templateid": t} for t in cur] + [{"templateid": tid}]
        api("host.update", {"hostid": h["hostid"], "templates": keep})
    print(f"  {h['host']:<16} done")
print(f"\n{len(changes)} host(s) changed.")
