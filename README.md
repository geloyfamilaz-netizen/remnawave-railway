# xray-railway

Xray-core on Railway: VLESS over WebSocket or gRPC. TLS is terminated by Railway's edge, xray listens on plain TCP on `$PORT`.

One image, two modes selected by `MODE`. Railway gives one public port per service, so deploy the same repo twice to get both transports.

## Deploy

1. Create a Railway project and add a service from this GitHub repo.
2. Set variables (see `.env.example`):
   - `UUID`: generate with `xray uuid` or `uuidgen`
   - `MODE`: `ws` (default) or `grpc`
   - `WS_PATH` (ws only, default `/ws`) / `GRPC_SERVICE` (grpc only, default `grpc`)
3. Settings -> Networking -> Generate Domain (target port = the `PORT` shown in the service, normally 8080).
4. Open the deploy logs: a ready `vless://` client link is printed at start.
5. For the second transport, add another service from the same repo with the other `MODE` and its own domain.

## Client parameters

WebSocket: address = your Railway domain, port 443, TLS on, SNI/host = domain, network `ws`, path = `WS_PATH`.

gRPC: address = your Railway domain, port 443, TLS on, SNI = domain, ALPN `h2`, network `grpc`, mode `gun`, serviceName = `GRPC_SERVICE`.

## Notes

- gRPC needs HTTP/2 end to end. If the gRPC service connects but stalls or drops, check whether Railway's edge is passing HTTP/2 to your service; WS is the safer fallback.
- Private IP ranges are blocked in routing, so the proxy cannot reach Railway's internal network.
- Pin the xray version with a build arg `XRAY_VERSION` (e.g. `v25.1.30`), otherwise the latest release is used at build time.
- Make sure you use this in line with Railway's terms of service; proxy/VPN-style traffic may be restricted on some plans.
