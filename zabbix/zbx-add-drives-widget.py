#!/usr/bin/env python3
"""zbx-add-drives-widget.py: put the Grafana Drives tables on the Zabbix Homelab
dashboard, as a URL widget directly under "Drives, busy percent".

Edits a dashboard file saved by `zbx-dashboard.py get`, in place, so the change is
made to what is live and never to a stale copy. Everything at or below the insert
point moves down by the widget's height. Refuses if that would pass the 64-row page
limit. Run it twice and it updates the widget rather than adding a second one.

  python3 zbx-add-drives-widget.py ~/Downloads/homelab.json
"""
import json, sys

URL = "https://grafana.local.cannon.dev/d/homelab-drives/drives?orgId=1&kiosk&refresh=1m"
NAME, ANCHOR, HEIGHT, PAGE_ROWS = "Drives", "Drives, busy percent", 12, 64

path = sys.argv[1] if len(sys.argv) == 2 else sys.exit(__doc__)
d = json.load(open(path))
pages = d[0]["pages"] if isinstance(d, list) else d["pages"]
ws = pages[0]["widgets"]

anchor = next((w for w in ws if w.get("name") == ANCHOR), None)
if not anchor:
    sys.exit(f"no widget named {ANCHOR!r}; nothing changed")
y = int(anchor["y"]) + int(anchor["height"])

old = next((w for w in ws if w.get("type") == "url" and w.get("name") == NAME), None)
if old:
    # Already there: take it out first, closing its gap, so re-running is a no-op.
    oy, oh = int(old["y"]), int(old["height"])
    ws.remove(old)
    for w in ws:
        if int(w["y"]) >= oy + oh:
            w["y"] = str(int(w["y"]) - oh)

for w in ws:
    if int(w["y"]) >= y:
        w["y"] = str(int(w["y"]) + HEIGHT)
ws.append({"type": "url", "name": NAME, "x": "0", "y": str(y), "width": "72",
           "height": str(HEIGHT), "view_mode": "1",   # header hidden; Grafana titles its own tables
           "fields": [{"type": "1", "name": "url", "value": URL}]})

bottom = max(int(w["y"]) + int(w["height"]) for w in ws)
if bottom > PAGE_ROWS:
    sys.exit(f"would end at row {bottom}, past the {PAGE_ROWS}-row limit; nothing written")
json.dump(d, open(path, "w"), indent=2, sort_keys=True)
print(f"{'updated' if old else 'added'} {NAME!r} at y={y}, {HEIGHT} rows; page now ends at row {bottom}")
for w in sorted(ws, key=lambda w: (int(w["y"]), int(w["x"]))):
    print(f"  y={int(w['y']):>3} x={int(w['x']):>3} {int(w['width']):>3}x{int(w['height']):<3} {w['type']:<12} {w.get('name','')}")
