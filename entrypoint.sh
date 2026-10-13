#!/bin/sh
# Builds Xray + Caddy configs and runs Xray, Caddy and the subscription server.
#
# Settings come from /app/config.env; a Railway variable with the same name wins.
# No variables are required: UUID is derived from Railway IDs unless you set it.
#
# :$PORT (Railway HTTPS domain, TLS ends at Railway edge)
#   Caddy -> /ws, /xh, /<grpc>/*  => Xray on 127.0.0.1
#         -> secret sub paths     => sub.py
#         -> everything else      => decoy website
# Reality inbounds listen on their own ports (for Railway TCP proxies).
set -eu

# ---------- preflight: files that must be in the image ----------
for f in /app/sub.py /app/derive.py /app/config.env; do
  [ -f "$f" ] || { echo "ERROR: $f is missing in the image. The Dockerfile in the repo is outdated or the file was not committed: it must contain 'COPY sub.py derive.py config.env /app/' and all three files must be in the repo root." >&2; exit 1; }
done

# ---------- config.env (env wins) ----------
CONFIG_FILE=/app/config.env
CFG_LOADED=0
CFG_OVERRIDDEN=""
if [ -f "$CONFIG_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r' | sed 's/#.*$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$line" in *=*) ;; *) continue ;; esac
    key=$(printf '%s' "${line%%=*}" | sed 's/[[:space:]]*$//')
    val=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//;s/^"\(.*\)"$/\1/;s/^'"'"'\(.*\)'"'"'$/\1/')
    case "$key" in ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac
    eval "cur=\"\${$key:-}\""
    if [ -n "$cur" ]; then
      CFG_OVERRIDDEN="$CFG_OVERRIDDEN $key"
    elif [ -n "$val" ]; then
      export "$key=$val"
      CFG_LOADED=$((CFG_LOADED + 1))
    fi
  done < "$CONFIG_FILE"
fi

# ---------- UUID: env > derived from Railway IDs (stable across deploys) > random ----------
UUID_SRC="UUID variable"
if [ -z "${UUID:-}" ]; then
  if [ -n "${RAILWAY_SERVICE_ID:-}" ]; then
    UH=$(printf 'xray-railway/uuid/v1:%s:%s:%s' "$RAILWAY_SERVICE_ID" "${RAILWAY_ENVIRONMENT_ID:-}" "${RAILWAY_PROJECT_ID:-}" | sha256sum | cut -c1-32)
    UV=$(printf '%x' $(( 0x$(printf '%s' "$UH" | cut -c17) & 3 | 8 )))
    UUID="$(printf '%s' "$UH" | cut -c1-8)-$(printf '%s' "$UH" | cut -c9-12)-5$(printf '%s' "$UH" | cut -c14-16)-$UV$(printf '%s' "$UH" | cut -c18-20)-$(printf '%s' "$UH" | cut -c21-32)"
    UUID_SRC="derived from Railway service/environment IDs (stable across deploys)"
  else
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')
    UUID_SRC="RANDOM (not on Railway: changes on every start; set UUID to keep it)"
  fi
  export UUID
fi


PORT="${PORT:-8080}"
LOG_LEVEL="${LOG_LEVEL:-warning}"

ENABLE_WS="${ENABLE_WS:-1}"
ENABLE_XHTTP="${ENABLE_XHTTP:-1}"
ENABLE_GRPC="${ENABLE_GRPC:-1}"
WS_PATH="${WS_PATH:-/ws}"
XHTTP_PATH="${XHTTP_PATH:-/xh}"
GRPC_SERVICE="${GRPC_SERVICE:-grpc}"
FP="${CLIENT_FP:-firefox}"

