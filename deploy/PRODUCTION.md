# Production runbook

metrics runs on the same Hetzner box as the 3m4 shortener (`/opt/3m4`), exp
(`/opt/exp`) and retro (`/opt/retro`). The 3m4 stack's Caddy owns ports 80/443,
so metrics is deployed as another docker compose project without its own Caddy,
and the 3m4 Caddy routes `metrics.3m4.net` to it over the shared `edge` docker
network.

**Already deployed before the accounts migration?** Append these to `.env` and rebuild
(the public accounts URL is baked into the web bundle at build time):

```
ACCOUNTS_URL=https://accounts.3m4.net
ACCOUNTS_INTERNAL_URL=http://accounts-api-1:5000
VITE_ACCOUNTS_URL=https://accounts.3m4.net
PROTOCOL_HEADER=x-forwarded-proto
```
then `docker compose --env-file ../.env -f docker-compose.yml -f docker-compose.prod.yml up -d --build web api`
from `deploy/`. Without `ACCOUNTS_URL` the API rejects every session (issuer mismatch);
without `PROTOCOL_HEADER` the login redirect carries an `http://` return address that
accounts refuses, so users land on their profile instead of the dashboard.

## First-time setup

1. **Shared network** (once per server; already there if exp is deployed):
   ```sh
   docker network inspect edge >/dev/null 2>&1 || docker network create edge
   ```
2. **Clone + configure**
   ```sh
   git clone git@github.com:Devace-93/metrics.git /opt/metrics
   cd /opt/metrics && cp .env.example .env && $EDITOR .env
   ```
   Prod `.env` checklist: `APP_BASE_URL=https://metrics.3m4.net`,
   `DASHBOARD_URL=https://metrics.3m4.net`, `VITE_API_URL=/api`,
   `VITE_APP_URL=https://metrics.3m4.net`, fresh `JWT_SECRET_KEY` and
   `IP_HASH_SECRET`, PostHog keys (`POSTHOG_API_KEY`, `POSTHOG_PERSONAL_API_KEY`,
   `VITE_POSTHOG_KEY`; flags are prefixed `metrics-` in the shared PostHog
   project), the payments portal set (see **Billing** below), a fresh Postgres
   password: set `POSTGRES_PASSWORD` (read by the postgres service through
   `--env-file ../.env`) and use the same value in `DATABASE_URL`.
   `deploy/first-deploy.sh` does all of this (steps 1-4, 7 and 8) in one go.
3. **GeoIP**: nothing to download. `docker-compose.prod.yml` mounts the
   shortener's `/opt/3m4/deploy/geoip` (kept fresh by its weekly
   `geoip-update.sh` cron) read-only at `/geoip`.
4. **Start**
   ```sh
   cd /opt/metrics/deploy
   docker compose --env-file ../.env -f docker-compose.yml -f docker-compose.prod.yml up -d --build
   ```
   Container names are stable (`metrics-api-1`, `metrics-web-1`, `metrics-mcp-1`, `metrics-worker-1`):
   compose project `metrics`, one replica each. The edge Caddy routes by name.
5. **Edge routing** — in `/opt/3m4` (branch `deploy/metrics-edge-routing` in the
   3m4 repo adds this):
   - `deploy/docker-compose.prod.yml`: the `caddy` service is already attached
     to the external `edge` network (done for exp).
   - `deploy/Caddyfile.prod`: the block
     ```
     metrics.3m4.net {
     	handle /api/* { reverse_proxy metrics-api-1:5000 }
     	handle /mcp*  { reverse_proxy metrics-mcp-1:3333 }
     	@tracker path /m.js /m/*
     	handle @tracker {
     		header Cache-Control "public, max-age=3600"
     		header Access-Control-Allow-Origin "*"
     		reverse_proxy metrics-web-1:3000
     	}
     	handle        { reverse_proxy metrics-web-1:3000 }
     }
     ```
   - `docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --force-recreate caddy`
6. **DNS (Bluehost)**: A record `metrics` → the server IP (`46.225.62.18`), same
   as `exp`. Caddy issues the TLS certificate automatically once DNS resolves.
7. **Backups**: add `/opt/metrics/deploy/backup.sh` to the same crontab as 3m4
   (nightly, keeps 14 days under `/opt/backups/metrics`).
