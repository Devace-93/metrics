# Production runbook

metrics runs on the same Hetzner box as the 3m4 shortener (`/opt/3m4`), exp
(`/opt/exp`) and retro (`/opt/retro`). The 3m4 stack's Caddy owns ports 80/443,
so metrics is deployed as another docker compose project without its own Caddy,
and the 3m4 Caddy routes `metrics.3m4.net` to it over the shared `edge` docker
network.

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
   project), RevenueCat keys when billing is switched on, a fresh Postgres
   password (also in `DATABASE_URL`).
3. **GeoIP**: nothing to download. `docker-compose.prod.yml` mounts the
   shortener's `/opt/3m4/deploy/geoip` (kept fresh by its weekly
   `geoip-update.sh` cron) read-only at `/geoip`.
4. **Start**
   ```sh
   cd /opt/metrics/deploy
   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
   ```
   Container names are stable (`metrics-api-1`, `metrics-web-1`, `metrics-mcp-1`):
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
   30 4 * * * cd /opt/metrics/deploy && docker compose -f docker-compose.yml -f docker-compose.prod.yml run --rm migrate python -m dbcore.cli prune-events >> /var/log/metrics-prune.log 2>&1
   ```
   (No-op while `early-access` is ON: every account has unlimited retention.)
9. **Deploy-on-push**: in the GitHub repo set secrets `DEPLOY_HOST` and
   `DEPLOY_SSH_KEY`, and repo variable `DEPLOY_ENABLED=true`. After that every
   push to `main` redeploys via `.github/workflows/deploy.yml`.