# Reality (TCP proxy ports). Private key is derived from UUID unless REALITY_PRIVATE_KEY is set.
ENABLE_REALITY="${ENABLE_REALITY:-1}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
REALITY_DEST="${REALITY_DEST:-www.microsoft.com:443}"
REALITY_SNI="${REALITY_SNI:-${REALITY_DEST%%:*}}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(printf '%s' "$UUID" | sha256sum | cut -c1-8)}"
REALITY_XHTTP_PORT="${REALITY_XHTTP_PORT:-4443}"
REALITY_GRPC_PORT="${REALITY_GRPC_PORT:-5443}"
TCP_PROXY_XHTTP="${TCP_PROXY_XHTTP:-}"
TCP_PROXY_GRPC="${TCP_PROXY_GRPC:-}"

# Optional WARP exit for chosen geosite tags (e.g. "openai,netflix").
WARP_PRIVATE_KEY="${WARP_PRIVATE_KEY:-}"
WARP_ADDRESS="${WARP_ADDRESS:-172.16.0.2/32}"
WARP_RESERVED="${WARP_RESERVED:-}"
WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1:2408}"
WARP_GEOSITES="${WARP_GEOSITES:-}"

# Subscription page + feed (sub.py). Paths are secret by default (derived from UUID).
ENABLE_SUB="${ENABLE_SUB:-1}"
SUB_H="$(printf '%s' "$UUID" | sha256sum | cut -c1-24)"
SUB_PAGE_PATH="${SUB_PAGE_PATH:-/s/$(printf 'page%s' "$SUB_H" | sha256sum | cut -c1-16)}"
SUB_FEED_PATH="${SUB_FEED_PATH:-/f/$(printf 'feed%s' "$SUB_H" | sha256sum | cut -c1-16)}"
SUB_INTERNAL_PORT=20003
PROFILE_NAME="${PROFILE_NAME:-Railway}"
MAX_DEVICES="${MAX_DEVICES:-1}"
STATE_DIR="${STATE_DIR:-}"

XRAY_CFG=/tmp/xray.json
CADDY_CFG=/tmp/Caddyfile
SUB_CFG=/tmp/sub.json
SNIFF='{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'

# ---------- Reality keys ----------
REALITY_ON=0
PUB=""
REALITY_KEY_SRC=""
if [ "$ENABLE_REALITY" = 1 ] && { [ "$REALITY_XHTTP_PORT" != 0 ] || [ "$REALITY_GRPC_PORT" != 0 ]; }; then
  if [ -n "$REALITY_PRIVATE_KEY" ]; then
    REALITY_KEY_SRC="REALITY_PRIVATE_KEY (custom)"
  else
    REALITY_PRIVATE_KEY=$(python3 /app/derive.py key "$UUID") \
      || { echo "ERROR: cannot derive Reality key from UUID" >&2; exit 1; }
    REALITY_KEY_SRC="derived from UUID"
  fi
  PUB=$(python3 /app/derive.py pub "$REALITY_PRIVATE_KEY") \
    || { echo "ERROR: REALITY_PRIVATE_KEY is not a valid x25519 key (32 bytes, base64url)" >&2; exit 1; }
  REALITY_ON=1
fi

# ---------- Xray config ----------
INBOUNDS='[]'
add_inbound() { INBOUNDS=$(printf '%s' "$INBOUNDS" | jq -c ". + [$1]"); }

if [ "$ENABLE_WS" = 1 ]; then
  add_inbound "$(jq -nc --arg id "$UUID" --arg p "$WS_PATH" --argjson s "$SNIFF" '{
    tag:"in-ws",listen:"127.0.0.1",port:10001,protocol:"vless",sniffing:$s,
    settings:{clients:[{id:$id}],decryption:"none"},
    streamSettings:{network:"ws",security:"none",wsSettings:{path:$p,heartbeatPeriod:30}}}')"