8. **Retention**: add a nightly cron that prunes events past each plan's
   retention window:
   ```
   30 4 * * * cd /opt/metrics/deploy && docker compose --env-file ../.env -f docker-compose.yml -f docker-compose.prod.yml run --rm migrate python -m dbcore.cli prune-events >> /var/log/metrics-prune.log 2>&1
   ```
   (No-op while `early-access` is ON: every account has unlimited retention.)
9. **Deploy-on-push**: in the GitHub repo set secrets `DEPLOY_HOST` and
   `DEPLOY_SSH_KEY`, and repo variable `DEPLOY_ENABLED=true`. After that every
   push to `main` redeploys via `.github/workflows/deploy.yml`.

## Billing (payments.3m4.net)

metrics never calls Stripe. The portal at `/opt/payments` owns checkout, the
Customer Portal, receipts and donations; metrics only sends users there,
receives its signed push webhooks and pulls entitlements with a service key.
Both stacks talk over the shared `edge` network by container name
(`payments-api-1`, `metrics-api-1`), so nothing is exposed publicly.

1. **App key on the payments box** (once; prints the two secrets a single
   time — rotate by running it again):
   ```sh
   cd /opt/payments && make app-key SLUG=metrics WEBHOOK_URL=http://metrics-api-1:5000/api/billing/webhook
   ```
2. **metrics `.env`**:
   ```
   BILLING_ENABLED=true
   PAYMENTS_URL=https://payments.3m4.net
   PAYMENTS_INTERNAL_URL=http://payments-api-1:5000
   PAYMENTS_SERVICE_KEY=m4pay_sk_…          # from step 1
   PAYMENTS_WEBHOOK_SECRET=whsec_m4pay_…    # from step 1
   VITE_PAYMENTS_URL=https://payments.3m4.net
   VITE_BILLING_ENABLED=true
   ```
   then rebuild `api`, `worker` and `web` (the public URL is baked into the
   web bundle): `docker compose --env-file ../.env -f docker-compose.yml -f docker-compose.prod.yml up -d --build api worker web`.
   `api`, `worker` and `web` are on `edge` already (base compose).
3. **Catalog**: the products live in payments' `packages/shared/catalog.json`
   (app `metrics`: `pro_monthly`, `pro_annual`, entitlement `pro`, Stripe
   lookup keys `metrics_pro_monthly` / `metrics_pro_annual`) and in metrics'
   `packages/shared/plan_limits.json` → `price_keys`. Keep both in sync;
   `team` has no product yet, so its Upgrade button is disabled.
4. **Verify** (same commands locally with `http://localhost:8083` and the
   `.env` secrets; `early-access` must be OFF for the billing page to show,
   the webhook works regardless):
   ```sh
   # push: a signed subscription.updated for an identity that has signed in to metrics
   SECRET=$(grep ^PAYMENTS_WEBHOOK_SECRET .env | cut -d= -f2-)
   IDENTITY=<accounts sub of a user who has opened the dashboard>
   BODY='{"id":"'$(uuidgen)'","type":"subscription.updated","created":"2026-11-01T00:00:00Z","app":"metrics","identity_id":"'$IDENTITY'","email":"x@example.com","data":{"entitlements":["pro"],"subscription":{"id":"sub_test","entitlement":"pro","status":"active","current_period_end":"2027-01-01T00:00:00Z","cancel_at_period_end":false,"label":"Pro"},"payment":null,"updated_at":"2026-11-01T00:00:00Z"}}'
   TS=$(date +%s); SIG=v1=$(printf '%s.%s' "$TS" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
   curl -s -X POST https://metrics.3m4.net/api/billing/webhook -H "Content-Type: application/json" \
     -H "X-M4Pay-Timestamp: $TS" -H "X-M4Pay-Signature: $SIG" -d "$BODY"      # → {"plan":"pro","status":"ok"}
   docker exec metrics-postgres-1 psql -U metrics -d metrics -c "select plan from accounts"   # → pro
   # pull: one reconcile run (lists the app's subscriptions changed in the last 2 days)
   make reconcile-billing                                                               # → reconciled: {'applied': n, ...}
   docker logs metrics-worker-1 | grep "billing reconcile"                             # the daily run
   ```
   The same signed POST with `"entitlements":[],"subscription":null` sets the
   plan back to `free`. Real purchases: `early-access` OFF → `/dashboard/billing`
   → Upgrade opens `https://payments.3m4.net/subscribe?app=metrics&price=pro_monthly`.
