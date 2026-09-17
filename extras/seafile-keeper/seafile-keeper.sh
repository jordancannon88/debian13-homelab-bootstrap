#!/bin/bash
# seafile-keeper.sh: keep an encrypted Seafile library's password warm on the server.
# Seafile caches a library password for one hour (hard-coded in seaf-server) and the
# mobile app does not re-send it for background uploads, so uploads into an encrypted
# library fail with a bare HTTP 500 after an idle hour. This calls the "set library
# password" API every run (a timer runs it every 50 minutes and at boot).
# Secrets live in /etc/seafile-keeper/env (root, 0600):
#   SEAFILE_URL=https://seafile.example        SEAFILE_TOKEN=<api token>
#   REPO_ID=<library id>                       REPO_PASSWORD=<library password>
# State: /var/lib/seafile-keeper/last_ok (epoch of the last success) for Zabbix.
set -u
ENV=/etc/seafile-keeper/env
STATE=/var/lib/seafile-keeper
[ -r "$ENV" ] || { echo "missing $ENV" >&2; exit 2; }
# shellcheck disable=SC1090
. "$ENV"
: "${SEAFILE_URL:?}" "${SEAFILE_TOKEN:?}" "${REPO_ID:?}" "${REPO_PASSWORD:?}"
mkdir -p "$STATE"
body=$(curl -sS --max-time 30 -o /dev/stderr -w '%{http_code}' \
  -H "Authorization: Token $SEAFILE_TOKEN" \
  --data-urlencode "password=$REPO_PASSWORD" \
  "$SEAFILE_URL/api2/repos/$REPO_ID/" 2>"$STATE/last_response") ; rc=$?
if [ $rc -eq 0 ] && [ "$body" = "200" ]; then
  date +%s > "$STATE/last_ok"
  echo "ok: password set for $REPO_ID (HTTP 200)"
  exit 0
fi
echo "FAILED: curl rc=$rc http=$body body=$(tr -d '\n' < "$STATE/last_response" | cut -c1-120)" >&2
exit 1
