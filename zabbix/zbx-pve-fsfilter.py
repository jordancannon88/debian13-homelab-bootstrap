#!/usr/bin/env python3
"""zbx-pve-fsfilter.py: on every host that has the "Homelab PVE guest volumes"
template linked (the PVE nodes), set the stock Linux template's filesystem
filter so its discovery ignores guest volumes (subvol-* datasets under the
ZFS pools). The Homelab template covers those, live copies only, named after
the guest (card 2rk32ec9faxf). Idempotent. Role needs host.get, usermacro.*.

  python3 zbx-pve-fsfilter.py --dry-run
  python3 zbx-pve-fsfilter.py
"""
import json, os, sys, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))
DRY = "--dry-run" in sys.argv
TEMPLATE = "Homelab PVE guest volumes"
MACRO = "{$VFS.FS.FSNAME.NOT_MATCHES}"
# stock default plus the guest volumes
VALUE = "^(/dev|/sys|/run|/proc|.+/shm$|/(local-zfs-[a-z]+|rpool/data)/subvol-.*)"

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
    tpl = api("template.get", {"output": ["templateid"], "filter": {"name": [TEMPLATE]}})
    if not tpl:
        raise SystemExit(f"template '{TEMPLATE}' not found (import it first)")
    hosts = api("host.get", {"output": ["hostid", "host"], "templateids": tpl[0]["templateid"],
                             "selectMacros": ["hostmacroid", "macro", "value"]})
    if not hosts:
        print("no host has the template linked yet"); return
    changes = 0
    for h in sorted(hosts, key=lambda x: x["host"]):
        have = {m["macro"]: m for m in h.get("macros", [])}
        if MACRO in have and have[MACRO]["value"] == VALUE:
            print(f"{h['host']}: already set")
        elif MACRO in have:
            print(f"{h['host']}: update {MACRO}"); changes += 1
            DRY or api("usermacro.update", {"hostmacroid": have[MACRO]["hostmacroid"], "value": VALUE})
        else:
            print(f"{h['host']}: add {MACRO}"); changes += 1
            DRY or api("usermacro.create", {"hostid": h["hostid"], "macro": MACRO, "value": VALUE})
    print(f"hosts={len(hosts)} {'planned' if DRY else 'applied'} changes={changes}")
    print("Note: the stock discovery drops the subvol items on its next run (up to 1 h); lost items are disabled immediately.")

if __name__ == "__main__":
    main()