fi
if [ "$ENABLE_XHTTP" = 1 ]; then
  add_inbound "$(jq -nc --arg id "$UUID" --arg p "$XHTTP_PATH" --argjson s "$SNIFF" '{
    tag:"in-xhttp",listen:"127.0.0.1",port:10002,protocol:"vless",sniffing:$s,
    settings:{clients:[{id:$id}],decryption:"none"},
    streamSettings:{network:"xhttp",security:"none",xhttpSettings:{path:$p,mode:"auto"}}}')"
fi
if [ "$ENABLE_GRPC" = 1 ]; then
  add_inbound "$(jq -nc --arg id "$UUID" --arg g "$GRPC_SERVICE" --argjson s "$SNIFF" '{
    tag:"in-grpc",listen:"127.0.0.1",port:10003,protocol:"vless",sniffing:$s,
    settings:{clients:[{id:$id}],decryption:"none"},
    streamSettings:{network:"grpc",security:"none",grpcSettings:{serviceName:$g}}}')"
fi

if [ "$REALITY_ON" = 1 ]; then
  RSET=$(jq -nc --arg d "$REALITY_DEST" --arg sn "$REALITY_SNI" --arg k "$REALITY_PRIVATE_KEY" --arg sid "$REALITY_SHORT_ID" \
    '{show:false,dest:$d,xver:0,serverNames:[$sn],privateKey:$k,shortIds:[$sid]}')
  if [ "$REALITY_XHTTP_PORT" != 0 ]; then
    add_inbound "$(jq -nc --arg id "$UUID" --argjson r "$RSET" --arg p "$XHTTP_PATH" --argjson port "$REALITY_XHTTP_PORT" --argjson s "$SNIFF" '{
      tag:"in-r-xhttp",listen:"0.0.0.0",port:$port,protocol:"vless",sniffing:$s,
      settings:{clients:[{id:$id}],decryption:"none"},
      streamSettings:{network:"xhttp",security:"reality",realitySettings:$r,xhttpSettings:{path:$p,mode:"auto"}}}')"
  fi
  if [ "$REALITY_GRPC_PORT" != 0 ]; then
    add_inbound "$(jq -nc --arg id "$UUID" --argjson r "$RSET" --arg g "$GRPC_SERVICE" --argjson port "$REALITY_GRPC_PORT" --argjson s "$SNIFF" '{
      tag:"in-r-grpc",listen:"0.0.0.0",port:$port,protocol:"vless",sniffing:$s,
      settings:{clients:[{id:$id}],decryption:"none"},
      streamSettings:{network:"grpc",security:"reality",realitySettings:$r,grpcSettings:{serviceName:$g}}}')"
  fi
fi

OUTBOUNDS='[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}]'
RULES='[{"type":"field","protocol":["bittorrent"],"outboundTag":"block"},{"type":"field","ip":["geoip:private"],"outboundTag":"block"}]'

WARP_ON=0
if [ -n "$WARP_PRIVATE_KEY" ]; then
  WARP_ON=1
  RES='null'
  [ -n "$WARP_RESERVED" ] && RES="[$WARP_RESERVED]"
  WARP=$(jq -nc --arg k "$WARP_PRIVATE_KEY" --arg a "$WARP_ADDRESS" --arg e "$WARP_ENDPOINT" --argjson res "$RES" '{
    tag:"warp",protocol:"wireguard",
    settings:({secretKey:$k,address:($a|split(",")),mtu:1280,
      peers:[{publicKey:"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",allowedIPs:["0.0.0.0/0","::/0"],endpoint:$e}]}
      + (if $res then {reserved:$res} else {} end))}')
  OUTBOUNDS=$(printf '%s' "$OUTBOUNDS" | jq -c ". + [$WARP]")
  if [ -n "$WARP_GEOSITES" ]; then
    DOMS=$(printf '%s' "$WARP_GEOSITES" | jq -Rc 'split(",")|map(gsub("\\s";"")|select(length>0)|"geosite:"+.)')
    RULES=$(printf '%s' "$RULES" | jq -c --argjson d "$DOMS" '. + [{"type":"field","domain":$d,"outboundTag":"warp"}]')
  fi
