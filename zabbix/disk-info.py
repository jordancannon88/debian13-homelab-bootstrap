#!/usr/bin/env python3
"""disk-info.py: every whole disk on this machine as one JSON document, for the
Zabbix item custom.diskinfo (template "Homelab drives").

Why this exists. A disk could only be looked at through a table with one row per
HOST, so a node with three drives squeezed three drives into one cell, and the Top
hosts widget cut that cell at 20 characters. The fix is a row per drive, which
needs an item per drive, which needs discovery keyed on something that does not
move. Kan bfrdv9wpggve has the whole history.

It does NOT alert. The SMART template already discovers these drives and already
fires on health, temperature, reallocated sectors and failed self-tests. The SMART
figures here exist so a drive reads as one line in a table, and carry no triggers.

Drives are keyed by SERIAL, not device letter: sdb is whatever the kernel
enumerated second this boot, the 6 TB disk is sdc on pve2 and sdb on pve3, and the
USB enclosure renumbers when it is re-enumerated.

How it runs. A systemd timer (zbx-diskinfo.timer) runs this as root every minute
with --write, and the agent's UserParameter only reads the file. It used to run
inside the agent, which gives a UserParameter 3 seconds by default; the hourly
SMART refresh across pms0's four USB drives could overrun that and fail the poll,
and a five-second activity sample never could fit. Run by hand with no arguments
it prints the document instead.

Sleeping drives are never woken. Every smartctl call carries -n standby, which asks
the drive's power state before touching it and stops if it is spun down. The full
SMART read runs at most once an hour and its answer is cached; only the power
probe runs every minute.

Numbers that do not apply or could not be read are -1, never 0: a ZFS pool member
has no filesystem of its own, an NVMe drive has no reallocated-sector attribute,
and reporting 0 for either would be a false "fine". The table maps -1 to a dash.
"""
import json, os, re, subprocess, sys, time

