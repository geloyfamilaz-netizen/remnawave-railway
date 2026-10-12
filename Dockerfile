# Xray-core (VLESS over WebSocket + XHTTP on one port) for Railway.
# Railway terminates TLS at its edge; Caddy routes by path on plain HTTP.

FROM alpine:3.20 AS download

ARG XRAY_VERSION=latest

RUN apk add --no-cache curl unzip \
 && if [ "$XRAY_VERSION" = "latest" ]; then \
      URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"; \
    else \
      URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"; \
    fi \
 && curl -fsSL "$URL" -o /tmp/xray.zip \
 && unzip /tmp/xray.zip xray geoip.dat geosite.dat -d /out \
 && chmod +x /out/xray

FROM alpine:3.20

RUN apk add --no-cache ca-certificates caddy python3 \
 && adduser -D -H xray \
 && mkdir -p /usr/local/share/xray /data \
 && chown xray /data

COPY --from=download /out/xray /usr/local/bin/xray
COPY --from=download /out/geoip.dat /out/geosite.dat /usr/local/share/xray/
COPY entrypoint.sh /entrypoint.sh
COPY sub.py /sub.py
RUN chmod +x /entrypoint.sh

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray \
    XDG_DATA_HOME=/tmp/xdg-data \
    XDG_CONFIG_HOME=/tmp/xdg-config \
    PYTHONUNBUFFERED=1

USER xray

ENTRYPOINT ["/entrypoint.sh"]
