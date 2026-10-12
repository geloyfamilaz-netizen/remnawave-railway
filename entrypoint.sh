#!/bin/sh
# Generates the xray config from environment variables and starts xray.
set -eu

if [ -z "${UUID:-}" ]; then
  echo "ERROR: UUID is not set. Generate one with: xray uuid (or uuidgen) and put it in Railway Variables." >&2
  exit 1
fi

PORT="${PORT:-8080}"
MODE="${MODE:-ws}"
WS_PATH="${WS_PATH:-/ws}"
GRPC_SERVICE="${GRPC_SERVICE:-grpc}"
LOG_LEVEL="${LOG_LEVEL:-warning}"

case "$MODE" in
  ws)
    STREAM='{"network":"ws","security":"none","wsSettings":{"path":"'"$WS_PATH"'"}}'
    ;;
  grpc)
    STREAM='{"network":"grpc","security":"none","grpcSettings":{"serviceName":"'"$GRPC_SERVICE"'"}}'
    ;;
  *)
    echo "ERROR: MODE must be 'ws' or 'grpc', got '$MODE'" >&2
    exit 1
    ;;
esac

CONFIG=/tmp/config.json
cat > "$CONFIG" <<EOF
{
  "log": { "loglevel": "$LOG_LEVEL" },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID" } ],
        "decryption": "none"
      },
      "streamSettings": $STREAM
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF

# Print a ready-to-import client link when Railway gives us the public domain.
DOMAIN="${RAILWAY_PUBLIC_DOMAIN:-}"
if [ -n "$DOMAIN" ]; then
  if [ "$MODE" = "ws" ]; then
    ENC_PATH=$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')
    echo "Client link: vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=$ENC_PATH#railway-ws"
  else
    echo "Client link: vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&alpn=h2&type=grpc&serviceName=$GRPC_SERVICE&mode=gun#railway-grpc"
  fi
else
  echo "RAILWAY_PUBLIC_DOMAIN is empty: generate a public domain for this service to get a client link."
fi

echo "Starting xray-core: mode=$MODE port=$PORT"
exec xray run -config "$CONFIG"