DEV_RE = re.compile(r"^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)$")
CACHE_DIR = os.environ.get("DISKINFO_CACHE", "/var/tmp/zbx-diskinfo")
SMART_TTL = int(os.environ.get("DISKINFO_SMART_TTL", "3600"))
WANT_SMART = os.environ.get("DISKINFO_SMART", "1") == "1"
# Five seconds rather than one: this runs from a timer now, not inside the agent's
# timeout, and read and write rates over a single second are mostly noise.
SAMPLE = float(os.environ.get("DISKINFO_SAMPLE", "5"))


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def run(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def disks():
    return sorted(d for d in os.listdir("/sys/block") if DEV_RE.match(d))


def serial_of(dev):
    """Serial from the by-id symlink built out of the ATA or NVMe identity, the same
    string the rest of the homelab names drives by. The EUI form of an NVMe link
    carries no serial, and a partition link names its parent, so both are skipped."""
    bydir = "/dev/disk/by-id"
    try:
        links = os.listdir(bydir)
    except OSError:
        return ""
    best = ""
    for link in sorted(links):
        if "-part" in link or link.startswith("nvme-eui."):
            continue
        if not link.startswith(("ata-", "nvme-", "scsi-SATA")):
            continue
        try:
            if os.path.realpath(os.path.join(bydir, link)) != f"/dev/{dev}":
                continue
        except OSError:
            continue
        sn = link.rsplit("_", 1)[-1]
        if sn and sn != link and len(sn) > len(best):
            best = sn
    return best


def human(size_b):
    tb = size_b / 1000 ** 4
    return f"{tb:.0f} TB" if tb >= 1 else f"{size_b / 1000 ** 3:.0f} GB"


# ---- activity ------------------------------------------------------------------

def diskstats():
    """The eleven classic counters per whole disk. Kernel field N sits at f[2+N]:
    f[3] reads, f[5] sectors read, f[6] ms reading, f[7] writes, f[9] sectors
    written, f[10] ms writing, f[12] io_ticks, f[13] weighted ms.

    Before 2026-09-23 this read f[9] as io_ticks. f[9] is sectors WRITTEN, so every
    busy percent this collector reported measured write volume, capped at 100. That
    is why SSDs read 100 percent while Ansible was writing its temp files. psi-json.sh
    reads the right field and was never affected."""
    out = {}
    for line in read("/proc/diskstats").splitlines():
        f = line.split()
        if len(f) >= 14 and DEV_RE.match(f[2]):
            out[f[2]] = [int(x) for x in f[3:14]]
    return out


def activity():
    """Busy, wait, queue and throughput over one measured window.

    busy   percent of the window with at least one request in flight (io_ticks)
    wait   average milliseconds per completed request, reads and writes together,
           the figure that actually says a drive is slow
    queue  average requests in flight (weighted ms over the window), which is what
           iostat calls aqu-sz
    read, write   bytes per second"""
    s0, c0 = diskstats(), time.monotonic()
    time.sleep(SAMPLE)
    s1, c1 = diskstats(), time.monotonic()
    ms = max(1.0, (c1 - c0) * 1000.0)
    out = {}
    for d, b in s1.items():
        a = s0.get(d, b)
        dd = [max(0, b[i] - a[i]) for i in range(11)]
        ios = dd[0] + dd[4]
        out[d] = {
            "busy": min(100, round(dd[9] * 100 / ms)),
            "wait": round((dd[3] + dd[7]) / ios, 1) if ios else 0.0,
            "queue": round(dd[10] / ms, 2),
            "read": round(dd[2] * 512 * 1000 / ms),
            "write": round(dd[6] * 512 * 1000 / ms),
        }
    return out


def host_io_psi():
    """This machine's IO pressure, full avg10. The kernel measures pressure per
    machine, not per drive, so every drive on a host carries the same figure; it
    sits beside the drive's own wait and queue so the cause and the effect read on
    one line."""
    for line in read("/proc/pressure/io").splitlines():
        if line.startswith("full"):
            for kv in line.split()[1:]:
                k, _, v = kv.partition("=")
                if k == "avg10":
                    try:
                        return float(v)
                    except ValueError:
                        pass
    return -1.0


# ---- where a drive sits --------------------------------------------------------

def parent_disk(name):
    """The whole disk a block device belongs to: sda3 -> sda, nvme0n1p3 -> nvme0n1."""
    if os.path.exists(f"/sys/class/block/{name}/partition"):
        return os.path.basename(os.path.dirname(os.path.realpath(f"/sys/class/block/{name}")))
    return name


def base_disks(name, seen=None):
    """Every whole disk underneath a block device, following device mapper down
    through its slaves, so an LVM volume (/dev/dm-0) resolves to real disks."""
    seen = set() if seen is None else seen
    if name in seen:
        return set()
    seen.add(name)
    slaves = f"/sys/class/block/{name}/slaves"
    if os.path.isdir(slaves):
        out = set()
        for s in os.listdir(slaves):
            out |= base_disks(s, seen)
        if out:
            return out
    return {parent_disk(name)}


def disks_of_path(path):
    for cand in (f"/dev/disk/by-id/{path}", f"/dev/{path}", path):
        real = os.path.realpath(cand)
        if os.path.exists(real):
            return base_disks(os.path.basename(real))
    return set()


def link_of(dev, model):
    """How the drive is attached. For USB it names the kernel driver, because on
    this hardware that is the difference between healthy and corrupting: the ASMedia
    bridges on uas corrupted pms0's XFS on 2026-09-16 and produced 152 ZFS checksum
    errors on pve2 on 2026-09-18, and both stopped on usb-storage."""
    if dev.startswith("nvme"):
        return "NVMe"
    if dev.startswith("vd"):
        return "virtio"
    if model.startswith("QEMU"):
        return "virtual"
    p = os.path.realpath(f"/sys/block/{dev}/device")
    if "/usb" in p:
        cur = p
        while cur and cur != "/":
            drv = os.path.join(cur, "driver")
            if os.path.islink(drv):
                name = os.path.basename(os.path.realpath(drv))
                if name in ("uas", "usb-storage"):
                    return f"USB {name}"
            cur = os.path.dirname(cur)
        return "USB"
    return "SATA" if "/ata" in p else "SCSI"


def zfs():
    """Per whole disk: the pools it belongs to, size and allocation from zpool list,
    and read + write + checksum errors from zpool status. Neither command needs root
    or touches a disk. Space comes from the pool because a vdev has no mountpoint of
    its own: the pool is mounted, the member is not."""
    info = {}

    def slot(d):
        return info.setdefault(d, {"pools": set(), "size": 0, "alloc": 0, "errors": 0})

    pool = None
    for line in run(["zpool", "list", "-vHp"], 20).splitlines():
        if not line.startswith("\t"):
            pool = line.split("\t")[0] or pool
            continue
        f = line.strip().split("\t")
        if len(f) < 4 or f[0].startswith(("mirror", "raidz", "draid", "spare",
                                          "log", "cache", "special", "dedup")):
            continue
        try:
            size, alloc = int(f[1]), int(f[2])
        except ValueError:
            continue
        for d in disks_of_path(f[0]):
            s = slot(d)
            s["size"] += size
            s["alloc"] += alloc
            if pool:
                s["pools"].add(pool)

    status = run(["zpool", "status", "-j", "-p"], 20) or run(["zpool", "status", "-j"], 20)
    try:
        doc = json.loads(status or "{}")
    except ValueError:
        doc = {}

    def walk(node, pool_name):
        if not isinstance(node, dict):
            return
        if node.get("path"):
            err = 0
            for k in ("read_errors", "write_errors", "checksum_errors"):
                try:
                    err += int(str(node.get(k, 0)))
                except ValueError:
                    pass
            for d in disks_of_path(node["path"]):
                s = slot(d)
                s["errors"] += err
                if pool_name:
                    s["pools"].add(pool_name)
        for v in node.values():
            walk(v, pool_name)

    for name, p in (doc.get("pools") or {}).items():
        walk(p, name)
    return info


def mounts():
    """Mountpoints and filesystem usage per whole disk, for filesystems that live on
    exactly one disk. One spanning several is skipped rather than counted against one
    of them or split between them, since neither would be true."""
    out, seen = {}, set()
    for line in read("/proc/self/mounts").splitlines():
        f = line.split()
        if len(f) < 3 or not f[0].startswith("/dev/") or f[2] == "zfs":
            continue
        src = os.path.realpath(f[0])
        if src in seen or not os.path.exists(src):
            continue
        ds = base_disks(os.path.basename(src))
        if len(ds) != 1:
            continue
        mp = f[1].replace("\\040", " ")
        try:
            st = os.statvfs(mp)
        except OSError:
            continue
        seen.add(src)
        o = out.setdefault(ds.pop(), {"mps": [], "size": 0, "used": 0})
        o["mps"].append(mp)
        o["size"] += st.f_blocks * st.f_frsize
        o["used"] += (st.f_blocks - st.f_bfree) * st.f_frsize
    return out


# ---- SMART, never waking a drive ----------------------------------------------

def smartctl(dev, args, dtype):
    base = ["smartctl"] if os.geteuid() == 0 else ["sudo", "-n", "/usr/sbin/smartctl"]
    extra = ["-d", dtype] if dtype else []
    try:
        return json.loads(run(base + args + ["--json=c"] + extra + [f"/dev/{dev}"]) or "{}")
    except ValueError:
        return {}


def attr(j, ids):
    for a in j.get("ata_smart_attributes", {}).get("table", []):
        if a.get("id") in ids:
            return a
    return None


def parse_smart(j, rota):
    out = {"hours": int(j.get("power_on_time", {}).get("hours", -1))}
    st = j.get("smart_status", {})
    out["health"] = ("PASSED" if st.get("passed") is True
                     else "FAILED" if st.get("passed") is False else "unknown")
    out["temp"] = int(j.get("temperature", {}).get("current", -1))
    out["firmware"] = str(j.get("firmware_version", ""))

    nv = j.get("nvme_smart_health_information_log")
    if nv:
        # NVMe has no reallocated, pending or CRC attributes; media errors are its
        # nearest equivalent and the SMART template already alerts on them.
        out["realloc"] = out["pending"] = out["crc"] = -1
        out["wear"] = int(nv.get("percentage_used", -1))
    else:
        def raw(ids):
            a = attr(j, ids)
            try:
                return int(a["raw"]["value"]) if a else -1
            except (KeyError, TypeError, ValueError):
                return -1
        out["realloc"], out["pending"], out["crc"] = raw([5]), raw([197]), raw([199])
        # SATA SSD wear: vendors disagree on the attribute, but its NORMALISED value
        # counts life remaining from 100 on all of these (Kingston 231 or 169, Samsung
        # 177, Crucial 202, Intel 233), so percent used is 100 minus it. Approximate by
        # nature; NVMe reports it directly. Spinning disks do not wear this way.
        w = None if rota else attr(j, [231, 169, 177, 202, 233])
        out["wear"] = max(0, min(100, 100 - int(w["value"]))) if w and "value" in w else -1

    # Latest self-test, with its age in power-on hours at the time of this read.
    res, when = "none", None
    ata = (j.get("ata_smart_self_test_log", {}).get("standard", {}).get("table") or [])
    nvt = (j.get("nvme_self_test_log", {}).get("table") or [])
    if ata:
        s = ata[0].get("status", {})
        res = ("passed" if s.get("passed") is True
               else "failed" if s.get("passed") is False
               else (s.get("string") or "unknown").split(" ")[0].lower())
        when = ata[0].get("lifetime_hours")
    elif nvt:
        v = nvt[0].get("self_test_result", {}).get("value")
        res = "passed" if v == 0 else "failed"
        when = nvt[0].get("power_on_hours")
    if isinstance(when, int) and out["hours"] >= 0:
        age = max(0, out["hours"] - when)
        res = f"{res} {age}h ago" if age < 48 else f"{res} {age // 24}d ago"
    out["selftest"] = res
    return out


def smart(dev, serial, rota):
    """Power state every run; the full read at most once an hour, only when awake.

    Both carry -n standby, which queries the drive's power mode before anything else
    and stops if it is spun down. The device type that worked (plain, or -d sat for
    USB bridges that need it) is remembered so later runs make one call, not two."""
    blank = {"hours": -1, "health": "unknown", "temp": -1, "firmware": "",
             "realloc": -1, "pending": -1, "crc": -1, "wear": -1,
             "selftest": "unknown", "power": "unknown"}
    if not WANT_SMART or not serial:
        return blank
    path = os.path.join(CACHE_DIR, re.sub(r"[^A-Za-z0-9_.-]", "_", serial) + ".json")
    try:
        cache = json.load(open(path))
        age = time.time() - os.stat(path).st_mtime
    except (OSError, ValueError):
        cache, age = {}, SMART_TTL + 1
    known = {k: cache[k] for k in blank if k in cache}

    dtypes = [cache["dtype"]] if "dtype" in cache else ["", "sat"]
    power, dtype = "unknown", cache.get("dtype", "")
    if dev.startswith("nvme"):
        power, dtype = "active", ""
    else:
        for dt in dtypes:
            j = smartctl(dev, ["-n", "standby", "-i"], dt)
            msgs = " ".join(m.get("string", "") for m in
                            j.get("smartctl", {}).get("messages", [])).upper()
            if "STANDBY" in msgs or "SLEEP" in msgs:
                power, dtype = "standby", dt
                break
            if j.get("serial_number") or j.get("model_name"):
                power, dtype = "active", dt
                break

    out = {**blank, **known, "power": power}
    if power == "active" and age > SMART_TTL:
        j = smartctl(dev, ["-n", "standby", "-H", "-A", "-i", "-l", "selftest"], dtype)
        if j.get("power_on_time") or j.get("smart_status") or j.get("temperature"):
            out.update(parse_smart(j, rota))
            try:
                os.makedirs(CACHE_DIR, exist_ok=True)
                tmp = path + ".tmp"
                with open(tmp, "w") as f:
                    json.dump({**{k: out[k] for k in blank if k != "power"}, "dtype": dtype}, f)
                os.replace(tmp, path)
            except OSError:
                pass
    return out


# ---- assemble ------------------------------------------------------------------

def collect():
    act = activity()
    psi = host_io_psi()
    zf = zfs()
    mt = mounts()
    host = os.uname().nodename.split(".")[0]
    data, drives = [], {}
    for dev in disks():
        size_b = int(read(f"/sys/block/{dev}/size", "0") or 0) * 512
        serial = serial_of(dev)
        name = f"{serial} {human(size_b)}" if serial and size_b else dev
        key = serial or dev
        model = (read(f"/sys/block/{dev}/device/model")
                 or read(f"/sys/block/{dev}/device/model_name"))
        rota = read(f"/sys/block/{dev}/queue/rotational", "1") == "1"
        z, m = zf.get(dev, {}), mt.get(dev, {})

        fs_size = z.get("size", 0) + m.get("size", 0)
        fs_used = z.get("alloc", 0) + m.get("used", 0)
        role = sorted(f"zfs {p}" for p in z.get("pools", ())) + m.get("mps", [])
        s = smart(dev, serial, rota)
        a = act.get(dev, {})

        data.append({"{#DEV}": dev, "{#SERIAL}": key, "{#DRIVE}": name,
                     "{#MODEL}": model, "{#MEDIA}": "HDD" if rota else "SSD"})
        d = drives[key] = {
            "host": host, "serial": serial or dev, "dev": dev, "name": name,
            "model": model, "media": "HDD" if rota else "SSD",
            "link": link_of(dev, model),
            "role": ", ".join(role) if role else "unmounted",
            "size": size_b, "size_h": human(size_b) if size_b else "",
            "fs_size": fs_size if fs_size else -1,
            "fs_used": fs_used if fs_size else -1,
            "fs_pct": round(fs_used * 100 / fs_size, 1) if fs_size else -1,
            "busy": a.get("busy", 0), "wait": a.get("wait", 0.0),
            "queue": a.get("queue", 0.0), "read": a.get("read", 0),
            "write": a.get("write", 0), "host_io_psi": psi,
            "zfs_errors": z.get("errors", 0) if z else -1,
            **s,
        }
        bits = [b for b in (d["size_h"], d["media"]) if b]
        if d["fs_pct"] >= 0:
            bits.append(f'{d["fs_pct"]:.0f}% full')
        if d["hours"] >= 0:
            bits.append(f'{d["hours"]} h')
        if d["health"] != "unknown":
            bits.append(d["health"])
        d["summary"] = ", ".join(bits)
    return {"data": data, "drives": drives}


def main():
    doc = json.dumps(collect())
    if len(sys.argv) == 3 and sys.argv[1] == "--write":
        target = sys.argv[2]
        tmp = target + ".tmp"
        with open(tmp, "w") as f:
            f.write(doc + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    else:
        print(doc)


if __name__ == "__main__":
    main()
