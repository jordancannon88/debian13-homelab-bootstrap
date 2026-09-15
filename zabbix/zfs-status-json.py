#!/usr/bin/env python3
"""zfs-status-json.py: one JSON document with every ZFS pool and vdev on this node,
for the Zabbix UserParameter custom.zfs.status (template "Homelab ZFS pools").

Reads `zpool status -j -p` and `zpool list -Hp` as the zabbix user (no root needed
on OpenZFS 2.3+). Emits:
  pools:      per pool health, capacity, fragmentation, permanent error count, scrub stats
  vdevs:      per non-root vdev (mirror groups, disks, logs, cache) state and error counters
  lld_pools / lld_vdevs: discovery arrays for the two LLD rules
Test offline: zfs-status-json.py - < status.json  (uses the piped `zpool status -j -p` output).
"""
import json
import subprocess
import sys
import time

STATE_CODE = {"ONLINE": 0, "DEGRADED": 1, "FAULTED": 2, "OFFLINE": 3, "UNAVAIL": 4, "REMOVED": 5}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=20, check=True).stdout


def num(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def walk(pool, node, out, lld, depth=0):
    """Collect every vdev below the root vdev. Root is skipped: its counters are the pool's own."""
    if depth > 0:
        name = node.get("name", "?")
        r, w, c = num(node.get("read_errors")), num(node.get("write_errors")), num(node.get("checksum_errors"))
        out[f"{pool}/{name}"] = {
            "pool": pool,
            "vdev": name,
            "type": node.get("vdev_type", ""),
            "state": node.get("state", ""),
            "state_code": STATE_CODE.get(node.get("state", ""), 6),
            "read": r,
            "write": w,
            "cksum": c,
            "errors_total": r + w + c,
            "slow_ios": num(node.get("slow_ios")),
        }
        lld.append({"{#POOL}": pool, "{#VDEV}": name, "{#VDEVTYPE}": node.get("vdev_type", "")})
    for child in (node.get("vdevs") or {}).values():
        walk(pool, child, out, lld, depth + 1)


def build(status, listing):
    pools, vdevs, lld_pools, lld_vdevs = {}, {}, [], []
    caps = {}
    for line in listing.splitlines():
        f = line.split("\t")
        if len(f) >= 6:
            caps[f[0]] = {"size": num(f[2]), "alloc": num(f[3]), "cap": num(f[4]), "frag": num(f[5])}
    for name, p in (status.get("pools") or {}).items():
        scan = p.get("scan_stats") or {}
        scan_end = num(scan.get("end_time"))
        pools[name] = {
            "health": p.get("state", ""),
            "health_code": STATE_CODE.get(p.get("state", ""), 6),
            "error_count": num(p.get("error_count")),
            "status": p.get("status", ""),
            "scan_function": scan.get("function", "NONE"),
            "scan_state": scan.get("state", "NONE"),
            "scan_end": scan_end,
            "scan_errors": num(scan.get("errors")),
            **caps.get(name, {"size": 0, "alloc": 0, "cap": 0, "frag": 0}),
        }
        lld_pools.append({"{#POOL}": name})
        for root in (p.get("vdevs") or {}).values():
            walk(name, root, vdevs, lld_vdevs)
    return {"ts": int(time.time()), "pools": pools, "vdevs": vdevs, "lld_pools": lld_pools, "lld_vdevs": lld_vdevs}


def main():
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "-":
            status = json.load(sys.stdin)
            listing = ""
        else:
            status = json.loads(run(["zpool", "status", "-j", "-p"]))
            listing = run(["zpool", "list", "-Hp", "-o", "name,health,size,alloc,cap,frag"])
        print(json.dumps(build(status, listing), separators=(",", ":")))
    except Exception as e:  # any failure becomes a visible error field, not an unsupported item
        print(json.dumps({"error": f"{type(e).__name__}: {e}"}))
        sys.exit(0)


if __name__ == "__main__":
    main()
