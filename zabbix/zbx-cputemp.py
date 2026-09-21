#!/usr/bin/env python3
"""zbx-cputemp.py: repair the hand-built CPU temperature triggers on the pve nodes.

Found on 2026-09-21: the five nodes each carry two host-level CPU temperature
triggers, made by hand one host at a time, and eight of the ten were DISABLED. Only
pve4 was alerting. The dashboard gauges gave the appearance of coverage the whole
time, which is why nobody noticed.

They were not disabled for being noisy. The thresholds are 90 and 100 °C and the
hottest node in the fleet sits in the sixties, so nothing has ever been near them.

Three changes, all reversible:

  1. Enable the eight disabled triggers. Nothing is close to firing, so this cannot
     produce a page today; it means a real thermal event produces one.
  2. Require the condition to persist. All ten used last(), which fires on a single
     sample, so one bad sensor read alerts. Every other trigger in this fleet asks
     for a sustained condition and temperature should too: min() over a window means
     every sample in it was above the line.
  3. Give the same trigger the same name on every host. pve4 said "is too high" and
     the other four said "too high", so anything matching by name missed one.

Thresholds are deliberately unchanged. 90 and 100 are sound for these CPUs, and
moving a threshold in the same pass as enabling a trigger would make it impossible to
say which change caused any new alert.

Prints what it would do and changes nothing unless --apply is given.

  python3 zbx-cputemp.py            show the plan
  python3 zbx-cputemp.py --apply    make the changes

Run from a machine that can reach the Zabbix frontend (the laptop; the dev box is
firewalled off). Needs trigger.get and, for --apply, trigger.update on the API role.
"""
import json, os, sys, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))
HOSTS = ["pve0", "pve1", "pve2", "pve3", "pve4"]

# (name it should have, window, operator and threshold)
WARN = ("CPU temperature too high", "5m", ">90")
CRIT = ("CPU temperature is critical", "3m", ">=100")


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


apply = "--apply" in sys.argv
print("PLAN ONLY, nothing will change. Re-run with --apply to make these changes.\n"
      if not apply else "APPLYING.\n")

planned = []
for host in HOSTS:
    trigs = api("trigger.get", {
        "output": ["triggerid", "description", "expression", "status", "priority"],
        "host": host, "search": {"description": "CPU temperature"},
        "expandExpression": True})
    if not trigs:
        print(f"{host}: no CPU temperature trigger found, skipping")
        continue
    for t in trigs:
        # tell the two apart by their threshold, not their name, since the names drifted
        which = CRIT if "100" in t["expression"] else WARN
        name, window, test = which
        want_expr = f"min(/{host}/{host}.cpuTemperature,{window}){test}"
        change = []
        params = {"triggerid": t["triggerid"]}
        if t["status"] == "1":
            change.append("enable")
            params["status"] = 0
        if t["expression"] != want_expr:
            change.append("sustained expression")
            params["expression"] = want_expr
        if t["description"] != name:
            change.append(f"rename to {name!r}")
            params["description"] = name
        if not change:
            print(f"{host}: [{t['priority']}] {t['description']} already correct")
            continue
        print(f"{host}: [{t['priority']}] {t['description']}")
        print(f"    {', '.join(change)}")
        print(f"    was  {t['expression']}" + ("  (DISABLED)" if t["status"] == "1" else ""))
        print(f"    now  {want_expr}")
        planned.append(params)

if not planned:
    print("\nnothing to do")
elif not apply:
    print(f"\n{len(planned)} triggers would change. Re-run with --apply.")
else:
    for params in planned:
        api("trigger.update", params)
    print(f"\n{len(planned)} triggers updated.")
    print("Verify with: python3 zbx-item.py --key cpuTemperature")
