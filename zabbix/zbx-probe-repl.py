#!/usr/bin/env python3
"""zbx-probe-repl.py: why is the replication-disabled trigger not showing?

Reads the Zabbix API and answers, in order:

  1. Does the trigger PROTOTYPE exist on the template? If not, the import did not
     take and nothing downstream can work.
  2. Did discovery create real TRIGGERS from it, one per job? If the prototype is
     there and the triggers are not, discovery has not run since the import.
  3. What is each job's enabled ITEM actually reading? A job that is enabled again
     is the honest reason for silence: the guard handed replication back.
  4. If a trigger exists and the item reads disabled, what does the server say the
     trigger's VALUE and state are? An unsupported trigger is silent and looks
     identical to a working one that has not fired.
  5. For any job reading disabled, the actual HISTORY over the grace window. This
     is the only thing that settles a trigger which evaluated cleanly and did not
     fire: `max(...,6h)=0` is false if a single 1 landed in the window, so a job
     that was briefly re-enabled and disabled again is silent and correct. It also
     shows whether the item is still collecting at all, since a stale last value
     looks identical to a current one in the item list.

Read-only. Nothing is created, changed or deleted.

Run it from a machine that can reach the Zabbix frontend (the laptop; the dev box
is firewalled off). Needs the token in ~/.config/zabbix/token, the same one the
template imports use.
"""
import json, os, sys, time, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))
TEMPLATE = "Homelab Proxmox events"
KEY = "custom.pve.replication.enabled"


def api(method, params):
    tok = open(TOKEN_FILE).readline().strip()
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(URL, data=body, headers={
        "Content-Type": "application/json-rpc", "Authorization": f"Bearer {tok}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.loads(r.read())
    if "error" in out:
        # A method the role is not allowed is worth saying plainly rather than
        # crashing, because the probe can still answer the other questions.
        return {"__error__": out["error"].get("data") or out["error"].get("message")}
    return out["result"]


GRACE = int(os.environ.get("GRACE_SECONDS", 6 * 3600))


def show(label, value):
    print(f"  {label:<26} {value}")


def ago(clock):
    """Human age of a unix timestamp, so a stale value is obvious."""
    try:
        d = int(time.time()) - int(clock)
    except (TypeError, ValueError):
        return "never"
    if d < 90:
        return f"{d}s ago"
    if d < 5400:
        return f"{d // 60}m ago"
    return f"{d / 3600:.1f}h ago"


print(f"template: {TEMPLATE}")
print(f"api:      {URL}")

# 1. the prototype
print("\n1. trigger prototype on the template")
tpl = api("template.get", {"output": ["templateid", "name"], "filter": {"host": [TEMPLATE]}})
if isinstance(tpl, dict) or not tpl:
    print(f"  template not found or not readable: {tpl}")
    sys.exit(1)
tid = tpl[0]["templateid"]
protos = api("triggerprototype.get", {
    "output": ["triggerid", "description", "expression", "status", "priority"],
    "templateids": [tid], "expandExpression": True})
if isinstance(protos, dict):
    show("could not read", protos["__error__"])
    print("  (add triggerprototype.get to the API role's allow list to see this)")
elif not protos:
    show("prototypes found", "NONE. The import did not create it.")
else:
    for p in protos:
        mark = "<-- this one" if "enabled[" in p.get("expression", "") else ""
        show("prototype", f"{p['description']} {mark}")
        if mark:
            show("  expression", p["expression"])
            show("  status", "enabled" if p["status"] == "0" else "DISABLED")

# 2. discovered triggers
print("\n2. triggers discovery created from it")
trigs = api("trigger.get", {
    "output": ["triggerid", "description", "expression", "value", "state", "status",
               "error", "lastchange"],
    "search": {"description": "has been disabled for over"},
    "selectHosts": ["host"], "expandExpression": True, "expandDescription": True})
if isinstance(trigs, dict):
    show("could not read", trigs["__error__"])
elif not trigs:
    show("triggers found", "NONE. The prototype has not been discovered yet.")
else:
    for t in trigs:
        host = ",".join(h["host"] for h in t.get("hosts", []))
        state = "UNSUPPORTED" if t["state"] == "1" else "ok"
        val = "PROBLEM" if t["value"] == "1" else "not firing"
        show(f"{host}", f"{val}, state={state}, "
                        f"{'enabled' if t['status']=='0' else 'DISABLED'}, "
                        f"last changed {ago(t.get('lastchange'))}")
        show("  name", t["description"])
        if t.get("error"):
            show("  server error", t["error"])

# 3. what the item reads
print(f"\n3. current value of {KEY}[...] per job")
items = api("item.get", {
    "output": ["itemid", "key_", "name", "lastvalue", "lastclock", "state", "error",
               "value_type"],
    "search": {"key_": KEY}, "selectHosts": ["host"], "monitored": True})
off = []
if isinstance(items, dict):
    show("could not read", items["__error__"])
elif not items:
    show("items found", "NONE. Discovery has not created the per-job items.")
else:
    for it in sorted(items, key=lambda i: (i["hosts"][0]["host"], i["key_"])):
        host = it["hosts"][0]["host"]
        v = it.get("lastvalue")
        meaning = {"0": "DISABLED", "1": "enabled"}.get(v, f"raw {v!r}")
        state = " UNSUPPORTED" if it["state"] == "1" else ""
        show(f"{host} {it['key_']}", f"{meaning}{state}, {ago(it.get('lastclock'))}")
        if it.get("error"):
            show("  item error", it["error"])
        if v == "0":
            off.append((host, it))

# 5. history over the grace window, for the jobs that read disabled
print(f"\n5. history over the last {GRACE // 3600}h for the jobs reading DISABLED")
if not off:
    show("nothing to check", "no job currently reads disabled")
for host, it in off:
    hist = api("history.get", {
        "itemids": [it["itemid"]], "history": int(it.get("value_type", 3)),
        "time_from": int(time.time()) - GRACE, "output": "extend",
        "sortfield": "clock", "sortorder": "ASC", "limit": 2000})
    if isinstance(hist, dict):
        show(f"{host} {it['key_']}", f"could not read: {hist['__error__']}")
        continue
    if not hist:
        show(f"{host} {it['key_']}",
             f"NO DATA in the window. max() over an empty window cannot be 0, "
             f"which is why the trigger is silent.")
        continue
    vals = [h["value"] for h in hist]
    highest = max(vals)
    # only transitions are interesting; a heartbeat repeats the same value hourly
    changes = [h for i, h in enumerate(hist) if i == 0 or h["value"] != hist[i - 1]["value"]]
    show(f"{host} {it['key_']}",
         f"{len(hist)} samples, oldest {ago(hist[0]['clock'])}, "
         f"newest {ago(hist[-1]['clock'])}, max={highest}")
    for h in changes:
        meaning = {"0": "DISABLED", "1": "enabled"}.get(h["value"], h["value"])
        show("  ", f"{time.strftime('%F %T', time.localtime(int(h['clock'])))}  {meaning}")
    if highest != "0":
        show("  verdict", "a 1 landed in the window, so max(...)=0 is false and the "
                          "silence is CORRECT: the job was re-enabled at some point.")
    else:
        show("  verdict", "every sample is 0, so max(...)=0 is true and the trigger "
                          "SHOULD be firing. If it is not, it has not been "
                          "re-evaluated since the import.")

print("\nreading this: a prototype present with no triggers means discovery has not"
      "\nrun since the import. Triggers present and not firing with the item reading"
      "\nDISABLED means the expression is wrong or unsupported. Items reading enabled"
      "\nmeans the guard already handed replication back and the silence is correct.")
