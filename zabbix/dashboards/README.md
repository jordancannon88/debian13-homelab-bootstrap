# Zabbix dashboards, captured

Zabbix has no import or export for global dashboards in its interface, so a
dashboard built by hand exists in one place only: the server's database. These
JSON files are captures made with `zabbix/zbx-dashboard.py`, kept here so a
dashboard is reviewable in a commit and restorable after a bad edit.

    python3 zbx-dashboard.py list                     what exists
    python3 zbx-dashboard.py get-all <dir>            capture everything
    python3 zbx-dashboard.py diff <file>              what changed on the server
    python3 zbx-dashboard.py put <file>               write one back

The API role needs `dashboard.get` to capture and diff, and the create and
update methods to write back. Writing also needs the dashboard shared with the
API user as read-write, and the role's Monitoring > Dashboards interface element
enabled: without the latter the write is refused with a method-permission error
even though the method is on the allow list.

Sharing is never captured and never written. Who may see or edit a dashboard is
an access decision that belongs to the server, not to a file in a repository. An
early version sent `users`, `userGroups` and `private` back with every write,
which silently reverted a share granted after the capture was taken.

Host and item patterns in a graph data set accept `*` only. `pve?` matches
nothing and draws an empty graph.

## The trap these captures exist to catch

Every column of a Top hosts widget carries its own aggregation setting. A column
set to `max` over a time window holds the highest value seen in that window, so a
brief spike reads as a standing figure until the window passes. On 2026-09-20 and
21 that made grf report 99 % memory and seafile-keeper 99 % CPU while both were
idle; the spikes were Ansible and fleet-check runs. Columns that answer "what is
happening now" belong on `aggregate_function: 0`, last value, with history on
auto.

One exception is worth knowing rather than fixing blindly: on a monotonic counter
such as uptime, `max` looks harmless because the newest value is the highest. It
is not. After a reboot the counter resets to zero while `max` keeps showing the
pre-reboot value for the length of the window, hiding the restart.

## Checking a capture

    python3 - <<'PY'
    import json, collections
    d = json.load(open('zabbix/dashboards/homelab.json'))
    for p in d['pages']:
        for w in p['widgets']:
            if w['type'] != 'tophosts': continue
            cols = collections.defaultdict(dict)
            for f in w['fields']:
                if f['name'].startswith('columns.'):
                    _, i, k = f['name'].split('.', 2)
                    cols[i][k] = f['value']
            for i in sorted(cols, key=int):
                c = cols[i]
                if str(c.get('aggregate_function', '0')) != '0':
                    print(w.get('name'), c.get('name'), 'aggregates')
    PY

## What the captured Homelab dashboard contains

Sixteen widgets in one page: five per-node gauges, six Top hosts tables (uptime,
CPU and memory, once for nodes and once for guests), three pressure graphs, the
problems list and the system information panel.

The three pressure graphs each carry one data set per node rather than a single
data set listing five hosts. That is deliberate: a data set gets one colour, so a
single set of five hosts leaves Zabbix to assign colours from a palette in
whatever order it resolves them, and the same node ends up a different colour on
each graph. One set per node pins it:

| Node | Colour |
|---|---|
| pve0 | 2774A4 blue |
| pve1 | 1A7C11 green |
| pve2 | 6C59DC violet |
| pve3 | FFA400 amber |
| pve4 | F63100 red |

The items differ per graph on purpose. CPU uses the five minute "some" figure the
alert thresholds against, so it moves deliberately rather than spiking on every
command. Memory and IO use "full", which means every task was stalled rather than
merely one waiting, and is what their alerts use.

## An empty graph is usually the time selector

The dashboard's time range lives in the viewing user's profile, not in the
dashboard, so it is neither captured nor restored by a `put`. On 2026-09-21 the
selector was left on an absolute two hour window from 11 June, which drew every
graph empty while the tables and gauges read live values, because those use last
value and ignore the range. Check the selector before doubting a definition, and
prefer a relative range such as "Last 1 hour", since an absolute one goes stale
the moment you leave it.

