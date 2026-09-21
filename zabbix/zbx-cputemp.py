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

Separately, --strays finds the same item copied onto hosts it does not belong to.
Verifying the repair turned up `pve4.cpuTemperature` on pbs, pbs0, pms0, pxc1 and
seafile-keeper, each with two enabled triggers, every item unsupported with "Unknown
metric" and none of them ever having returned a value. Those hosts were created by
cloning pve4 in the interface, which carries its host-level items and triggers with
it. Ten triggers that could never fire, on five items that never collected, reading
as CPU temperature monitoring for machines that have none.

Deleting an item deletes the triggers that depend only on it. To make that safe,
--strays refuses to touch anything that has ever collected a value, and only
considers an item whose key names a host other than the one it sits on.

Prints what it would do and changes nothing unless --apply is given.

  python3 zbx-cputemp.py             show the plan for pve0-pve4
  python3 zbx-cputemp.py --apply     make those changes
  python3 zbx-cputemp.py --strays    show the stray copies on other hosts
  python3 zbx-cputemp.py --strays --apply   delete them

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

if "--strays" in sys.argv:
    items = api("item.get", {
        "output": ["itemid", "key_", "lastvalue", "lastclock", "state", "error"],
        "search": {"key_": "cpuTemperature"}, "selectHosts": ["host"]})
    doomed, kept = [], []
    for it in items:
        host = it["hosts"][0]["host"] if it.get("hosts") else "?"
        owner = it["key_"].split(".")[0]          # the host the key names
        if owner == host:
            continue                              # belongs here, leave alone
        # Never delete something that has collected data. An item with history is a
        # judgement call, not a stray, whatever its key looks like.
        if str(it.get("lastclock", "0")) != "0":
            kept.append((host, it, "HAS COLLECTED DATA, refusing"))
            continue
        trigs = api("trigger.get", {"itemids": [it["itemid"]],
                                    "output": ["description", "status"],
                                    "expandDescription": True})
        doomed.append((host, it, trigs))
    if not doomed and not kept:
        print("no stray copies found")
    for host, it, trigs in doomed:
        state = "UNSUPPORTED" if it.get("state") == "1" else "no data, ever"
        print(f"{host}: item {it['key_']}  ({state})")
        if it.get("error"):
            print(f"    {it['error']}")
        for t in trigs:
            dis = " DISABLED" if t.get("status") == "1" else " enabled"
            print(f"    trigger goes with it: {t['description']}{dis}")
    for host, it, why in kept:
        print(f"{host}: item {it['key_']}  {why}")
    if doomed and not apply:
        n = sum(len(t) for _, _, t in doomed)
        print(f"\n{len(doomed)} items and the {n} triggers on them would be deleted."
              f"\nNone has ever collected a value, so no history is lost."
              f"\nRe-run with --strays --apply.")
    elif doomed:
        api("item.delete", [it["itemid"] for _, it, _ in doomed])
        print(f"\n{len(doomed)} items deleted, with their triggers.")
        print("Verify with: python3 zbx-item.py --key cpuTemperature")
    sys.exit(0)

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
