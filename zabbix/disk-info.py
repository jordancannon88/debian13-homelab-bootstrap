#!/usr/bin/env python3
"""disk-info.py: every whole disk on this machine as one JSON document, for the
Zabbix UserParameter custom.diskinfo (template "Homelab drives").

Why this exists. Until 2026-09-22 a disk could only be looked at through a table
with one row per HOST, so a node with three drives had to squeeze three drives
into one cell, and the Top hosts widget cut that cell at 20 characters. The fix
is a row per drive, and a row per drive needs an item per drive, which needs
discovery. Discovery also buys what the ranked slots could never give: a drive
keeps its identity, so its history means one drive, and a trigger can name it.

What it does NOT do is alert. The SMART template already discovers these drives
and already fires on health, temperature, reallocated sectors and failed
self-tests. Collecting those again would give the fleet two opinions about the
same drive. Hours, health and temperature are carried here only so a drive reads
as one line on a dashboard, and they carry no triggers.

Drives are keyed by SERIAL, not by device letter. sdb is not a drive, it is
whatever the kernel enumerated second this boot: the 6 TB disk is sdc on pve2 and
sdb on pve3, and the USB enclosure renumbers when it is re-enumerated. The SMART
template keys on the device letter, which is why its items and these do not share
a name.

Sleeping drives are never woken. smartctl runs with -n standby, which returns
without touching a disk that is spun down, and its answers are cached for an hour
so a poll every minute does not mean a SMART read every minute. A drive that is
parked keeps whatever was last read and reports health "standby".
"""
import json, os, re, subprocess, sys, time

DEV_RE = re.compile(r"^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)$")
CACHE_DIR = os.environ.get("DISKINFO_CACHE", "/var/tmp/zbx-diskinfo")
SMART_TTL = int(os.environ.get("DISKINFO_SMART_TTL", "3600"))
WANT_SMART = os.environ.get("DISKINFO_SMART", "1") == "1"
SAMPLE = float(os.environ.get("DISKINFO_SAMPLE", "1"))


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def disks():
    return sorted(d for d in os.listdir("/sys/block") if DEV_RE.match(d))


def serial_of(dev):
    """Serial from the by-id symlink built out of the ATA or NVMe identity, which is
    the same string the rest of the homelab names drives by. The EUI form of an NVMe
    link carries no serial, and a partition link names its parent, so both are
    skipped."""
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
    if tb >= 1:
        return f"{tb:.0f} TB"
    return f"{size_b / 1000 ** 3:.0f} GB"


def io_ticks():
    """Field 10 of /proc/diskstats: milliseconds with at least one request in flight."""
    out = {}
    for line in read("/proc/diskstats").splitlines():
        f = line.split()
        if len(f) >= 13 and DEV_RE.match(f[2]):
            out[f[2]] = int(f[9])
    return out


def busy_percent():
    """Percent of the sample window each disk had a request in flight. Elapsed time is
    measured rather than assumed: the sleep plus two passes over diskstats always runs
    somewhat over the nominal window, and treating the window as exactly 1000 ms is
    what made every reading ten times too high before 2026-09-22."""
    t0, c0 = io_ticks(), time.monotonic()
    time.sleep(SAMPLE)
    t1, c1 = io_ticks(), time.monotonic()
    ms = max(1.0, (c1 - c0) * 1000.0)
    return {d: max(0, min(100, round((t1[d] - t0.get(d, t1[d])) * 100 / ms)))
            for d in t1}


def parent_disk(name):
    """The whole disk a block device belongs to: sda3 -> sda, nvme0n1p3 -> nvme0n1."""
    if os.path.exists(f"/sys/class/block/{name}/partition"):
        return os.path.basename(os.path.dirname(os.path.realpath(f"/sys/class/block/{name}")))
    return name


def base_disks(name, seen=None):
    """Every whole disk underneath a block device, following device mapper down.

    An LVM volume is /dev/dm-0, which is not a disk and never matches one by name.
    Its slaves directory names the partitions it is built from, so the walk has to go
    through it or every LVM filesystem looks like it lives nowhere. Recursion is
    guarded because stacked mappers can name each other."""
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


