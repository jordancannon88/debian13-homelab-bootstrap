#!/usr/bin/env python3
"""zbx-host-macro.py: read or set one user macro on one Zabbix host.

  python3 zbx-host-macro.py pms0                                   # list the host's macros
  python3 zbx-host-macro.py pms0 '{$LOAD_AVG_PER_CPU.MAX.WARN}' 4  # create or update

Used for per-host threshold overrides that are not worth a template, e.g. the
NAS VM whose nightly snapraid sync and scrub push load past the stock 1.5 per
CPU. Role needs host.get, usermacro.get, usermacro.create, usermacro.update.
"""
import json, os, sys, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))

def api(method, params):
    tok = open(TOKEN_FILE).readline().strip()
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(URL, data=body, headers={
        "Content-Type": "application/json-rpc", "Authorization": f"Bearer {tok}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.loads(r.read())
    if "error" in out:
        raise SystemExit(f"{method}: {out['error'].get('data') or out['error']}")
    return out["result"]

def main():
    if len(sys.argv) not in (2, 4):
        raise SystemExit(__doc__)
    host = sys.argv[1]
    hosts = api("host.get", {"output": ["hostid", "host"], "filter": {"host": [host]}})
    if not hosts:
        raise SystemExit(f"host {host} not found")
    hid = hosts[0]["hostid"]
    macros = api("usermacro.get", {"output": ["hostmacroid", "macro", "value"], "hostids": hid})
    if len(sys.argv) == 2:
        for m in sorted(macros, key=lambda m: m["macro"]):
            print(f"{m['macro']} = {m['value']}")
        return
    macro, value = sys.argv[2], sys.argv[3]
    cur = next((m for m in macros if m["macro"] == macro), None)
    if cur and cur["value"] == value:
        print(f"{host}: {macro} already {value}")
    elif cur:
        api("usermacro.update", {"hostmacroid": cur["hostmacroid"], "value": value})
        print(f"{host}: {macro} {cur['value']} -> {value}")
    else:
        api("usermacro.create", {"hostid": hid, "macro": macro, "value": value})
        print(f"{host}: {macro} created = {value}")

if __name__ == "__main__":
    main()
