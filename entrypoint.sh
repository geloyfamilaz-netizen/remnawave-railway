#!/bin/sh
# xray-railway: VLESS WS + XHTTP on a single Railway port, subscription page for Incy.
#
#   Railway edge (TLS) ──> Caddy :$PORT ─┬─ /<ws path>        ──> xray ws   :20001
#                                        ├─ /<xhttp path>/*   ──> xray xhttp:20002
#                                        ├─ /<subscription>   ──> sub.py    :20003
#                                        └─ everything else   ──> 404

set -eu

# ───────────────────────────── log helpers ─────────────────────────────
if [ -n "${NO_COLOR:-}" ]; then
  RS=''; B=''; D=''; RED=''; GRN=''; YEL=''; BLU=''; MAG=''; CYN=''
else
  ESC=$(printf '\033')
  RS="${ESC}[0m"; B="${ESC}[1m"; D="${ESC}[2m"
  RED="${ESC}[31m"; GRN="${ESC}[32m"; YEL="${ESC}[33m"
  BLU="${ESC}[34m"; MAG="${ESC}[35m"; CYN="${ESC}[36m"
fi
now()     { date -u '+%H:%M:%S'; }
ok()      { printf '%s%s%s %s✔%s  %s\n' "$D" "$(now)" "$RS" "$GRN" "$RS" "$*"; }
warn()    { printf '%s%s%s %s▲%s  %s\n' "$D" "$(now)" "$RS" "$YEL" "$RS" "$*"; }
fail()    { printf '%s%s%s %s✖%s  %s\n' "$D" "$(now)" "$RS" "$RED" "$RS" "$*" >&2; }
section() { printf '\n %s▍%s %s%s%s\n' "$MAG" "$RS" "$B" "$*" "$RS"; }
kv()      { printf '   %s%-8s%s %s\n' "$D" "$1" "$RS" "$2"; }

banner() {
  printf '\n%s╭──────────────────────────────────────────────────╮%s\n' "$BLU" "$RS"
  printf '%s│%s  %sxray-railway%s  %s·%s  VLESS  %s·%s  WS + XHTTP           %s│%s\n' \
    "$BLU" "$RS" "$B" "$RS" "$D" "$RS" "$D" "$RS" "$BLU" "$RS"
  printf '%s╰──────────────────────────────────────────────────╯%s\n' "$BLU" "$RS"
}

digest()  { printf '%s' "$1" | sha256sum | cut -c1-"$2"; }
urlenc() {
  printf '%s' "$1" | sed 's|%|%25|g; s|/|%2F|g; s|?|%3F|g; s|&|%26|g; s|#|%23|g; s|=|%3D|g; s| |%20|g'
}

banner

# ───────────────────────────── settings ────────────────────────────────
PORT="${PORT:-8080}"
LOG_LEVEL="${LOG_LEVEL:-warning}"
MAX_DEVICES="${MAX_DEVICES:-1}"
PROFILE_NAME="${PROFILE_NAME:-Railway}"
FP="${FP:-chrome}"
STATE_DIR="${STATE_DIR:-/data}"
SEED="${SEED:-}"

WS_PORT=20001; XHTTP_PORT=20002; SUB_PORT=20003
CONFIG=/tmp/xray.json
CADDYFILE=/tmp/Caddyfile

# ───────────────────────────── UUID ────────────────────────────────────
# Priority: UUID env  >  saved on volume  >  derived from Railway IDs  >  random
STATE_OK=''
if [ -d "$STATE_DIR" ] && [ -w "$STATE_DIR" ]; then STATE_OK="$STATE_DIR"; fi

