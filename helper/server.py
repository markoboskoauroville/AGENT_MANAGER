#!/usr/bin/env python3
"""Agent Manager (CEO) (Mantra): the phone door. A tiny HTTP API bound ONLY to this Mac's Tailscale address (100.x),
never 0.0.0.0, never the LAN. Token in ~/Downloads/API/agent-manager-token.txt (created here if missing, never printed).
  GET  /overview   the collect.py JSON      GET /plans   the plans    POST /command   one command file, as the Mac app writes it
Started and stopped by the app (one app owns its engine). Port 8847."""
import hmac, json, os, re, secrets, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8847
HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE = os.path.expanduser("~/Downloads/API/agent-manager-token.txt")
MOS = os.path.expanduser("~/.mantra-os")
TS = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "tailscale"]
ACTIONS = {"pause", "stop", "message", "reprompt", "retire"}
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,80}$")

def tailscale_ip():
    for exe in TS:
        try:
            out = subprocess.run([exe, "ip", "-4"], capture_output=True, text=True, timeout=8).stdout.split()
            for ip in out:
                if ip.startswith("100."): return ip
        except Exception: pass
    return None

def token():
    try:
        t = open(TOKEN_FILE).read().strip()
        if t: return t
    except FileNotFoundError: pass
    os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
    t = secrets.token_urlsafe(32)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f: f.write(t + "\n")
    return t

TOK = token()
_lock = threading.Lock(); _cache = {"at": 0.0, "data": None}

def overview():
    with _lock:
        if _cache["data"] is None or time.time() - _cache["at"] > 4:
            try:
                r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "collect.py"), "--json"], capture_output=True, timeout=45)
                _cache["data"] = json.loads(r.stdout); _cache["at"] = time.time()
            except Exception as e:
                if _cache["data"] is None: return {"error": "collect failed: %s" % type(e).__name__}
        d = dict(_cache["data"]); d["served_at"] = time.strftime("%H:%M:%S")
        return d

def plans():
    return overview().get("plans", [])

def write_command(b):
    action = str(b.get("action", ""))
    if action not in ACTIONS: return 400, {"error": "action must be one of " + ", ".join(sorted(ACTIONS))}
    slug = str(b.get("slug", ""))
    if action == "retire" and not slug:
        slug = ((overview().get("retire") or {}).get("master_slug")) or ""
    if not SLUG.match(slug): return 400, {"error": "bad slug"}
    if action != "retire" and not os.path.exists(os.path.join(MOS, "plans", slug + ".json")): return 404, {"error": "no such plan"}
    text = str(b.get("text", ""))[:4000]
    if action in ("message", "reprompt") and not text.strip(): return 400, {"error": "text is empty"}
    try: task = int(b.get("task", 0))
    except Exception: return 400, {"error": "bad task"}
    ms = int(time.time() * 1000)
    j = {"id": str(ms), "agent": str(b.get("agent", ""))[:200], "task": task, "action": action, "text": text,
         "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")[:-2] + ":" + time.strftime("%z")[-2:], "state": "sent", "result": "", "via": "phone"}
    if action == "retire":
        for k in ("session", "device", "kind"): j[k] = str(b.get(k, ""))[:200]
    d = os.path.join(MOS, "commands", slug); os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "%d.json" % ms)
    while os.path.exists(p): ms += 1; j["id"] = str(ms); p = os.path.join(d, "%d.json" % ms)
    with open(p + ".tmp", "w") as f: json.dump(j, f, indent=1)
    os.rename(p + ".tmp", p)
    return 200, {"ok": True, "id": j["id"], "slug": slug}

class H(BaseHTTPRequestHandler):
    server_version = "AgentManager"
    def log_message(self, *a): pass
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def _auth(self):
        got = self.headers.get("Authorization", "")
        if got.startswith("Bearer ") and hmac.compare_digest(got[7:].strip(), TOK): return True
        self._send(401, {"error": "token"}); return False
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/ping": return self._send(200, {"ok": True})
        if not self._auth(): return
        if path == "/overview": return self._send(200, overview())
        if path == "/plans": return self._send(200, plans())
        self._send(404, {"error": "not found"})
    def do_POST(self):
        if not self._auth(): return
        if self.path.split("?")[0] != "/command": return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n > 20000: return self._send(413, {"error": "too large"})
            b = json.loads(self.rfile.read(n) or b"{}")
        except Exception: return self._send(400, {"error": "bad json"})
        code, obj = write_command(b); self._send(code, obj)

def main():
    while True:  # Tailscale may not be up yet: wait for its address, bind only to it
        ip = tailscale_ip()
        if ip:
            try:
                srv = ThreadingHTTPServer((ip, PORT), H); break
            except OSError as e:
                print("bind %s:%d failed: %s" % (ip, PORT, e), file=sys.stderr); sys.exit(1)
        time.sleep(15)
    print("agent-manager door on %s:%d" % (ip, PORT), flush=True)
    srv.serve_forever()

if __name__ == "__main__": main()
