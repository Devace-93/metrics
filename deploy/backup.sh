#!/usr/bin/env bash
# Nightly Postgres dump for the metrics stack. Keeps 14 days.
set -euo pipefail
DIR=/opt/backups/metrics
mkdir -p "$DIR"
cd /opt/metrics/deploy
docker compose --env-file ../.env -f docker-compose.yml -f docker-compose.prod.yml exec -T postgres \
  pg_dump -U metrics -d metrics | gzip > "$DIR/metrics-$(date +%F).sql.gz"
find "$DIR" -name 'metrics-*.sql.gz' -mtime +14 -delete
