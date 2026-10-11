# Remnawave test environment on Railway

Deploys the [Remnawave](https://docs.rw) panel (`remnawave/backend`) on Railway, with Railway-managed PostgreSQL and Redis. For testing only.

Based on the official docs: <https://docs.rw/install/remnawave-panel> and <https://docs.rw/install/environment-variables>.

## Architecture

| Service | Source | Notes |
| --- | --- | --- |
| `remnawave` | this repo (Dockerfile) | Panel API + UI, port `3000` |
| `Postgres` | Railway database template | Provides `DATABASE_URL` |
| `Redis` | Railway database template | Replaces the Valkey unix socket used in the official compose file |

Railway terminates HTTPS for you, so no separate reverse proxy is needed. The docs require the panel to be served behind a reverse proxy over HTTPS, and Railway's public domain does that.

## Deploy

1. In Railway: **New Project → Deploy from GitHub repo** and pick this repo. It builds from `Dockerfile`.
2. In the same project: **+ New → Database → Add PostgreSQL**, then **+ New → Database → Add Redis**. Keep the default service names `Postgres` and `Redis` (the variable references below rely on them).
3. On the `remnawave` service, open **Variables → Raw Editor** and paste the contents of `.env.example`. Replace every `change_me` with a value from `openssl rand -hex 64`. `WEBHOOK_SECRET_HEADER` must be exactly 64 characters, `a-z A-Z 0-9` only (`openssl rand -hex 32` gives 64 hex chars).
4. **Settings → Networking → Generate Domain**, and set the target port to `3000`.
5. Redeploy. Open the generated domain and create the first admin account.

## Notes

- The panel does not need the metrics port (`3001`) exposed publicly. Don't generate a domain for it.
- Changing environment variables requires a redeploy so the container is recreated.
- Add a Railway volume only if you add stateful files. Panel data lives in Postgres.
- Remnawave nodes (`remnawave/node`) need a server with its own public IP and open ports, so they can't run on Railway. Run nodes on a VPS and connect them to this panel.
- The image tag is `remnawave/backend:2`. Pin an exact version in `Dockerfile` if you want repeatable builds.
