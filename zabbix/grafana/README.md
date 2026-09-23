# Grafana dashboards

Grafana on `grf` is where the homelab's Zabbix data is **looked at**. Zabbix stays
the monitoring system: it collects, stores, triggers, alerts, and holds maintenance
windows, acknowledgements and runbook links. Grafana never alerts. Plan and
decisions: Kan `x79x4lcj9dqt`.

Everything here reaches Grafana through its API with `zabbix/grafana-api.py`, never
by editing in the Grafana interface. A dashboard built by hand exists only in
Grafana's database, cannot be reviewed and cannot be rebuilt; a file here can.

## Layout

```
dashboards/<Folder name>/<name>.json   one dashboard; the directory is its folder
datasources/<name>.json                one data source; secrets by placeholder only
```

Every dashboard carries a fixed `uid` (`homelab-<name>`), so a put replaces rather
than duplicates and links between dashboards stay valid.

## Workflow

```
python3 zabbix/grafana-api.py check dashboards/Homelab/<name>.json   # queries run, rows come back
python3 zabbix/grafana-api.py diff                                    # what would change
python3 zabbix/grafana-api.py put-all --apply                         # write what differs
```

`check` runs every panel's queries through Grafana's server and prints the rows, so a
panel is proven against real data before anyone looks at it. Queries that only run
in the browser (the Zabbix plugin's text and problems modes) are listed as "check by
eye". Writes are dry runs until `--apply`. Nothing is ever deleted by the tool.

After Grafana is upgraded, `get-all` captures whatever it migrated, so the files
never drift from what is live.

## Data sources

| Placeholder | Data source | Use it for |
|---|---|---|
| `${DS_ZABBIX}` | Zabbix plugin | numeric time series; it runs these on Grafana's server |
| `${DS_INFINITY}` | Infinity, `Zabbix API` | tables and anything with text: one `item.get`, pivoted with JSONata |
| `${DS_LOKI}` | Loki | logs, by Alloy's `host` label |

The Zabbix plugin's text mode runs only in the browser, so text columns come through
Infinity. Infinity returns the fields of a JSONata pivot in alphabetical order, so
every pivoted table carries an `organize` transformation that sets the column order.

Data source files are written with `ds-put`, which needs the separate admin token
(`claude-admin`, decision D2). Secrets appear only as `${SECRET:<name>}`, read from
`~/.config/grafana/secrets/<name>` on the laptop, and are never committed.

## Standards

**Red is the value the trigger fires at.** A colour that disagrees with the alerting
teaches a reading the alerts then contradict. Amber is ten points below the trigger
for levels (utilisation, space, temperature) and half the trigger for pressure, which
already measures waiting. Where nothing alerts, nothing is coloured: the drive wait
column stays plain until its threshold is chosen from data.

| Colour | Hex | Meaning |
|---|---|---|
| amber | `FCCB1D` | approaching the trigger |
| red | `E65660` | at or past the trigger |
| green | `4CAF50` | an explicit good state (PASSED, passed self-test) only |

**Series colours carry identity, not severity.** Lines are coloured per host and
never red, yellow or anything close, so a line is never mistaken for an alert:
pve0 `2774A4`, pve1 `1A7C11`, pve2 `6C59DC`, pve3 `00A6BF`, pve4 `A64BC4`, pms0 `546E7A`.
The same host is the same colour on every panel.

**Values that do not apply are -1, shown as a dash**, never 0. A ZFS pool member has
no filesystem of its own and an NVMe drive has no reallocated-sector count; a 0 in
either would read as a false "fine".

**Tables are one row per thing**, whatever the thing is: a host, a drive, a pool.
Identity columns come first (host, then serial or name), rows sort by them so the
order holds still between refreshes, and a column is wide enough for its longest
real value (`Serial` is 200 px for pve0's 20-character serial).

**Units come from Grafana**, not from text in the value: bytes as `decbytes`, rates as
`Bps`, times as `ms`, temperatures as `celsius`. Refresh is one minute.

**Variables over copies.** One dashboard with a host dropdown, not a panel per host;
panels repeat per value where a row per host is wanted.
