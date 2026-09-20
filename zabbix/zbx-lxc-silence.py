#!/usr/bin/env python3
"""zbx-lxc-silence.py: on every host that has the "Homelab LXC" template linked,
silence the three stock Linux triggers that read the host kernel's numbers
inside a container (card 2g05h9zrkkr1):

  - host macro {$LOAD_AVG_PER_CPU.MAX.WARN} = 1000   (load average is too high)
  - host macro {$CPU.UTIL.CRIT}            = 1000   (high CPU utilization)
  - the host's inherited "has been restarted" trigger disabled
  - the PSI template's "High IO pressure stall on ..." trigger disabled (host's number)

The Homelab LXC template carries the honest replacements. Idempotent: existing
macros are updated to the value, disabled triggers stay disabled. Run on the
laptop with the claude API token; the role needs host.get, usermacro.get,
usermacro.create, usermacro.update, trigger.get, trigger.update.

  python3 zbx-lxc-silence.py --dry-run
  python3 zbx-lxc-silence.py
  python3 zbx-lxc-silence.py --restore-load   # load macro back to the stock 1.5

Use --restore-load once lxcfs runs with --enable-loadavg on the nodes (bootstrap
harden.sh, 2026-09-20): from then on a container's /proc/loadavg is its own, so
the stock load trigger is meaningful again. The CPU macro, the restart trigger
and the PSI trigger stay silenced: those still read the host.
"""
import json, os, sys, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))
DRY = "--dry-run" in sys.argv
RESTORE_LOAD = "--restore-load" in sys.argv
TEMPLATE = "Homelab LXC"
# --restore-load touches the load macro only and puts it back to the stock value.
MACROS = ({"{$LOAD_AVG_PER_CPU.MAX.WARN}": "1.5"} if RESTORE_LOAD
          else {"{$LOAD_AVG_PER_CPU.MAX.WARN}": "1000", "{$CPU.UTIL.CRIT}": "1000"})
RESTART_TRIGGER_MATCH = "Linux: {HOST.NAME} has been restarted"   # the stock one only, never "LXC: ..."
PSI_TRIGGER_PREFIX = "High IO pressure stall on"   # the PSI template's trigger: host's number inside a container

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
        for macro, val in MACROS.items():
            if macro in have and have[macro]["value"] == val:
                print(f"{h['host']}: {macro} already {val}")
            elif macro in have:
                print(f"{h['host']}: {macro} {have[macro]['value']} -> {val}")
                changes += 1
                DRY or api("usermacro.update", {"hostmacroid": have[macro]["hostmacroid"], "value": val})
            else:
                print(f"{h['host']}: add {macro} = {val}")
                changes += 1
                DRY or api("usermacro.create", {"hostid": h["hostid"], "macro": macro, "value": val})
        trs = api("trigger.get", {"output": ["triggerid", "description", "status"], "hostids": h["hostid"],
                                  "filter": {"description": RESTART_TRIGGER_MATCH}, "inherited": True})
        trs = [t for t in trs if t["description"] == RESTART_TRIGGER_MATCH]
        for t in trs:
            if t["status"] == "1":
                print(f"{h['host']}: trigger '{t['description']}' already disabled")
            else:
                print(f"{h['host']}: disable trigger '{t['description']}'")
                changes += 1
                DRY or api("trigger.update", {"triggerid": t["triggerid"], "status": 1})
        if not trs:
            print(f"{h['host']}: WARNING no inherited '{RESTART_TRIGGER_MATCH}' trigger found")
        psi = api("trigger.get", {"output": ["triggerid", "description", "status"], "hostids": h["hostid"],
                                  "search": {"description": PSI_TRIGGER_PREFIX}, "inherited": True})
        for t in psi:
            if not t["description"].startswith(PSI_TRIGGER_PREFIX):
                continue
            if t["status"] == "1":
                print(f"{h['host']}: trigger '{t['description'][:40]}...' already disabled")
            else:
                print(f"{h['host']}: disable trigger '{t['description'][:40]}...'")
                changes += 1
                DRY or api("trigger.update", {"triggerid": t["triggerid"], "status": 1})
    print(f"hosts={len(hosts)} {'planned' if DRY else 'applied'} changes={changes}")

if __name__ == "__main__":
    main()
