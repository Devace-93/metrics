#!/usr/bin/env sh
# Smoke test for a running metrics stack: health, tracker headers, collect round-trip.
#   BASE_URL=http://localhost:8083 sh deploy/smoke.sh
# Identity lives at accounts.3m4.net: the script signs up a throwaway identity
# there (ACCOUNTS_URL, default http://localhost:8085), verifies it through
# Mailpit (MAILPIT_URL, default http://localhost:8025) and calls this API with
# the 3m4_session cookie. Needs signups ON in both stacks.
set -eu
BASE_URL="${BASE_URL:-http://localhost:8083}"
ACCOUNTS_URL="${ACCOUNTS_URL:-http://localhost:8085}"
MAILPIT_URL="${MAILPIT_URL:-http://localhost:8025}"
API="$BASE_URL/api"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 smoke"
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

say() { printf '\033[36m▸ %s\033[0m\n' "$1"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need curl; need python3

say "health"
curl -fsS "$API/healthz" | grep -q '"ok"' && echo "  api ok"

say "tracker headers"
curl -fsS -o /dev/null -D - "$BASE_URL/m.js" | tr -d '\r' | grep -iE '^(content-type|cache-control|access-control-allow-origin):' | sed 's/^/  /'

say "session from accounts + verified e-mail"
EMAIL="smoke+$(date +%s)@example.com"
curl -fsS -c "$JAR" -b "$JAR" -X POST "$ACCOUNTS_URL/api/auth/signup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"Smoke-Passw0rd!\"}" >/dev/null
TOKEN=""
i=0
while [ $i -lt 20 ] && [ -z "$TOKEN" ]; do
  TOKEN=$(curl -sS "$MAILPIT_URL/api/v1/search?query=to:$EMAIL" | python3 -c '
import json, sys, urllib.request, re
base = sys.argv[1]
msgs = json.load(sys.stdin).get("messages") or []
for m in msgs:
    mid = m["ID"]
    body = json.load(urllib.request.urlopen(f"{base}/api/v1/message/{mid}"))
    found = re.search(r"verify\?token=([A-Za-z0-9_-]+)", (body.get("Text") or "") + (body.get("HTML") or ""))
    if found:
        print(found.group(1)); break
' "$MAILPIT_URL" || true)
  [ -z "$TOKEN" ] && sleep 1
  i=$((i + 1))
done
[ -n "$TOKEN" ] || { echo "  no verification mail at $MAILPIT_URL" >&2; exit 1; }
curl -fsS -b "$JAR" -c "$JAR" -X POST "$ACCOUNTS_URL/api/auth/verify/consume" -H 'Content-Type: application/json' -d "{\"token\":\"$TOKEN\"}" >/dev/null
curl -fsS -b "$JAR" -c "$JAR" -X POST "$ACCOUNTS_URL/api/session/refresh" -H 'Content-Type: application/json' -d '{}' >/dev/null
echo "  $EMAIL verified"

say "project"
PROJECT=$(curl -fsS -b "$JAR" -X POST "$API/projects" -H 'Content-Type: application/json' \
  -d '{"name":"Smoke project","url":"https://smoke.example"}')
PID=$(printf '%s' "$PROJECT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
PUB=$(printf '%s' "$PROJECT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')
echo "  project $PID ($PUB)"

say "collect (JSON + header)"
curl -fsS -X POST "$API/collect" -H "X-Project-Key: $PUB" -H 'Content-Type: application/json' -H "User-Agent: $UA" \
  -d '{"u":"https://smoke.example/docs?utm_source=smoke","r":"https://news.ycombinator.com/","t":"Docs","w":1440,"h":900,"l":"es-MX"}' | sed 's/^/  /'; echo

say "collect (text/plain, like the tracker)"
curl -fsS -X POST "$API/collect" -H 'Content-Type: text/plain' -H "User-Agent: $UA" \
  --data-raw "{\"k\":\"$PUB\",\"n\":\"signup\",\"u\":\"https://smoke.example/pricing\",\"p\":{\"plan\":\"pro\"}}" | sed 's/^/  /'; echo

say "pixel"
curl -fsS -o /dev/null -w "  %{http_code} %{content_type}\n" "$API/collect/pixel.gif?k=$PUB&u=/newsletter" -H "User-Agent: $UA"

say "stats"
curl -fsS "$API/projects/$PID/stats?period=today" -b "$JAR" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d["totals"]; print("  %d page views, %d visitors, %d events; pages: %s" % (t["pageviews"], t["visitors"], t["events"], ", ".join(r["value"] for r in d["breakdowns"]["path"])))'

say "cleanup"
curl -fsS -X DELETE "$API/projects/$PID" -b "$JAR" && echo "  project deleted"
curl -fsS -b "$JAR" -c "$JAR" -X POST "$ACCOUNTS_URL/api/session/logout" -H 'Content-Type: application/json' -d '{}' -o /dev/null && echo "  logged out"
echo "smoke ok"