UUID="${UUID:-}"
UUID_SRC='переменная UUID'
if [ -z "$UUID" ]; then
  if [ -n "$STATE_OK" ] && [ -s "$STATE_OK/uuid" ]; then
    UUID=$(cat "$STATE_OK/uuid"); UUID_SRC="том $STATE_DIR"
  else
    SEED_STR="${RAILWAY_PROJECT_ID:-}${RAILWAY_SERVICE_ID:-}${RAILWAY_ENVIRONMENT_ID:-}${SEED}"
    if [ -n "$SEED_STR" ]; then
      H=$(printf '%s' "xray-railway:$SEED_STR" | sha256sum | cut -c1-32)
      UUID="$(echo "$H" | cut -c1-8)-$(echo "$H" | cut -c9-12)-5$(echo "$H" | cut -c14-16)-a$(echo "$H" | cut -c18-20)-$(echo "$H" | cut -c21-32)"
      UUID_SRC='автоген. (стабильный, из ID сервиса Railway)'
    fi
    if [ -z "$UUID" ]; then
      UUID=$(cat /proc/sys/kernel/random/uuid)
      UUID_SRC='автоген. (случайный)'
    fi
    if [ -n "$STATE_OK" ]; then
      printf '%s' "$UUID" > "$STATE_OK/uuid"
      UUID_SRC="$UUID_SRC → сохранён в $STATE_DIR"
    fi
  fi
fi
if ! printf '%s' "$UUID" | grep -Eiq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  fail "UUID '$UUID' некорректен. Удалите переменную UUID — он сгенерируется сам."
  exit 1
fi

