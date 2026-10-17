#!/usr/bin/env bash
# Walk the CONTRACT.md happy path with curl against a RUNNING stack, using a
# session from the accounts service (no passwords live in this app).
#
#   services/api/scripts/smoke.sh                                   # http://localhost:8083 + http://localhost:8085
#   BASE=https://metrics.3m4.net ACCOUNTS=https://accounts.3m4.net services/api/scripts/smoke.sh
#
# 1. Signs up a throwaway identity at accounts (cookie jar keeps 3m4_session).
# 2. Calls this API with the cookie: /auth/me is reachable unverified,
#    /projects is 403 email_unverified until the mailed link is followed. With
#    Mailpit (local stack) the script consumes the verification token itself.
# 3. Creates a project, sends a hit through the collect API, reads the stats,
#    creates an API key and reads the project back through it.
# Needs curl + jq.
set -euo pipefail

BASE="${BASE:-http://localhost:8083}"
ACCOUNTS="${ACCOUNTS:-http://localhost:8085}"
MAILPIT="${MAILPIT:-http://localhost:8025}"
API="$BASE/api"
EMAIL="${SMOKE_EMAIL:-smoke+$(date +%s)@example.com}"
PASSWORD="${SMOKE_PASSWORD:-Smoke-Passw0rd!}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 smoke"
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

step() { printf '\n\033[36m▶ %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl; need jq

step "health"
curl -fsS "$API/healthz" | jq -c .

step "sign up at accounts as $EMAIL"
curl -fsS -c "$JAR" -b "$JAR" -X POST "$ACCOUNTS/api/auth/signup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | jq -c '{handle: .user.handle, verified: .user.email_verified}'

step "GET /auth/me with the session cookie (allowed while unverified)"
curl -fsS -b "$JAR" "$API/auth/me" | jq -c '{handle: .user.handle, verified: .user.email_verified, account: .account.name, plan}'

step "POST /projects is refused until the e-mail is verified"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -b "$JAR" -X POST "$API/projects" -H 'Content-Type: application/json' \
  -d '{"name":"Smoke project","url":"https://smoke.example"}')
echo "  $CODE (expected 403)"

step "verify the e-mail through Mailpit"
TOKEN=""
for _ in $(seq 1 20); do
  TOKEN=$(curl -sS "$MAILPIT/api/v1/search?query=to:$EMAIL" | jq -r '.messages[0].ID // empty' | \
    xargs -r -I{} curl -sS "$MAILPIT/api/v1/message/{}" | jq -r '.Text // ""' | grep -oE 'verify\?token=[A-Za-z0-9_-]+' | head -1 | cut -d= -f2 || true)
  [ -n "$TOKEN" ] && break
  sleep 1
done
if [ -z "$TOKEN" ]; then
  echo "  no verification mail found at $MAILPIT (production? verify manually, then re-run with SMOKE_EMAIL)"; exit 1
fi
curl -fsS -b "$JAR" -c "$JAR" -X POST "$ACCOUNTS/api/auth/verify/consume" -H 'Content-Type: application/json' \
  -d "{\"token\":\"$TOKEN\"}" | jq -c '{verified: .user.email_verified}'
# A fresh access cookie carries email_verified=true.
curl -fsS -b "$JAR" -c "$JAR" -X POST "$ACCOUNTS/api/session/refresh" -H 'Content-Type: application/json' -d '{}' >/dev/null
echo "  session refreshed"

step "create project"
PROJECT=$(curl -fsS -b "$JAR" -X POST "$API/projects" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Smoke project $(date +%H%M%S)\",\"url\":\"https://smoke.example\"}")
jq -c '{id, key, public_key_prefix}' <<<"$PROJECT"
PID=$(jq -r .id <<<"$PROJECT"); PUB=$(jq -r .public_key <<<"$PROJECT")

step "collect (JSON + X-Project-Key, real browser UA)"
curl -fsS -X POST "$API/collect" -H "X-Project-Key: $PUB" -H 'Content-Type: application/json' -H "User-Agent: $UA" \
  -d '{"u":"https://smoke.example/docs?utm_source=smoke","r":"https://news.ycombinator.com/","t":"Docs","w":1440,"h":900,"l":"es-MX"}' | jq -c .

step "stats"
curl -fsS -b "$JAR" "$API/projects/$PID/stats?period=today" \
  | jq -c '{pageviews: .totals.pageviews, visitors: .totals.visitors}'

step "create an API key (viewer) and read the project back with it"
KEY=$(curl -fsS -b "$JAR" -X POST "$API/apikeys" -H 'Content-Type: application/json' -d '{"name":"smoke","role":"viewer"}' | jq -r .key)
curl -fsS -H "X-API-Key: $KEY" "$API/projects/$PID" | jq -c '{id, name}'

step "no session, no key"
curl -sS -o /dev/null -w '  %{http_code} (expected 401)\n' "$API/projects"

if [ "${KEEP:-0}" != 1 ]; then
  step "cleanup (KEEP=1 to skip)"
  curl -fsS -b "$JAR" -X DELETE "$API/projects/$PID" -o /dev/null -w '  delete project -> HTTP %{http_code}\n'
fi

step "log out at accounts; the cookie is gone"
curl -fsS -b "$JAR" -c "$JAR" -X POST "$ACCOUNTS/api/session/logout" -H 'Content-Type: application/json' -d '{}' -o /dev/null
curl -sS -o /dev/null -w '  %{http_code} (expected 401)\n' -b "$JAR" "$API/auth/me"
printf '\n\033[32m✓ smoke complete\033[0m\n'
