#!/usr/bin/env python3
"""tb-mesh-status-json.py: the state of the Thunderbolt mesh auto-heal (tb-mesh-heal.sh)
as one JSON document, for the Zabbix UserParameter custom.tbmesh.status (template
"Homelab TB3 mesh"). Runs as the zabbix user, reads only /var/lib/tb-mesh-heal, /proc
and /etc/default/tb-mesh-heal. It never touches the mesh: no vtysh, ping or pvecm.

Fields:
  boot_id             current boot id (events are scoped to this boot by btime)
  heal_last_run_age   seconds since the heal last ran (its last_run heartbeat); huge when
                      it never ran
  auto_mesh_reboot    AUTO_MESH_REBOOT from /etc/default/tb-mesh-heal (0/1, -1 = file
                      exists but is unreadable)
  mesh_down_for       seconds this node has reached no mesh peer on any link (0 = fine)
  mesh_paging         1 when the heal gave up on a whole-mesh episode (mesh_page file, or
                      an evacuate-and-reboot guard failed while the mesh is still down)
  events_this_boot    heal actions logged since boot
  last_event          newest action ("tbmesh en03 reason=noadj", "meshwide host=pve4
                      event=creset downfor=420")
  last_event_age      seconds since it
  last_meshwide       newest whole-mesh action this boot
  test                1 while the test marker exists
  ifaces.<if>         present (netdev exists), resets (monotonic single-ended reset
                      count), last_reason (newest tbmesh reason for this interface),
                      linkstuck (edge stuck after a coordinated reset, needs a cold
                      cycle of both ends), nobus (controller off the PCI bus, node needs
                      a reboot), peer (far-end node learned while the adjacency was up)
  lld_ifaces          discovery rows for the mesh interfaces that have a reset script
  error               non-empty when the state dir is unreadable

Test marker /etc/zabbix/homelab-test/tbmesh, one keyword per line, injected on top of
the real state: "linkstuck <if>", "nobus <if>", "meshdown <seconds>", "paging",
"stale". Remove it after the test; the template warns after an hour if it is left.
"""
import json, os, re, sys, time

STATE = os.environ.get("TBMESH_STATE", "/var/lib/tb-mesh-heal")
MARKER = os.environ.get("TBMESH_MARKER", "/etc/zabbix/homelab-test/tbmesh")
DEFAULTS = "/etc/default/tb-mesh-heal"
IFACES = [i for i in ("en02", "en03") if os.access(f"/usr/local/bin/pve-{i}-disconnect-bug-fix.sh", os.X_OK)] or ["en02", "en03"]
EVENT_RE = re.compile(r"^(\d+)\s+(.*)$")
TBMESH_RE = re.compile(r"^tbmesh (\S+) reason=(\S+)")


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def read_int(path, default=0):
    try:
        return int(read(path) or default)
    except ValueError:
        return default


def btime():
    for line in read("/proc/stat").splitlines():
        if line.startswith("btime "):
            return int(line.split()[1])
    return 0


def auto_mesh_reboot():
    if not os.path.exists(DEFAULTS):
        return 0
    if not os.access(DEFAULTS, os.R_OK):
        return -1
    m = re.search(r"^\s*(?:export\s+)?AUTO_MESH_REBOOT=['\"]?([01])", read(DEFAULTS), re.M)
    return int(m.group(1)) if m else 0


def main():
    now = int(time.time())
    out = {"boot_id": read("/proc/sys/kernel/random/boot_id"), "heal_last_run_age": 999999,
           "auto_mesh_reboot": auto_mesh_reboot(), "mesh_down_for": 0, "mesh_paging": 0,
           "events_this_boot": 0, "last_event": "", "last_event_age": 999999, "last_meshwide": "",
           "test": 0, "ifaces": {}, "lld_ifaces": [{"{#IFNAME}": i} for i in IFACES], "error": ""}
    if not os.path.isdir(STATE) or not os.access(STATE, os.R_OK | os.X_OK):
        out["error"] = f"{STATE} missing or not readable by uid {os.getuid()} (heal never ran, or dir mode is not 0755)"
        print(json.dumps(out, separators=(",", ":")))
        return

    last_run = read_int(os.path.join(STATE, "last_run"), 0)
    if last_run:
        out["heal_last_run_age"] = max(0, now - last_run)
    since = read_int(os.path.join(STATE, "mesh_down_since"), 0)
    if since:
        out["mesh_down_for"] = max(0, now - since)
    paging = os.path.exists(os.path.join(STATE, "mesh_page"))

    boot = btime()
    events = []
    for line in read(os.path.join(STATE, "events.log")).splitlines():
        m = EVENT_RE.match(line.strip())
        if m:
            events.append((int(m.group(1)), m.group(2)))
    events.sort(key=lambda e: e[0])
    this_boot = [e for e in events if e[0] >= boot]
    out["events_this_boot"] = len(this_boot)
    if events:
        out["last_event"] = events[-1][1][:200]
        out["last_event_age"] = max(0, now - events[-1][0])
    meshwide = [e for e in this_boot if e[1].startswith("meshwide ")]
    if meshwide:
        out["last_meshwide"] = meshwide[-1][1][:200]
        # the evacuate-and-reboot guards page without writing mesh_page
        if out["mesh_down_for"] > 0 and re.search(r"event=(notarget|noquorum|evac_failed)", meshwide[-1][1]):
            paging = True

    for i in IFACES:
        last_reason = ""
        for _, txt in reversed(this_boot):
            m = TBMESH_RE.match(txt)
            if m and m.group(1) == i:
                last_reason = m.group(2)
                break
        out["ifaces"][i] = {
            "present": 1 if os.path.isdir(f"/sys/class/net/{i}") else 0,
            "resets": read_int(os.path.join(STATE, f"{i}.resets"), 0),
            "last_reason": last_reason,
            "linkstuck": 1 if os.path.exists(os.path.join(STATE, f"{i}.linkstuck")) else 0,
            "nobus": 1 if os.path.exists(os.path.join(STATE, f"{i}.nobus")) else 0,
            "peer": read(os.path.join(STATE, f"{i}.peer")),
        }

    if os.path.exists(MARKER):
        out["test"] = 1
        for line in read(MARKER).splitlines():
            w = line.split()
            if not w:
                continue
            if w[0] == "linkstuck" and len(w) > 1 and w[1] in out["ifaces"]:
                out["ifaces"][w[1]]["linkstuck"] = 1
                out["ifaces"][w[1]]["last_reason"] = "linkstuck"
            elif w[0] == "nobus" and len(w) > 1 and w[1] in out["ifaces"]:
                out["ifaces"][w[1]]["nobus"] = 1
                out["ifaces"][w[1]]["last_reason"] = "nobus"
            elif w[0] == "meshdown" and len(w) > 1 and w[1].isdigit():
                out["mesh_down_for"] = int(w[1])
            elif w[0] == "paging":
                paging = True
                out["last_meshwide"] = "meshwide host=TEST event=manual"
            elif w[0] == "stale":
                out["heal_last_run_age"] = 9999

    out["mesh_paging"] = 1 if paging else 0
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never leave the item unsupported
        print(json.dumps({"error": f"{type(e).__name__}: {e}"[:200], "test": 0, "lld_ifaces": []}))
