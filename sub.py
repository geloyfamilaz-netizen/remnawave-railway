#!/usr/bin/env python3
"""Subscription page + feed for xray-railway (stdlib only).

Everything is read from a JSON file written by entrypoint.sh (SUB_CONFIG,
default /tmp/sub.json), so no per-setting env vars are needed:

  {"page_path": "/s/..", "feed_path": "/f/..", "base_url": "https://host",
   "name": "Railway", "max_devices": 1, "state_dir": "", "port": 20003,
   "links": [{"name": "rw-ws", "tag": "TLS · http/1.1", "url": "vless://..."}]}

Routes (everything else -> 404):
  GET <page_path>   HTML page with every link and the "Add to Incy" button
  GET <feed_path>   base64 subscription (what Incy downloads)

Device limit: if the client sends an `x-hwid` header, the first max_devices
distinct HWIDs are remembered and everyone else gets 403.
"""
import base64
import html
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CFG = json.load(open(os.environ.get("SUB_CONFIG", "/tmp/sub.json"), encoding="utf-8"))
PAGE_PATH = CFG["page_path"]
FEED_PATH = CFG["feed_path"]
BASE_URL = CFG["base_url"]
LINKS = CFG["links"]
NAME = CFG.get("name") or "Railway"
MAX_DEVICES = int(CFG.get("max_devices", 1))
STATE_DIR = CFG.get("state_dir") or ""
DEV_FILE = os.path.join(STATE_DIR, "devices.json") if STATE_DIR else ""
PORT = int(CFG.get("port", 20003))

FEED_URL = BASE_URL + FEED_PATH
INCY_URL = "incy://import/" + FEED_URL

D, G, Y, R = "\033[2m", "\033[32m", "\033[33m", "\033[0m"
if os.environ.get("NO_COLOR"):
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
.badge{display:inline-block;font-size:12px;padding:3px 10px;border:1px solid var(--line);border-radius:99px;color:var(--mut);margin:0 6px 14px 0}
.cta{display:block;text-align:center;text-decoration:none;color:#fff;font-weight:600;padding:15px;border-radius:14px;
background:linear-gradient(135deg,var(--acc),var(--acc2));box-shadow:0 8px 24px #4f8cff33;margin-bottom:22px}
.cta:active{transform:scale(.98)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin-bottom:12px}
.card h2{font-size:14px;margin:0 0 8px;display:flex;justify-content:space-between;align-items:center;gap:10px}
.tag{font-size:11px;color:var(--mut);font-weight:400;text-align:right}
code{display:block;word-break:break-all;font:12px/1.45 ui-monospace,Menlo,monospace;color:#b9c8dc;background:#0b1118;
border-radius:8px;padding:9px;max-height:84px;overflow:auto}
button{margin-top:9px;width:100%;background:transparent;color:var(--tx);border:1px solid var(--line);border-radius:10px;padding:10px;font:inherit;font-size:14px;cursor:pointer}
button.ok{border-color:#2fbf71;color:#2fbf71}
small{display:block;color:var(--mut);font-size:12px;margin-top:18px;text-align:center}
a.l{color:var(--acc)}
</style></head><body><main>
<span class="badge">Лимит устройств: __MAX__</span><span class="badge">Подключений: __COUNT__</span>
<h1>__NAME__</h1>
<p class="sub">Если одно подключение режется — переключитесь на другое.</p>
<a class="cta" href="__INCY__">＋ Добавить в Incy</a>
<div class="card"><h2>Подписка <span class="tag">все подключения сразу</span></h2>
<code id="c0">__FEED__</code><button data-c="c0">Скопировать подписку</button></div>
__CARDS__
<small>Не открылось? Установите <a class="l" href="https://apps.apple.com/app/incy/id6756943388">Incy</a> и нажмите кнопку ещё раз,<br>либо вставьте ссылку подписки вручную.</small>
</main><script>
document.querySelectorAll("button").forEach(function(b){b.onclick=function(){
var t=document.getElementById(b.dataset.c).textContent,o=b.textContent;
var done=function(){b.textContent="Скопировано ✓";b.className="ok";setTimeout(function(){b.textContent=o;b.className=""},1400)};
if(navigator.clipboard){navigator.clipboard.writeText(t).then(done)}else{var r=document.createRange();
r.selectNode(document.getElementById(b.dataset.c));getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand("copy");done()}}});
</script></body></html>"""

CARD_TPL = (
    '<div class="card"><h2>{title} <span class="tag">{tag}</span></h2>'
    '<code id="c{n}">{url}</code><button data-c="c{n}">Скопировать ссылку</button></div>'
)


def build_page():
    cards = "\n".join(
        CARD_TPL.format(
            n=i,
            title=html.escape(l["name"]),
            tag=html.escape(l.get("tag", "")),
            url=html.escape(l["url"]),
        )
        for i, l in enumerate(LINKS, 1)
    )
    return (
        PAGE_TPL.replace("__NAME__", html.escape(NAME))
        .replace("__MAX__", str(MAX_DEVICES) if MAX_DEVICES > 0 else "∞")
        .replace("__COUNT__", str(len(LINKS)))
        .replace("__INCY__", html.escape(INCY_URL, quote=True))
        .replace("__FEED__", html.escape(FEED_URL))
        .replace("__CARDS__", cards)
    ).encode()


PAGE = build_page()
FEED = base64.b64encode(("\n".join(l["url"] for l in LINKS) + "\n").encode())
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