fi

jq -n --arg ll "$LOG_LEVEL" --argjson i "$INBOUNDS" --argjson o "$OUTBOUNDS" --argjson r "$RULES" '{
  log:{loglevel:$ll,access:"none"},
  inbounds:$i,outbounds:$o,
  routing:{domainStrategy:"IPIfNonMatch",rules:$r}}' > "$XRAY_CFG"

# ---------- Caddy config (decoy + path routing) ----------
{
cat <<CADDY
{
	admin off
	auto_https off
	servers {
		protocols h1 h2c
	}
}
:$PORT {
	header -Server
CADDY
if [ "$ENABLE_WS" = 1 ]; then cat <<CADDY
	@ws {
		path $WS_PATH
		header Upgrade websocket
	}
	handle @ws {
		reverse_proxy 127.0.0.1:10001
	}
CADDY
fi
if [ "$ENABLE_XHTTP" = 1 ]; then cat <<CADDY
	@xhttp path $XHTTP_PATH $XHTTP_PATH/*
	handle @xhttp {
		reverse_proxy 127.0.0.1:10002 {
			flush_interval -1
		}
	}
CADDY
fi
if [ "$ENABLE_GRPC" = 1 ]; then cat <<CADDY
	@grpc {
		path /$GRPC_SERVICE/*
		header Content-Type application/grpc*
	}
	handle @grpc {
		reverse_proxy h2c://127.0.0.1:10003 {
			flush_interval -1
		}
	}
CADDY
fi
if [ "$ENABLE_SUB" = 1 ]; then cat <<CADDY
	@sub path $SUB_PAGE_PATH $SUB_PAGE_PATH/ $SUB_FEED_PATH $SUB_FEED_PATH/
	handle @sub {
		reverse_proxy 127.0.0.1:$SUB_INTERNAL_PORT
	}
CADDY
fi
cat <<CADDY
	handle {
		root * /srv/www
		file_server
	}
	handle_errors {
		rewrite * /404.html
		file_server {
			root /srv/www
		}
	}
}
CADDY
} > "$CADDY_CFG"

# ---------- client links ----------
D="${PUBLIC_DOMAIN:-${RAILWAY_PUBLIC_DOMAIN:-}}"
D_OK=1
[ -n "$D" ] || { D="<RAILWAY_DOMAIN>"; D_OK=0; }
PUBLIC_BASE="https://$D"
enc() { printf '%s' "$1" | sed 's|/|%2F|g'; }

# host:port check (port numeric, host non-empty, no spaces)
valid_hp() {
  case "$1" in ''|*[[:space:]]*|*/*|:*|*:|*:*[!0-9]*) return 1 ;; *:*) return 0 ;; *) return 1 ;; esac
}

# Railway injects one RAILWAY_TCP_PROXY_* pair: use it for the matching app port
TCP_AUTO=""
if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ] && [ -n "${RAILWAY_TCP_APPLICATION_PORT:-}" ]; then
  HP="$RAILWAY_TCP_PROXY_DOMAIN:$RAILWAY_TCP_PROXY_PORT"
  if [ "$RAILWAY_TCP_APPLICATION_PORT" = "$REALITY_XHTTP_PORT" ] && [ -z "$TCP_PROXY_XHTTP" ]; then
    TCP_PROXY_XHTTP="$HP"; TCP_AUTO="$TCP_AUTO xhttp"
  elif [ "$RAILWAY_TCP_APPLICATION_PORT" = "$REALITY_GRPC_PORT" ] && [ -z "$TCP_PROXY_GRPC" ]; then
    TCP_PROXY_GRPC="$HP"; TCP_AUTO="$TCP_AUTO grpc"
  fi
