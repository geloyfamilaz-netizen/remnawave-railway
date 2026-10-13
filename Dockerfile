# Xray-core + Caddy (decoy website) for Railway.
# Railway terminates TLS at its edge; Caddy listens on plain $PORT.
# Settings live in config.env (baked into the image); only UUID is needed in Railway.
FROM alpine:3.20 AS download

ARG XRAY_VERSION=v25.1.30
ARG CADDY_VERSION=2.8.4

RUN apk add --no-cache curl unzip \
 && if [ "$XRAY_VERSION" = "latest" ]; then \
      XURL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"; \
    else \
      XURL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"; \
    fi \
 && curl -fsSL "$XURL" -o /tmp/xray.zip \
 && unzip /tmp/xray.zip xray geoip.dat geosite.dat -d /out \
 && curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" -o /tmp/caddy.tgz \
 && tar xzf /tmp/caddy.tgz -C /out caddy \
 && chmod +x /out/xray /out/caddy

FROM alpine:3.20

RUN apk add --no-cache ca-certificates jq python3 \
 && adduser -D -H xray \
 && mkdir -p /usr/local/share/xray /srv/www /app

COPY --from=download /out/xray /out/caddy /usr/local/bin/
COPY --from=download /out/geoip.dat /out/geosite.dat /usr/local/share/xray/
COPY www/ /srv/www/
COPY sub.py derive.py config.env /app/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray \
    XDG_DATA_HOME=/tmp/caddy-data \
    XDG_CONFIG_HOME=/tmp/caddy-config

USER xray
ENTRYPOINT ["/entrypoint.sh"]
