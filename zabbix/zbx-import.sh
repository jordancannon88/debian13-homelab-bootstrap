#!/usr/bin/env bash
# zbx-import.sh: import a Zabbix template YAML through the JSON-RPC API with the
# house import rules, so no scp + GUI dance is needed.
#
#   zbx-import.sh <template.yaml>                 standard rules
#   zbx-import.sh --delete-triggers <template.yaml>   also Triggers: Delete missing on
#                                                  (a trigger was renamed or removed)
#   zbx-import.sh --delete-items <template.yaml>      also Items, Discovery rules and
#                                                  Triggers: Delete missing on (an item
#                                                  key changed); never for the stock
#                                                  SMART template
#
# Rules applied (the same table used in the GUI on every import):
#   Template groups   untouched (creating a group needs Super admin; make it in the GUI first)
#   Templates         update + create
#   Template linkage  update + create
#   Items             update + create (+ delete missing with --delete-items)
#   Discovery rules   update + create (+ delete missing with --delete-items)
#   Triggers          update + create (+ delete missing with --delete-triggers)
#   Value mappings   update + create (template-scoped)
#   Template dashboards, graphs, web scenarios, host groups: untouched
#
# Needs: the token of the `claude` API user (role Template importer, API allow
# list configuration.import/export) in ~/.config/zabbix/token (0600), curl,
# python3. Runs from a machine that can reach the Zabbix frontend (the laptop;
# the dev box cannot). Set ZBX_URL if the frontend is not at the default.
set -euo pipefail

ZBX_URL="${ZBX_URL:-https://zabbix.local.cannon.dev/api_jsonrpc.php}"
TOKEN_FILE="${ZBX_TOKEN_FILE:-$HOME/.config/zabbix/token}"

delete_triggers=false; delete_items=false
while [ "${1:-}" = "--delete-triggers" ] || [ "${1:-}" = "--delete-items" ]; do
  [ "$1" = "--delete-triggers" ] && delete_triggers=true
  [ "$1" = "--delete-items" ] && { delete_items=true; delete_triggers=true; }
  shift
done
yaml="${1:-}"
[ -n "$yaml" ] && [ -r "$yaml" ] || { echo "usage: $0 [--delete-triggers] <template.yaml>" >&2; exit 2; }
[ -r "$TOKEN_FILE" ] || { echo "no token at $TOKEN_FILE" >&2; exit 2; }
token=$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')

# Build the request with python so the YAML is JSON-escaped correctly.
req=$(python3 - "$yaml" "$delete_triggers" "$delete_items" <<'PY'
import json, sys
src = open(sys.argv[1], encoding="utf-8").read()
dt = sys.argv[2] == "true"
di = sys.argv[3] == "true"
uc = {"updateExisting": True, "createMissing": True}
rules = {
    "template_groups": {"createMissing": False},   # creating groups needs Super admin; Templates/Custom exists
    "templates": uc,
    "templateLinkage": {"createMissing": True, "deleteMissing": False},
    "items": {**uc, "deleteMissing": di},
    "discoveryRules": {**uc, "deleteMissing": di},
    "triggers": {**uc, "deleteMissing": dt},
    "host_groups": {"createMissing": False},
    "valueMaps": {"updateExisting": True, "createMissing": True, "deleteMissing": False},   # template-scoped in 7.x
    "templateDashboards": {"updateExisting": False, "createMissing": False, "deleteMissing": False},
    "graphs": {"updateExisting": False, "createMissing": False, "deleteMissing": False},
    "httptests": {"updateExisting": False, "createMissing": False, "deleteMissing": False},
}
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "configuration.import",
                  "params": {"format": "yaml", "source": src, "rules": rules}}))
PY
)

name=$(grep -m1 -E "^\s+template: '" "$yaml" | sed "s/.*template: '\(.*\)'/\1/")
echo "importing '${name:-?}' from $yaml (delete missing: triggers=$delete_triggers items=$delete_items)"
resp=$(curl -sS --fail-with-body -X POST "$ZBX_URL" \
  -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $token" \
  --data-binary "$req") || { echo "HTTP error from $ZBX_URL:"; echo "$resp"; exit 1; }
python3 - "$resp" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
if "error" in r:
    e = r["error"]; print(f"IMPORT FAILED: {e.get('message')}: {e.get('data')}"); sys.exit(1)
print("import ok:", r.get("result"))
PY