fi
valid_hp "$TCP_PROXY_XHTTP" || { [ -z "$TCP_PROXY_XHTTP" ] || echo "WARN: TCP_PROXY_XHTTP='$TCP_PROXY_XHTTP' is not host:port, ignored" >&2; TCP_PROXY_XHTTP=""; }
valid_hp "$TCP_PROXY_GRPC"  || { [ -z "$TCP_PROXY_GRPC" ]  || echo "WARN: TCP_PROXY_GRPC='$TCP_PROXY_GRPC' is not host:port, ignored" >&2;  TCP_PROXY_GRPC=""; }

LINK_WS="vless://$UUID@$D:443?encryption=none&security=tls&sni=$D&fp=$FP&type=ws&host=$D&path=$(enc "$WS_PATH")#rw-ws"
LINK_XHTTP="vless://$UUID@$D:443?encryption=none&security=tls&sni=$D&fp=$FP&alpn=h2&type=xhttp&host=$D&path=$(enc "$XHTTP_PATH")&mode=packet-up#rw-xhttp"
LINK_GRPC="vless://$UUID@$D:443?encryption=none&security=tls&sni=$D&fp=$FP&alpn=h2&type=grpc&serviceName=$GRPC_SERVICE&mode=gun#rw-grpc"
reality_base() { printf 'vless://%s@%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s' "$UUID" "$1" "$REALITY_SNI" "$FP" "$PUB" "$REALITY_SHORT_ID"; }
R_XHTTP_TAIL="&type=xhttp&path=$(enc "$XHTTP_PATH")&mode=auto#rw-r-xhttp"
R_GRPC_TAIL="&type=grpc&serviceName=$GRPC_SERVICE&mode=gun#rw-r-grpc"

# ---------- startup log ----------
echo "=== Config ==="
echo "config.env: $CFG_LOADED values loaded; overridden by Railway variables:${CFG_OVERRIDDEN:- none}"
echo "uuid: $UUID  [$UUID_SRC]"
echo "domain: $D$([ "$D_OK" = 1 ] || echo '  (WARN: no Railway domain yet: Networking -> Generate Domain, or set PUBLIC_DOMAIN)')"
echo "transports: ws=$ENABLE_WS xhttp=$ENABLE_XHTTP grpc=$ENABLE_GRPC reality=$REALITY_ON warp=$WARP_ON sub=$ENABLE_SUB  (fp=$FP)"
if [ "$REALITY_ON" = 1 ]; then
  echo "reality: key $REALITY_KEY_SRC | sni=$REALITY_SNI dest=$REALITY_DEST"
  echo "reality: public key (pbk) = $PUB"
  echo "reality: short id (sid)   = $REALITY_SHORT_ID"
fi

echo "=== Client links ==="
[ "$ENABLE_WS" = 1 ]    && echo "WS     : $LINK_WS"
[ "$ENABLE_XHTTP" = 1 ] && echo "XHTTP  : $LINK_XHTTP"
[ "$ENABLE_GRPC" = 1 ]  && echo "gRPC   : $LINK_GRPC"
LINKS='[]'
add_link() { LINKS=$(printf '%s' "$LINKS" | jq -c --arg n "$1" --arg t "$2" --arg u "$3" '. + [{name:$n,tag:$t,url:$u}]'); }
[ "$ENABLE_WS" = 1 ]    && add_link "VLESS · WebSocket" "TLS · http/1.1" "$LINK_WS"
[ "$ENABLE_XHTTP" = 1 ] && add_link "VLESS · XHTTP" "TLS · h2 · packet-up" "$LINK_XHTTP"
if [ "$REALITY_ON" = 1 ]; then
  echo "Reality (TCP proxies in Railway Networking; auto from RAILWAY_TCP_PROXY_*:${TCP_AUTO:- none}):"
  if [ "$REALITY_XHTTP_PORT" != 0 ]; then
    if [ -n "$TCP_PROXY_XHTTP" ]; then
      RL="$(reality_base "$TCP_PROXY_XHTTP")$R_XHTTP_TAIL"
      echo "R-XHTTP: $RL"
      add_link "VLESS · Reality · XHTTP" "Reality · TCP proxy" "$RL"
    else
      echo "R-XHTTP: not in subscription. Create TCP proxy -> app port $REALITY_XHTTP_PORT, then set TCP_PROXY_XHTTP=host:port in config.env"
      echo "         template: $(reality_base "<HOST:PORT>")$R_XHTTP_TAIL"
    fi
  fi
  if [ "$REALITY_GRPC_PORT" != 0 ]; then
    if [ -n "$TCP_PROXY_GRPC" ]; then
      RL="$(reality_base "$TCP_PROXY_GRPC")$R_GRPC_TAIL"
      echo "R-gRPC : $RL"
      add_link "VLESS · Reality · gRPC" "Reality · TCP proxy" "$RL"
    else
      echo "R-gRPC : not in subscription. Create TCP proxy -> app port $REALITY_GRPC_PORT, then set TCP_PROXY_GRPC=host:port in config.env"
      echo "         template: $(reality_base "<HOST:PORT>")$R_GRPC_TAIL"
    fi
  fi
