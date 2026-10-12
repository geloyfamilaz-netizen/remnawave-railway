# xray-railway

Xray-core on Railway: **VLESS over WebSocket and gRPC in one service**, plus a hidden
subscription page with an "Add to Incy" button. TLS is terminated by Railway's edge.

```
Railway edge ─> Caddy :$PORT ─┬─ /<ws path>          ─> xray (ws)
                              ├─ /<grpc service>/*   ─> xray (grpc, h2c)
                              ├─ /<hidden path>      ─> subscription page
                              └─ anything else       ─> 404
```

## Deploy

1. New Railway service from this repo.
2. Settings → Networking → **Generate Domain** (target port = `PORT`, normally 8080).
3. Open the deploy logs: UUID, paths, both `vless://` links and the subscription page URL are printed.

No variables are required. See `.env.example` for overrides.

## What's automatic

- **UUID** — taken from `UUID` if set, else from a volume at `STATE_DIR`, else derived from the
  Railway service IDs (stable between deploys), else random.
- **Paths** — WS path, gRPC service name and the subscription path are random-looking hashes
  derived from the UUID. Nothing is served at `/`.
- **robots.txt** — `Disallow: /` plus `X-Robots-Tag: noindex, nofollow` on every response and a
  `noindex` meta on the page. The hidden path is never listed in robots.txt.
- **Client links** — `security=tls`, `fp=chrome` (uTLS), SNI, Host/authority, ALPN (`http/1.1` for WS,
  `h2` for gRPC). Override with `SNI`, `ADDRESS`, `HTTP_HOST`, `FP`.
- BitTorrent and private IP ranges are blocked in routing.

## Subscription page / Incy

The page lives at `https://<domain>/<hidden>/<path>`. It shows the WS and gRPC links, the combined
subscription URL and an **Add to Incy** button (`incy://import/<subscription url>`).

## Device limit (`MAX_DEVICES`, default 1)

The subscription feed remembers the first `x-hwid` the client sends and answers 403 to any other.
Limits: Xray itself has no per-device limit, so this only gates *fetching the subscription* —
a copied `vless://` link still works anywhere. For hard limits use the Remnawave panel. Without a
volume the bound device resets on redeploy; clients that send no HWID are not limited.

## Notes

- gRPC needs HTTP/2 end to end. If it stalls, check Railway's edge and use WS as the fallback.
- A custom `SNI` only works if your Railway edge serves a certificate for that name
  (e.g. your own domain attached to the service).
- `XRAY_VERSION` build arg pins the Xray release (e.g. `v25.1.30`).
- `MODE` is gone: both transports run in a single service.
- Use this in line with Railway's terms of service.