def zfs_space():
    """Bytes allocated and usable per member device, from the pool itself.

    Without this every node reads -1, because a ZFS vdev has no mountpoint: the pool
    is mounted and the member is not. zpool reports size and alloc per leaf device, so
    the drive can be asked directly rather than inferred from the pool. It needs no
    root and touches no disk."""
    out = {}
    try:
        p = subprocess.run(["zpool", "list", "-vHp"],
                           capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return out
    for line in p.stdout.splitlines():
        if not line.startswith("\t"):
            continue                      # a pool, not a member
        f = line.strip().split("\t")
        if len(f) < 4 or f[0].startswith(("mirror", "raidz", "draid", "spare",
                                          "log", "cache", "special", "dedup")):
            continue                      # a vdev grouping, whose children follow
        try:
            size, alloc = int(f[1]), int(f[2])
        except ValueError:
            continue                      # "-" where a device carries no figures
        for cand in (f"/dev/disk/by-id/{f[0]}", f"/dev/{f[0]}", f[0]):
            try:
                real = os.path.realpath(cand)
            except OSError:
                continue
            if os.path.exists(real):
                for d in base_disks(os.path.basename(real)):
                    t, u = out.get(d, (0, 0))
                    out[d] = (t + size, u + alloc)
                break
    return out


def space_map():
    """Bytes used and total per whole disk, across mounted filesystems and ZFS pools.

    A disk with nothing that maps to it is absent, and reads -1 later, which is the
    honest answer rather than zero: claiming a full drive is 0 percent used would be
    worse than saying nothing. A filesystem spanning several disks is skipped rather
    than counted against one of them or split between them, because neither would be
    true."""
    out = dict(zfs_space())
    seen = set()
    for line in read("/proc/self/mounts").splitlines():
        f = line.split()
        if len(f) < 2 or not f[0].startswith("/dev/"):
            continue
        src = os.path.realpath(f[0])
        if src in seen or not os.path.exists(src):
            continue
        disks = base_disks(os.path.basename(src))
        if len(disks) != 1:
            continue
        mp = f[1].replace("\\040", " ")
        try:
            st = os.statvfs(mp)
        except OSError:
            continue
        seen.add(src)
        d = disks.pop()
        t, u = out.get(d, (0, 0))
        out[d] = (t + st.f_blocks * st.f_frsize,
                  u + (st.f_blocks - st.f_bfree) * st.f_frsize)
    return out


def smart(dev, serial):
    """Hours, health and temperature, read at most once an hour and never from a disk
    that is spun down.

    -n standby is the whole point: it returns without waking the drive. A parked drive
    therefore keeps whatever was last read and reports health "standby", which is not
    a fault. USB bridges usually need -d sat, so a plain read that comes back with
    nothing is retried that way once."""
    blank = {"hours": -1, "health": "unknown", "temp": -1}
    if not WANT_SMART or not serial:
        return blank
    path = os.path.join(CACHE_DIR, f"{re.sub(r'[^A-Za-z0-9_.-]', '_', serial)}.json")
    try:
        if time.time() - os.stat(path).st_mtime < SMART_TTL:
            return {**blank, **json.load(open(path))}
    except (OSError, ValueError):
        pass

    # The agent runs as zabbix, which reaches smartctl only through the sudoers rule
    # the SMART setup installs (zabbix ALL=(root) NOPASSWD: /usr/sbin/smartctl). Run
    # by hand as root it needs no sudo, and a machine without that rule simply gets
    # health "unknown" rather than an error.
    cmd = (["smartctl"] if os.geteuid() == 0 else ["sudo", "-n", "/usr/sbin/smartctl"])
    got = None
    for extra in ([], ["-d", "sat"]):
        try:
            p = subprocess.run(cmd + ["-n", "standby", "-H", "-A", "-i",
                                      "--json=c"] + extra + [f"/dev/{dev}"],
                               capture_output=True, text=True, timeout=30)
            j = json.loads(p.stdout or "{}")
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        if j.get("power_on_time") or j.get("smart_status") or j.get("temperature"):
            got = j
            break

    out = dict(blank)
    if got is None:
        out["health"] = "standby"
    else:
        out["hours"] = int(got.get("power_on_time", {}).get("hours", -1))
        st = got.get("smart_status", {})
        out["health"] = ("PASSED" if st.get("passed") is True
                         else "FAILED" if st.get("passed") is False else "unknown")
        out["temp"] = int(got.get("temperature", {}).get("current", -1))
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(out, f)
        os.replace(tmp, path)
    except OSError:
        pass
    return out


def main():
    busy = busy_percent()
    space = space_map()
    data, drives = [], {}
    for dev in disks():
        size_b = int(read(f"/sys/block/{dev}/size", "0") or 0) * 512
        serial = serial_of(dev)
        name = f"{serial} {human(size_b)}" if serial and size_b else dev
        key = serial or dev
        model = read(f"/sys/block/{dev}/device/model") or read(f"/sys/block/{dev}/device/model_name")
        rota = read(f"/sys/block/{dev}/queue/rotational", "1") == "1"
        total, used = space.get(dev, (-1, -1))
        s = smart(dev, serial)
        data.append({"{#DEV}": dev, "{#SERIAL}": key, "{#DRIVE}": name,
                     "{#MODEL}": model, "{#MEDIA}": "HDD" if rota else "SSD"})
        drives[key] = {
            "dev": dev, "name": name, "model": model,
            "media": "HDD" if rota else "SSD",
            "size": size_b, "size_h": human(size_b) if size_b else "",
            "busy": busy.get(dev, 0),
            "fs_size": total, "fs_used": used,
            "fs_pct": round(used * 100 / total, 1) if total > 0 else -1,
            "hours": s["hours"], "health": s["health"], "temp": s["temp"],
        }
        # One line describing the drive, for a view that has room for a drive per row
        # but not for a column per fact. Busy percent is deliberately absent: it moves
        # every minute and everything else here moves once an hour at most, so mixing
        # them would make the line churn for no reading.
        d = drives[key]
        bits = [b for b in (d["size_h"], d["media"]) if b]
        if d["fs_pct"] >= 0:
            bits.append(f'{d["fs_pct"]:.0f}% full')
        if d["hours"] >= 0:
            bits.append(f'{d["hours"]} h')
        if d["health"] not in ("unknown",):
            bits.append(d["health"])
        d["summary"] = ", ".join(bits)
    json.dump({"data": data, "drives": drives}, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