fi

# ---------- subscription (sub.py) ----------
SPID=""
if [ "$ENABLE_SUB" = 1 ]; then
  NLINKS=$(printf '%s' "$LINKS" | jq 'length')
  if [ "$NLINKS" -gt 0 ]; then
    STATE_DIR_OK=""
    STATE_NOTE="no"
    if [ -n "$STATE_DIR" ]; then
      if mkdir -p "$STATE_DIR" 2>/dev/null && [ -w "$STATE_DIR" ]; then
        STATE_DIR_OK="$STATE_DIR"; STATE_NOTE="yes ($STATE_DIR)"
      else
        STATE_NOTE="no (STATE_DIR=$STATE_DIR is not writable: mount a Railway Volume there)"
      fi
    fi
    jq -nc --arg pp "$SUB_PAGE_PATH" --arg fp "$SUB_FEED_PATH" --arg bu "$PUBLIC_BASE" --arg nm "$PROFILE_NAME" \
      --argjson md "$MAX_DEVICES" --arg sd "$STATE_DIR_OK" --argjson port "$SUB_INTERNAL_PORT" --argjson l "$LINKS" \
      '{page_path:$pp,feed_path:$fp,base_url:$bu,name:$nm,max_devices:$md,state_dir:$sd,port:$port,links:$l}' > "$SUB_CFG"
    echo "=== Subscription ($NLINKS links) ==="
    echo "Subscription page: $PUBLIC_BASE$SUB_PAGE_PATH"
    echo "Subscription feed: $PUBLIC_BASE$SUB_FEED_PATH"
    echo "device limit: $MAX_DEVICES | persistent: $STATE_NOTE"
    printf '%s' "$LINKS" | jq -r 'to_entries[]|"  \(.key+1). \(.value.name) [\(.value.tag)]"'
    SUB_CONFIG="$SUB_CFG" python3 /app/sub.py & SPID=$!
  else
    echo "Subscription disabled: no links to publish (enable WS, XHTTP or Reality)"
    ENABLE_SUB=0
  fi
fi

# ---------- run all, die together ----------
xray run -config "$XRAY_CFG" & XPID=$!
caddy run --config "$CADDY_CFG" --adapter caddyfile & CPID=$!
trap 'kill $XPID $CPID $SPID 2>/dev/null; exit 0' TERM INT
echo "Started: xray=$XPID caddy=$CPID sub=${SPID:-off} port=$PORT reality=$REALITY_ON"
while kill -0 $XPID 2>/dev/null && kill -0 $CPID 2>/dev/null && { [ -z "$SPID" ] || kill -0 $SPID 2>/dev/null; }; do sleep 2; done
echo "A process exited, stopping container" >&2
kill $XPID $CPID $SPID 2>/dev/null || true
exit 1
