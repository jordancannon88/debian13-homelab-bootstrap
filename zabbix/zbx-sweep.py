#!/usr/bin/env python3
"""zbx-sweep.py: monitoring that is not monitoring anything.

Two questions, both raised by the CPU temperature work of 2026-09-21, where five
items sat on hosts that could never produce them and ten triggers watched those
items. Nothing in Zabbix reports that state: an unsupported item is not a problem,
and a trigger over a dead item is silent rather than wrong. You have to go looking.

  strays   Items whose key names a DIFFERENT host, for example pve4.cpuTemperature
           sitting on pms0. This is what host cloning in the interface produces,
           because a clone carries host-level items and triggers with it.

  dead     Items that are unsupported, or that have never returned a value, with the
           triggers that depend on them. A trigger over an item with no data cannot
           fire, so a dead item is silently missing coverage rather than a visible
           fault.

Without a host it prints one line per host, a count only. Name a host to see the
detail for that host alone. Nothing here is worth reading as a wall of text, and the
counts tell you which host to look at first.

  python3 zbx-sweep.py strays              counts per host
  python3 zbx-sweep.py strays pve2         detail for one host
  python3 zbx-sweep.py dead                counts per host
  python3 zbx-sweep.py dead pve1           detail for one host
  python3 zbx-sweep.py dead pve1 --templated   include templated items too
  python3 zbx-sweep.py dead --by-key       group by key instead of by host

By default `dead` shows host-level items only, because a templated item that is
unsupported is usually one template linked where it does not apply, which is a
different and less urgent problem than something made by hand and forgotten.

Read-only. It deletes nothing; it only tells you where to look. Run from a machine
that can reach the Zabbix frontend (the laptop; the dev box is firewalled off).
Needs host.get, item.get and trigger.get on the API role.
"""
import json, os, re, sys, urllib.request

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


def label(it):
    """How the item came to exist. templateid is 0 for DISCOVERED items as well as
    hand-made ones, so reading it alone counts LLD output as hand-made: dkr's 68
    docker.container_info items are discovered, not someone's typing."""
    if str(it.get("flags", "0")) == "4":
        return "discovered"
    return "templated" if it.get("templateid", "0") != "0" else "by hand"


def why_dead(it):
    """Why this item is not monitoring anything, or None if it is fine.

    An item with history disabled ALWAYS reports no last value, because item.get
    reads history. That is the normal pattern for a master item holding a large JSON
    blob for dependent items to parse, so judging it by lastclock marks every healthy
    master item dead. smart.disk.get is one: it reads empty on every host in the
    fleet, including the two where SMART alerts are firing right now. Only the
    item's supported state can judge those."""
    if it.get("state") == "1":
        return "UNSUPPORTED"
    if str(it.get("history", "")) in ("0", "0s"):
        return None                       # keeps no history by design, not dead
    if str(it.get("lastclock", "0")) == "0":
        return "no data, ever"
    return None


args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = {a for a in sys.argv[1:] if a.startswith("--")}
cmd = args[0] if args else ""
only = args[1] if len(args) > 1 else None
if cmd not in ("strays", "dead"):
    raise SystemExit(__doc__)

hosts = sorted({h["host"] for h in api("host.get", {"output": ["host"]})})
items = api("item.get", {
    "output": ["itemid", "key_", "name", "lastvalue", "lastclock", "state", "error",
               "status", "templateid", "flags", "history"],
    "selectHosts": ["host"], "monitored": True})

# Collect the findings first, then decide how much of them to print.
found = {}
# Zabbix's own key namespaces. A host named after one of these cannot be
# distinguished from an ordinary key, so it is excluded as a needle. The first
# version of this matched a host named "net" against every net.if.* item in the
# fleet and reported 1201 findings across all 17 hosts, none of them real.
RESERVED = {
    "agent", "db", "dir", "eventlog", "icmpping", "icmppingloss", "icmppingsec",
    "jmx", "kernel", "log", "logrt", "modbus", "mqtt", "net", "perf_counter",
    "perf_counter_en", "proc", "proc_info", "sensor", "service", "system", "vfs",
    "vm", "web", "wmi", "zabbix",
}


