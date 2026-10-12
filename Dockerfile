# Xray-core (VLESS over WebSocket / gRPC) for Railway.
# Railway terminates TLS at its edge, so xray listens on plain TCP on $PORT.

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
RUN apk add --no-cache ca-certificates \
 && adduser -D -H xray \
 && mkdir -p /usr/local/share/xray
COPY --from=download /out/xray /usr/local/bin/xray
COPY --from=download /out/geoip.dat /out/geosite.dat /usr/local/share/xray/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray \
    MODE=ws

USER xray
ENTRYPOINT ["/entrypoint.sh"]
