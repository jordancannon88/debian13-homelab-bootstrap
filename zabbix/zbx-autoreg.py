#!/usr/bin/env python3
"""zbx-autoreg.py: create the Zabbix autoregistration actions for the bootstrap's
HostMetadata tokens (card ujoe08opmrhs). Idempotent: an action whose name already
exists is left alone. Run on the laptop, same token as zbx-import.sh.

  python3 zbx-autoreg.py --dry-run   # print the plan, change nothing
  python3 zbx-autoreg.py             # create the missing actions

Token: ~/.config/zabbix/token (role needs action.get/create, template.get,
hostgroup.get). Endpoint: ZBX_URL or https://zabbix.local.cannon.dev/api_jsonrpc.php.

One action per token, condition "Host metadata contains <token>" (each token is
chosen so none is a substring of another). Autoregistration never unlinks or
removes anything, so re-announcing an existing host only adds what is missing.
"""
import json, os, ssl, sys, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))
DRY = "--dry-run" in sys.argv

# action key -> (token, host groups to add, templates to link, add_host)
PLAN = {
    "homelab":   ("homelab", ["Linux servers"], ["Linux by Zabbix agent active"], True),
    "homelab-psi": ("homelab", [], ["Linux IO pressure stall (PSI)"], False),
    "pve":       ("pve", ["Hypervisors"], [], False),
    "lxc":       ("lxc", ["Virtual machines"], [], False),
    "vm":        ("vm", ["Virtual machines"], [], False),
    "docker":    ("docker", ["Docker hosts"], [], False),
    "smart":     ("smart", [], ["SMART by Zabbix agent 2 active"], False),
    "zfs":       ("zfs", [], ["Homelab ZFS pools"], False),
    "snapraid":  ("snapraid", [], ["Homelab snapraid"], False),
    "events":    ("events", [], ["Homelab Proxmox events"], False),
    "nic":       ("nic", [], ["Homelab physical NIC flapping"], False),
    "tbmesh":    ("tbmesh", [], ["Homelab TB3 mesh"], False),
    "kernel":    ("kernel", [], ["Homelab kernel"], False),
    "bootcheck": ("bootcheck", [], ["Homelab boot check"], False),
    "keeper":    ("keeper", [], ["Homelab Seafile keeper"], False),
    "lxcstat":   ("lxcstat", [], ["Homelab LXC"], False),
}
NAME = "Autoreg: {key}"

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

def find_template(name):
    hits = api("template.get", {"output": ["templateid", "name"], "filter": {"name": [name]}})
    hits = hits or api("template.get", {"output": ["templateid", "name"], "filter": {"host": [name]}})
    return hits[0] if hits else None

def main():
    groups = {g["name"]: g["groupid"] for g in api("hostgroup.get", {"output": ["groupid", "name"]})}
    existing = {a["name"] for a in api("action.get", {"output": ["name"], "filter": {"eventsource": 2}})}
    created, skipped, warnings = [], [], []
    for key, (token, gnames, tnames, add_host) in PLAN.items():
        name = NAME.format(key=key)
        if name in existing:
            skipped.append(name); continue
        ops = []
        if add_host:
            ops.append({"operationtype": 2})
        gids = []
        for g in gnames:
            if g in groups: gids.append({"groupid": groups[g]})
            else: warnings.append(f"{name}: host group '{g}' not found, skipped")
        if gids:
            ops.append({"operationtype": 4, "opgroup": gids})
        tids, tres = [], []
        for t in tnames:
            hit = find_template(t)
            if hit: tids.append({"templateid": hit["templateid"]}); tres.append(hit["name"])
            else: warnings.append(f"{name}: template '{t}' not found, skipped")
        if tids:
            ops.append({"operationtype": 6, "optemplate": tids})
        if not ops:
            warnings.append(f"{name}: nothing to do, not created"); continue
        params = {"name": name, "eventsource": 2, "status": 0,
                  "filter": {"evaltype": 0, "conditions": [{"conditiontype": 24, "operator": 2, "value": token}]},
                  "operations": ops}
        desc = f"{name}: contains '{token}' -> " + ", ".join(
            (["add host"] if add_host else []) + [f"group {g}" for g in gnames if g in groups] + [f"link {t}" for t in tres])
        if DRY:
            print("would create ", desc)
        else:
            api("action.create", params); print("created ", desc)
        created.append(name)
    for s in skipped: print("exists  ", s)
    for w in warnings: print("WARNING ", w)
    print(f"{'planned' if DRY else 'created'}={len(created)} existing={len(skipped)} warnings={len(warnings)}")

if __name__ == "__main__":
    main()