def first_segment(key):
    """The part before the first dot or bracket: pve4.cpuTemperature -> pve4."""
    return re.split(r"[.\[]", key, maxsplit=1)[0]


if cmd == "strays":
    # The clone signature is specific: the key is NAMED for a host, as in
    # pve4.cpuTemperature. Matching the host name anywhere in the key is far too
    # loose, because ordinary keys embed paths and interface names.
    needles = {h for h in hosts if h not in RESERVED}
    ignored = sorted(set(hosts) - needles)
    for it in items:
        host = it["hosts"][0]["host"]
        seg = first_segment(it["key_"])
        if seg in needles and seg != host:
            found.setdefault(host, []).append((it, seg))
    if ignored:
        print(f"ignoring host name(s) that collide with Zabbix key namespaces: "
              f"{', '.join(ignored)}\n")
else:
    for it in items:
        if it.get("status") == "1":
            continue                                  # disabled on purpose
        if "--templated" not in flags and it.get("templateid", "0") != "0":
            continue
        w = why_dead(it)
        if w:
            found.setdefault(it["hosts"][0]["host"], []).append((it, w))

if not found:
    print(f"{len(hosts)} hosts checked, nothing found." if cmd == "strays" else
          f"{len(hosts)} hosts checked, no dead items.")
    raise SystemExit(0)

if only is None and "--by-key" in flags:
    # One line per distinct key with the hosts it is dead on. When every host shows
    # the same small count, the question is which key, not which host.
    by_key = {}
    for host, rows in found.items():
        for it, note in rows:
            by_key.setdefault(it["key_"], []).append(host)
    for key in sorted(by_key, key=lambda k: (-len(by_key[k]), k)):
        hs = sorted(by_key[key])
        print(f"  {key}")
        print(f"      {len(hs)} host(s): {', '.join(hs)}")
    print(f"\n{len(by_key)} distinct key(s), {sum(len(v) for v in by_key.values())} item(s).")
    raise SystemExit(0)

if only is None:
    width = max(len(h) for h in found)
    total = sum(len(v) for v in found.values())
    for host in sorted(found, key=lambda h: (-len(found[h]), h)):
        kinds = {}
        for it, _ in found[host]:
            kinds[label(it)] = kinds.get(label(it), 0) + 1
        detail = ", ".join(f"{n} {k}" for k, n in sorted(kinds.items()))
        print(f"  {host:<{width}}  {len(found[host]):>3}   {detail}")
    scope = "" if "--templated" in flags or cmd == "strays" else " non-templated"
    print(f"\n{total}{scope} item(s) across {len(found)} of {len(hosts)} hosts.")
    print("'by hand' is the column that matters: discovered items come from an LLD"
          "\nrule, so many of them dead usually means one broken collector, not"
          "\nmany forgotten decisions.")
    print(f"Detail for one host:  python3 zbx-sweep.py {cmd} <host>"
          + ("  [--templated]" if cmd == "dead" else ""))
    raise SystemExit(0)

if only not in found:
    print(f"{only}: nothing found" if only in hosts else f"{only}: not a monitored host")
    raise SystemExit(0)

print(f"{only}\n")
for it, note in sorted(found[only], key=lambda r: r[0]["key_"]):
    state = why_dead(it) or (f"collecting, last {it.get('lastvalue')!r}")
    if cmd == "strays":
        print(f"  {it['key_']}")
        print(f"      names {note} instead of {only}   ({label(it)}, {state})")
    else:
        print(f"  {it['key_']}")
        print(f"      {note}   ({label(it)})")
    if it.get("error"):
        print(f"      {it['error']}")
    live = [t for t in api("trigger.get", {"itemids": [it["itemid"]],
                                           "output": ["description", "status"],
                                           "expandDescription": True})
            if t.get("status") != "1"]
    for t in live:
        print(f"      trigger over it, cannot fire: {t['description']}")
