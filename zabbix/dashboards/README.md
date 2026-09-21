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
