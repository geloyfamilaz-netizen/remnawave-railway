#!/usr/bin/env python3
"""Subscription page + feed for xray-railway (stdlib only).

Routes (everything else -> 404):
  GET <SUB_PAGE_PATH>   HTML page with both links and the "Add to Incy" button
  GET <SUB_FEED_PATH>   base64 subscription (what Incy downloads)

Device limit: if the client sends an `x-hwid` header, the first MAX_DEVICES
distinct HWIDs are remembered and everyone else gets 403.
"""
import base64
import html
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

E = os.environ
PAGE_PATH = E["SUB_PAGE_PATH"]
FEED_PATH = E["SUB_FEED_PATH"]
BASE_URL = E["PUBLIC_BASE"]
LINK_WS = E["LINK_WS"]
LINK_XHTTP = E["LINK_XHTTP"]
NAME = E.get("PROFILE_NAME", "Railway")
MAX_DEVICES = int(E.get("MAX_DEVICES", "1"))
STATE_DIR = E.get("STATE_DIR_OK", "")
DEV_FILE = os.path.join(STATE_DIR, "devices.json") if STATE_DIR else ""
PORT = int(E.get("SUB_INTERNAL_PORT", "20003"))

FEED_URL = BASE_URL + FEED_PATH
INCY_URL = "incy://import/" + FEED_URL

D, G, Y, R = "\033[2m", "\033[32m", "\033[33m", "\033[0m"
if E.get("NO_COLOR"):
    D = G = Y = R = ""


def log(msg):
    print(f"{D}[sub]{R} {msg}", flush=True)


# ---------------------------------------------------------------- devices
_lock = threading.Lock()
_devices = []
if DEV_FILE and os.path.exists(DEV_FILE):
    try:
        _devices = json.load(open(DEV_FILE))
    except Exception:
        _devices = []


def check_device(hwid):
    """True if this HWID may fetch the subscription."""
    if MAX_DEVICES <= 0 or not hwid:
        return True
    with _lock:
        if hwid in _devices:
            return True
        if len(_devices) < MAX_DEVICES:
            _devices.append(hwid)
            if DEV_FILE:
                try:
                    json.dump(_devices, open(DEV_FILE, "w"))
                except Exception:
                    pass
            log(f"{G}device bound{R} {hwid[:8]}… ({len(_devices)}/{MAX_DEVICES})")
            return True
    return False


# ------------------------------------------------------------------- page
PAGE_TPL = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow,noarchive,nosnippet">
<meta name="referrer" content="no-referrer">
<title>__NAME__ — подписка</title><link rel="icon" href="data:,">
<style>
:root{color-scheme:dark;--bg:#0b0f14;--card:#121923;--line:#1f2a38;--tx:#e6edf5;--mut:#8a9bb0;--acc:#4f8cff;--acc2:#7b5cff}
*{box-sizing:border-box}html,body{margin:0}
body{background:radial-gradient(900px 500px at 50% -10%,#16223a,var(--bg));color:var(--tx);
font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;min-height:100vh;display:flex;justify-content:center;padding:28px 16px}
main{width:100%;max-width:520px}
h1{font-size:22px;margin:0 0 4px}p.sub{margin:0 0 20px;color:var(--mut);font-size:14px}
.badge{display:inline-block;font-size:12px;padding:3px 10px;border:1px solid var(--line);border-radius:99px;color:var(--mut);margin-bottom:14px}
.cta{display:block;text-align:center;text-decoration:none;color:#fff;font-weight:600;padding:15px;border-radius:14px;
background:linear-gradient(135deg,var(--acc),var(--acc2));box-shadow:0 8px 24px #4f8cff33;margin-bottom:22px}
.cta:active{transform:scale(.98)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin-bottom:12px}
.card h2{font-size:14px;margin:0 0 8px;display:flex;justify-content:space-between;align-items:center}
.tag{font-size:11px;color:var(--mut);font-weight:400}
code{display:block;word-break:break-all;font:12px/1.45 ui-monospace,Menlo,monospace;color:#b9c8dc;background:#0b1118;
border-radius:8px;padding:9px;max-height:84px;overflow:auto}
button{margin-top:9px;width:100%;background:transparent;color:var(--tx);border:1px solid var(--line);border-radius:10px;padding:10px;font:inherit;font-size:14px;cursor:pointer}
button.ok{border-color:#2fbf71;color:#2fbf71}
small{display:block;color:var(--mut);font-size:12px;margin-top:18px;text-align:center}
a.l{color:var(--acc)}
</style></head><body><main>
<span class="badge">Лимит устройств: __MAX__</span>
<h1>__NAME__</h1>
<p class="sub">Две точки входа: WebSocket и XHTTP. Если одна режется — переключитесь на другую.</p>
<a class="cta" href="__INCY__">＋ Добавить в Incy</a>
<div class="card"><h2>Подписка <span class="tag">обе ссылки сразу</span></h2>
<code id="c0">__FEED__</code><button data-c="c0">Скопировать подписку</button></div>
<div class="card"><h2>VLESS · WebSocket <span class="tag">TLS · http/1.1</span></h2>
<code id="c1">__WS__</code><button data-c="c1">Скопировать ссылку</button></div>
<div class="card"><h2>VLESS · XHTTP <span class="tag">TLS · h2 · packet-up</span></h2>
<code id="c2">__GRPC__</code><button data-c="c2">Скопировать ссылку</button></div>
<small>Не открылось? Установите <a class="l" href="https://apps.apple.com/app/incy/id6756943388">Incy</a> и нажмите кнопку ещё раз,<br>либо вставьте ссылку подписки вручную.</small>
</main><script>
document.querySelectorAll("button").forEach(function(b){b.onclick=function(){
var t=document.getElementById(b.dataset.c).textContent,o=b.textContent;
var done=function(){b.textContent="Скопировано ✓";b.className="ok";setTimeout(function(){b.textContent=o;b.className=""},1400)};
if(navigator.clipboard){navigator.clipboard.writeText(t).then(done)}else{var r=document.createRange();
r.selectNode(document.getElementById(b.dataset.c));getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand("copy");done()}}});
</script></body></html>"""

PAGE = (
    PAGE_TPL.replace("__NAME__", html.escape(NAME))
    .replace("__MAX__", str(MAX_DEVICES) if MAX_DEVICES > 0 else "∞")
    .replace("__INCY__", html.escape(INCY_URL, quote=True))
    .replace("__FEED__", html.escape(FEED_URL))
    .replace("__WS__", html.escape(LINK_WS))
    .replace("__GRPC__", html.escape(LINK_XHTTP))
).encode()

FEED = base64.b64encode((LINK_WS + "\n" + LINK_XHTTP + "\n").encode())
TITLE = "base64:" + base64.b64encode(NAME.encode()).decode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def version_string(self):
        return "nginx"

    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype="text/plain; charset=utf-8", extra=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Robots-Tag", "noindex, nofollow, noarchive")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == PAGE_PATH:
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if path == FEED_PATH:
            hwid = self.headers.get("x-hwid", "").strip()[:128]
            if not check_device(hwid):
                log(f"{Y}device limit{R} rejected {hwid[:8]}… "
                    f"({self.headers.get('x-device-model', '?')})")
                return self._send(403, b"Device limit reached\n")
            return self._send(200, FEED, extra=(
                ("profile-title", TITLE),
                ("profile-update-interval", "12"),
            ))
        return self._send(404, b"Not Found\n")



if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
