#!/usr/bin/env python3
"""zbx-pxc1-prune.py: on the cluster host pxc1 (Proxmox VE by HTTP), disable the
per-guest triggers that duplicate a guest's own agent (card rv8jq8rbryow).

Kept: everything about nodes, quorum, HA, storage pools, and every trigger for
a guest that has no agent of its own (unc1, immich, haos, opn1, ...).
Disabled: restart / disk / memory / CPU / stopped triggers for guests listed in
SELF_REPORTING (they carry Linux, PSI, LXC or SMART templates themselves), and
the "Storage [node/pool] ..." triggers for every ZFS pool that the node itself
already reports through the Homelab ZFS pools template (found from the node's
own "ZFS: [pool]:" triggers). Storages of other kinds (dir, PBS, NFS) stay.
Also disabled: "Node [pveN]: restarted / CPU / memory / root filesystem / swap"
when pveN is itself a Zabbix host (its Linux agent raises the same); Storage
"local" (the root pool) and "local-pbs-hdd" (pve3's ZFS pool); shared NFS
storages on every node but KEEP_SHARED_ON. "Node offline", quorum, API,
"Not running" and every trigger for an agentless guest stay.

  python3 zbx-pxc1-prune.py --dry-run   # list keep / disable, change nothing
  python3 zbx-pxc1-prune.py             # apply
  python3 zbx-pxc1-prune.py --enable    # undo: re-enable everything it disabled

Role needs host.get, trigger.get, trigger.update.
"""
import json, os, re, sys, urllib.request

URL = os.environ.get("ZBX_URL", "https://zabbix.local.cannon.dev/api_jsonrpc.php")
TOKEN_FILE = os.environ.get("ZBX_TOKEN_FILE", os.path.expanduser("~/.config/zabbix/token"))
DRY = "--dry-run" in sys.argv
ENABLE = "--enable" in sys.argv
HOST = "pxc1"
# Guests with their own Zabbix agent (name as Proxmox shows it in the trigger).
SELF_REPORTING = ["grf", "zabbix", "frigate", "seafile-keeper", "pbs", "pbs0", "dkr", "net", "dev", "pms0"]
# Trigger name fragments that a guest agent already covers.
DUPLICATE_KINDS = ["has been restarted", "disk space usage", "memory usage", "CPU usage", "cpu usage"]
NODE_DUP_KINDS = ["has been restarted", "memory usage", "CPU usage", "cpu usage",
                  "root filesystem space usage", "swap space usage"]
# Storages whose space another host already reports: "local" is the node's root
# pool (Linux agent, "/"), "local-pbs-hdd" is pve3's local-zfs-hdd pool (ZFS template).
STORAGE_COVERED = ["local", "local-pbs-hdd"]
# Shared storages every node mounts: keep the trigger on one node only.
SHARED_STORAGES = ["nfs-pms0", "pms0-nas"]
KEEP_SHARED_ON = "pve2"

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

def guest_of(name):
    # "Proxmox VE: LXC [pve3/pbs (lxc/901)] ..." or "VM [pve4/dev (qemu/904)] ..."
    # and the restart form without the id: "LXC [pve2/grf]: has been restarted"
    m = re.search(r"\[[^/\]]+/([^ (\]]+)(?: \((?:lxc|qemu)/\d+\))?\]", name)
    return m.group(1) if m else None

def self_reported_pools():
    # (node, pool) pairs the nodes report themselves: "ZFS: [local-zfs-hdd]: ..." on host pve2
    trs = api("trigger.get", {"output": ["description"], "selectHosts": ["host"],
                              "search": {"description": "ZFS: ["}, "expandDescription": True})
    pairs = set()
    for t in trs:
        m = re.match(r"ZFS: \[([^\]]+)\]", t["description"])
        if m:
            for h in t["hosts"]:
                pairs.add((h["host"], m.group(1)))
    return pairs

def main():
    pools = self_reported_pools()
    agent_hosts = {h["host"] for h in api("host.get", {"output": ["host"]})}
    hosts = api("host.get", {"output": ["hostid", "host"], "filter": {"host": [HOST]}})
    if not hosts:
        raise SystemExit(f"host {HOST} not found (API user needs read on its group)")
    hid = hosts[0]["hostid"]
    trs = api("trigger.get", {"output": ["triggerid", "description", "status"], "hostids": hid,
                              "expandDescription": True, "sortfield": "description"})
    keep, dup = [], []
    for t in trs:
        g = guest_of(t["description"])
        kind = any(k in t["description"] for k in DUPLICATE_KINDS)
        st = re.search(r"Storage \[([^/\]]+)/([^\]]+)\]", t["description"])
        nd = re.search(r"Node \[([^\]]+)\]", t["description"])
        node_dup = bool(nd and nd.group(1) in agent_hosts and any(k in t["description"] for k in NODE_DUP_KINDS))
        st_dup = bool(st and ((st.group(1), st.group(2)) in pools
                              or (st.group(2) in STORAGE_COVERED and st.group(1) in agent_hosts)
                              or (st.group(2) in SHARED_STORAGES and st.group(1) != KEEP_SHARED_ON)))
        if (g in SELF_REPORTING and kind) or st_dup or node_dup:
            dup.append(t)
        else:
            keep.append(t)
    changes = 0
    for t in dup:
        want = "0" if ENABLE else "1"
        state = "enable" if ENABLE else "disable"
        if t["status"] == want:
            print(f"{state}d already: {t['description'][:95]}")
        else:
            print(f"{state}: {t['description'][:95]}")
            changes += 1
            DRY or api("trigger.update", {"triggerid": t["triggerid"], "status": int(want)})
    print(f"--- kept ({len(keep)}):")
    for t in keep:
        print(f"keep{' (disabled)' if t['status']=='1' else ''}: {t['description'][:95]}")
    print(f"total={len(trs)} duplicates={len(dup)} {'planned' if DRY else 'applied'} changes={changes}")

if __name__ == "__main__":
    main()
