# Remnawave panel (backend) for Railway.
# Postgres and Redis run as separate Railway services (see README.md).
# For reproducible test builds, pin a specific tag instead of the major tag.
FROM remnawave/backend:2

ENV APP_PORT=3000 \
    METRICS_PORT=3001

EXPOSE 3000
