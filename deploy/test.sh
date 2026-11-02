#!/usr/bin/env sh
# Run the backend test suite (services/api/tests) against a disposable Postgres
# started with `docker run`, using a local virtualenv in .venv. Redis is not
# needed (the rate limiter runs on memory:// in tests).
#   make test            # or: sh deploy/test.sh [pytest args]
# The container is removed when the script exits, whatever the outcome.
set -eu
cd "$(dirname "$0")/.."

PG=metrics-test-pg
PG_PORT="${TEST_PG_PORT:-55434}"

cleanup() { docker rm -f "$PG" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup

docker run -d --rm --name "$PG" -e POSTGRES_USER=metrics -e POSTGRES_PASSWORD=metrics -e POSTGRES_DB=metrics_test \
  -p "$PG_PORT:5432" postgres:16-alpine >/dev/null

i=0
until docker exec "$PG" pg_isready -U metrics >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 60 ] || { echo "postgres did not come up" >&2; exit 1; }; sleep 1
done

if [ ! -d .venv ]; then
  "${PYTHON:-python3}" -m venv .venv
fi
# shellcheck disable=SC1091
. .venv/bin/activate
pip install -q -r services/api/requirements.txt -r services/api/requirements-dev.txt

export DATABASE_URL="postgresql+psycopg://metrics:metrics@localhost:$PG_PORT/metrics_test"
export TEST_DATABASE_URL="$DATABASE_URL"
export REDIS_URL="memory://"
export PYTHONPATH="$PWD:$PWD/services/api"

python -m pytest services/api/tests "$@"
