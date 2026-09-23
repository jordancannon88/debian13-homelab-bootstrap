#!/usr/bin/env python3
"""zbx-fix-cputemp-gauges.py: make the five CPU temperature gauges on the Homelab
dashboard turn amber and red where the triggers fire, 90 and 100 degrees C.

They were amber at 85 and red at 95, so a gauge went red five degrees before
anything alerted, which breaks the rule the rest of the dashboard follows: red is
the value the trigger fires at (zabbix/dashboards/README.md). The gauge maximum
moves from 100 to 110, because a red band starting at the maximum has no width
and would never show.

Edits a dashboard file saved by `zbx-dashboard.py get`, in place. Safe to rerun.

  python3 zbx-fix-cputemp-gauges.py ~/Downloads/homelab.json
"""
import json, sys

AMBER, RED, MAX = "90", "100", "110"
path = sys.argv[1] if len(sys.argv) == 2 else sys.exit(__doc__)
d = json.load(open(path))
pages = d[0]["pages"] if isinstance(d, list) else d["pages"]
done = 0
for w in pages[0]["widgets"]:
    if w.get("type") != "gauge" or w.get("name") not in {f"PVE{i}" for i in range(5)}:
        continue
    f = {x["name"]: x for x in w["fields"]}
    # Steps 0 and 1 are the cold and normal bands; 2 is amber, 3 is red.
    if "thresholds.2.threshold" not in f or "thresholds.3.threshold" not in f or "max" not in f:
        sys.exit(f"{w['name']}: threshold layout not as expected; nothing written")
    f["thresholds.2.threshold"]["value"] = AMBER
    f["thresholds.3.threshold"]["value"] = RED
    f["max"]["value"] = MAX
    done += 1
if done != 5:
    sys.exit(f"found {done} of 5 CPU gauges; nothing written")
json.dump(d, open(path, "w"), indent=2, sort_keys=True)
print(f"5 gauges: amber {AMBER}, red {RED}, max {MAX}")