## Line colours on the pressure graphs

Red and amber are reserved. Zabbix paints problem severity in those colours
everywhere else in the interface, so a host line in red or yellow reads as an
alert when it is only a host. The three pressure graphs therefore use cool
colours only, the same colour for a node on all three, so a line can be followed
across CPU, memory and IO without re-reading the legend:

| Node | Colour |
|---|---|
| pve0 | `2774A4` blue |
| pve1 | `1A7C11` green |
| pve2 | `6C59DC` violet |
| pve3 | `00A6BF` cyan |
| pve4 | `A64BC4` purple-magenta |

pve3 was amber and pve4 was red until 2026-09-21. Keep any node added later in
the cool half of the wheel, and give it a hue away from violet and magenta, which
are the closest pair in the set above.

## Thresholds on the Top hosts columns

The rule, applied 2026-09-21: **red is the number the trigger actually fires at.**
A dashboard whose colours disagree with the alerting is worse than no colours,
because it teaches a reading that the alerts then contradict.

| Column | Amber | Red | Trigger it matches |
|---|---|---|---|
| CPU utilization, CPU use (own) | 80 | 90 | `{$CPU.UTIL.CRIT}`, `{$LXC.CPU.UTIL.CRIT}` = 90 |
| Memory use (no ARC), Memory utilization | 80 | 90 | `{$MEMORY.UTIL.NOARC.MAX}` = 90 |
| CPU pressure (some 300s) | 25 | 50 | `{$PSI.CPU.SOME.WARN}` = 50 |
| Memory pressure (full 60s) | 5 | 10 | `{$PSI.MEM.FULL.WARN}` = 10 |

Amber is set differently for the two kinds of metric, on purpose. Utilization is a
level, so only the approach to the limit is interesting and amber sits ten points
below the trigger. Pressure already measures waiting, so half the trigger is a
meaningful early band.

Three faults were fixed. Memory pressure went amber at 10 and red at 50, so the
column still read as mild after the High trigger had already fired at 10; that was
the serious one. Both utilization columns went amber at 50, which is ordinary load
on a hypervisor and had every node yellow through every backup window, which is how
a colour stops being read at all. And the CPU widgets used a different palette from
the memory widgets for the same three steps, so the same meaning had two
appearances. Everything now uses `FCCB1D` and `E65660`, the pair the pressure
columns already used.

Red and amber are correct here, unlike on the graph lines above, because these
colours carry severity rather than identity.

## The CPU temperature gauges

Five gauge widgets, one per node, `description: CPU °C`. Two things about them are
worth knowing before touching them.

**They reference items by numeric id**, because a Zabbix gauge is a single-item
widget and takes an itemid, not a host and item name the way the Top hosts columns
do. Two consequences. This file only restores correctly onto the server it was
captured from: the ids 59480, 55544, 50816, 54958 and 50815 mean nothing elsewhere.
And if one of those items is ever recreated, by a re-import with Delete missing on,
a host being re-added, or rediscovery, the gauge goes blank rather than erroring, so
nothing tells you it stopped working. Check them with `zabbix/zbx-item.py` after any
such change.

**Nothing alerts on CPU temperature.** No Homelab template carries a temperature
item or trigger for the CPU; the disk temperature work on Kan s24n9c7q8aye covers
SMART only. So these gauges are the only place a hot CPU appears, and a gauge warns
whoever happens to be looking at the dashboard. That is the same fault as a
threshold that disagrees with its trigger, one step worse: there is no trigger at
all.

Scale and thresholds, set 2026-09-21: range 20 to 100, blue from 20, green from 45,
amber at 85, red at 95. The range was 0 to 120, which spent its top fifth on values
no sensor in the fleet can reach and put every real reading in the lower half of the
arc. 100 is roughly where these CPUs begin thermal throttling, so the top of the arc
now means something. Amber was at 80, which a NUC reaches under an ordinary backup.