# ───────────────── obfuscated (but stable) paths ───────────────────────
WS_PATH="${WS_PATH:-/$(digest "ws:$UUID$SEED" 16)}"
XHTTP_PATH="${XHTTP_PATH:-/$(digest "xhttp:$UUID$SEED" 16)}"
SUB_PAGE_PATH="${SUB_PATH:-/$(digest "a:$UUID$SEED" 8)/$(digest "b:$UUID$SEED" 12)/$(digest "c:$UUID$SEED" 20)}"
SUB_PAGE_PATH="/${SUB_PAGE_PATH#/}"; SUB_PAGE_PATH="${SUB_PAGE_PATH%/}"
SUB_FEED_PATH="$SUB_PAGE_PATH/$(digest "feed:$UUID$SEED" 24)"
case "$WS_PATH" in /*) ;; *) WS_PATH="/$WS_PATH" ;; esac
case "$XHTTP_PATH" in /*) ;; *) XHTTP_PATH="/$XHTTP_PATH" ;; esac
XHTTP_PATH="${XHTTP_PATH%/}"

# ───────────────────── public address / DPI params ─────────────────────
DOMAIN="${DOMAIN:-${RAILWAY_PUBLIC_DOMAIN:-}}"
if [ -z "$DOMAIN" ]; then
  warn "Нет публичного домена: Railway → Settings → Networking → Generate Domain."
  DOMAIN="YOUR-DOMAIN.up.railway.app"
fi
ADDRESS="${ADDRESS:-$DOMAIN}"   # куда реально подключаться (можно IP/CDN-хост)
SNI="${SNI:-$DOMAIN}"           # TLS SNI
HTTP_HOST="${HTTP_HOST:-$DOMAIN}"  # Host / authority — по нему Railway выбирает сервис
PUBLIC_BASE="https://$DOMAIN"
REMARK=$(urlenc "$PROFILE_NAME")

LINK_WS="vless://$UUID@$ADDRESS:443?encryption=none&security=tls&sni=$SNI&fp=$FP&alpn=http%2F1.1&type=ws&host=$HTTP_HOST&path=$(urlenc "$WS_PATH")#$REMARK-WS"
LINK_XHTTP="vless://$UUID@$ADDRESS:443?encryption=none&security=tls&sni=$SNI&fp=$FP&alpn=h2%2Chttp%2F1.1&type=xhttp&host=$HTTP_HOST&path=$(urlenc "$XHTTP_PATH")&mode=packet-up#$REMARK-XHTTP"

# ───────────────────────────── xray config ─────────────────────────────
cat > "$CONFIG" <<EOF
{
  "log": { "loglevel": "$LOG_LEVEL" },
  "inbounds": [
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": $WS_PORT,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "$WS_PATH" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "routeOnly": true }
    },
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": $XHTTP_PORT,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "security": "none", "xhttpSettings": { "path": "$XHTTP_PATH", "mode": "auto" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF

# ───────────────────────────── caddy router ────────────────────────────
cat > "$CADDYFILE" <<EOF
{
	admin off
	auto_https off
	log {
		output stderr
		format console
		level WARN
	}
	servers {
		protocols h1 h2c
	}
}

:$PORT {
	header -Server
	header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet"

	handle /robots.txt {
		header Content-Type "text/plain; charset=utf-8"
		respond "User-agent: *
Disallow: /
" 200
	}

	@ws path $WS_PATH
	handle @ws {
		reverse_proxy 127.0.0.1:$WS_PORT
	}

	@xhttp path $XHTTP_PATH $XHTTP_PATH/*
	handle @xhttp {
		reverse_proxy 127.0.0.1:$XHTTP_PORT {
			flush_interval -1
		}
	}

	@sub path $SUB_PAGE_PATH $SUB_PAGE_PATH/*
	handle @sub {
		reverse_proxy 127.0.0.1:$SUB_PORT
	}

	handle {
		respond "Not Found" 404
	}
}
EOF

# ───────────────────────────── preflight ───────────────────────────────
xray run -test -config "$CONFIG" >/tmp/xray-test.log 2>&1 || { fail "Конфиг xray не прошёл проверку:"; cat /tmp/xray-test.log >&2; exit 1; }
caddy validate --config "$CADDYFILE" --adapter caddyfile >/tmp/caddy-test.log 2>&1 || { fail "Caddyfile не прошёл проверку:"; cat /tmp/caddy-test.log >&2; exit 1; }

# ───────────────────────────── summary ─────────────────────────────────
section "Идентификация"
kv UUID   "${B}$UUID${RS}"
kv source "${D}$UUID_SRC${RS}"
[ -z "$STATE_OK" ] && kv note "${D}без тома UUID берётся из ID сервиса и не меняется между деплоями${RS}"

section "Транспорты"
kv WS     "path    ${CYN}$WS_PATH${RS}"
kv XHTTP  "path    ${CYN}$XHTTP_PATH${RS}  ${D}(packet-up)${RS}"

section "Обход DPI"
kv SNI    "$SNI"
kv Host   "$HTTP_HOST"
kv Addr   "$ADDRESS:443"
kv uTLS   "fp=$FP   ${D}ALPN: ws→http/1.1, xhttp→h2${RS}"
kv Paths  "${D}случайные, стабильные; блок BitTorrent и private-IP${RS}"

section "Подписка для Incy"
kv Page   "${GRN}$PUBLIC_BASE$SUB_PAGE_PATH${RS}"
kv Devices "$([ "$MAX_DEVICES" -gt 0 ] && echo "максимум $MAX_DEVICES (по HWID клиента)" || echo "без ограничений")"
kv Robots "${D}/robots.txt → Disallow: /, X-Robots-Tag: noindex${RS}"

section "Ссылки"
printf '   %sWebSocket%s\n   %s%s%s\n\n' "$B" "$RS" "$CYN" "$LINK_WS" "$RS"
printf '   %sXHTTP%s\n   %s%s%s\n\n' "$B" "$RS" "$CYN" "$LINK_XHTTP" "$RS"

# ───────────────────────────── start ───────────────────────────────────
export SUB_PAGE_PATH SUB_FEED_PATH PUBLIC_BASE LINK_WS LINK_XHTTP PROFILE_NAME MAX_DEVICES NO_COLOR
export SUB_INTERNAL_PORT="$SUB_PORT" STATE_DIR_OK="$STATE_OK"

xray run -config "$CONFIG" & XRAY_PID=$!
python3 /sub.py & SUB_PID=$!
caddy run --config "$CADDYFILE" --adapter caddyfile & CADDY_PID=$!

stop() { kill "$XRAY_PID" "$SUB_PID" "$CADDY_PID" 2>/dev/null || true; }
trap 'stop; exit 0' TERM INT

sleep 1
for pair in "xray:$XRAY_PID" "sub:$SUB_PID" "caddy:$CADDY_PID"; do
  name=${pair%%:*}; pid=${pair##*:}
  if kill -0 "$pid" 2>/dev/null; then ok "$name запущен"; else fail "$name не стартовал"; stop; exit 1; fi
done
ok "Слушаю порт ${B}$PORT${RS}  ${D}— готово к подключениям${RS}"

# watchdog: если любой процесс упал — выходим, Railway перезапустит контейнер
while :; do
  for pair in "xray:$XRAY_PID" "sub:$SUB_PID" "caddy:$CADDY_PID"; do
    name=${pair%%:*}; pid=${pair##*:}
    kill -0 "$pid" 2>/dev/null || { fail "$name завершился, перезапуск контейнера"; stop; exit 1; }
  done
  sleep 2
done
