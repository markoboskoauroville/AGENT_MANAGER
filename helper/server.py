#!/usr/bin/env python3
"""Agent Manager (CEO) (Mantra): the phone door. A tiny HTTP API bound ONLY to this Mac's Tailscale address (100.x),
never 0.0.0.0, never the LAN. Token in ~/Downloads/API/agent-manager-token.txt (created here if missing, never printed).
  GET  /overview   the collect.py JSON      GET /plans   the plans (fresh from the files)   GET /live?since=N   long poll, held up to 20 s until something changes (v22)   GET /blockers   POST /blocker/solve|done {id}    POST /command   one command file, as the Mac app writes it
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

token()  # makes sure the file exists; every request re-reads it, so a rotation needs no restart

def current():
    try: return open(TOKEN_FILE).read().strip()
    except OSError: return ""
_lock = threading.Lock(); _cache = {"at": 0.0, "data": None, "hash": ""}
_cv = threading.Condition(); _ver = {"n": 1, "plansig": ""}

def _jread(p):
    try: return json.load(open(p))
    except Exception: return {}

def fresh_plans():
    """read straight from the files on every call (no 3 s collector wait): ~/.mantra-os/plans + newest commands"""
    import glob
    out = []
    for f in sorted(glob.glob(MOS + "/plans/*.json"), key=os.path.getmtime, reverse=True)[:12]:
        p = _jread(f)
        if not p: continue
        slug = os.path.basename(f)[:-5]
        p["slug"] = slug; p["age"] = int(time.time() - os.path.getmtime(f))
        cmds = []
        for c in sorted(glob.glob("%s/commands/%s/*.json" % (MOS, slug)), key=os.path.getmtime, reverse=True)[:12]:
            j = _jread(c)
            if j: cmds.append({k: j.get(k) for k in ("id", "agent", "task", "action", "text", "at", "state", "result")})
        p["commands"] = cmds
        out.append(p)
    return out

def plansig():
    import glob
    sig = []
    for f in glob.glob(MOS + "/plans/*.json") + glob.glob(MOS + "/commands/*/*.json"):
        try: st = os.stat(f); sig.append((f, st.st_mtime_ns, st.st_size))
        except OSError: pass
    return hash(tuple(sorted(sig)))

def _bump():
    with _cv:
        _ver["n"] += 1; _cv.notify_all()

def collector_loop():
    """keeps the heavy overview (sessions, phones, vm, usage) fresh in the background, every ~2 s after the last run ends;
    watches the plan files every 0.4 s and wakes the live waiters the moment one changes"""
    last_heavy = 0.0
    while True:
        try:
            sig = plansig()
            if sig != _ver["plansig"]:
                _ver["plansig"] = sig; _bump()
            if time.time() - last_heavy > 2:
                r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "collect.py"), "--json"], capture_output=True, timeout=45)
                d = json.loads(r.stdout)
                h = json.dumps({k: v for k, v in d.items() if k not in ("time", "plans")}, sort_keys=True)
                with _lock:
                    changed = h != _cache["hash"]
                    _cache.update(at=time.time(), data=d, hash=h)
                if changed: _bump()
                last_heavy = time.time()
        except Exception:
            time.sleep(2)
        time.sleep(0.4)

def overview():
    with _lock:
        d = dict(_cache["data"]) if _cache["data"] else None
        at = _cache["at"]
    if d is None: return {"error": "collector starting"}
    d["plans"] = fresh_plans()
    d["served_at"] = time.strftime("%H:%M:%S")
    d["data_age"] = int(time.time() - at)
    d["ver"] = _ver["n"]
    return d

def live(since, wait=20):
    """long poll: answers at once when `since` is not the current version, else holds up to `wait` s for a change"""
    with _cv:
        if since == _ver["n"]: _cv.wait(wait)
    return overview()

def plans():
    return fresh_plans()

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

def block(*args):
    """mantra_block.py next to this file: list | solve <id> | done <id>"""
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "mantra_block.py")] + list(args), capture_output=True, text=True, timeout=130)
    return r.returncode, (r.stdout + r.stderr).strip()[-300:]

class H(BaseHTTPRequestHandler):
    server_version = "AgentManager"
    def log_message(self, *a): pass
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def _auth(self):
        got = self.headers.get("Authorization", "")
        if got.startswith("Bearer ") and current() and hmac.compare_digest(got[7:].strip().encode(), current().encode()): return True
        self._send(401, {"error": "token"}); return False
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/ping": return self._send(200, {"ok": True, "t": time.time()})
        if not self._auth(): return
        if path == "/overview": return self._send(200, overview())
        if path == "/live":
            try: since = int(self.path.split("since=")[1].split("&")[0])
            except Exception: since = -1
            return self._send(200, live(since))
        if path == "/plans": return self._send(200, plans())
        if path == "/blockers":
            b = (_cache["data"] or {}).get("blockers")
            if b is not None: return self._send(200, b)
            rc, o = block("list", "--json", "--all")
            try: return self._send(200, json.loads(o))
            except Exception: return self._send(500, {"error": "blockers"})
        self._send(404, {"error": "not found"})
    def do_POST(self):
        if not self._auth(): return
        pth = self.path.split("?")[0]
        if pth in ("/blocker/solve", "/blocker/done"):
            try: b = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", "0")), 4000)) or b"{}")
            except Exception: return self._send(400, {"error": "bad json"})
            bid = str(b.get("id", ""))
            if not re.match(r"^[A-Za-z0-9_.-]{1,120}$", bid): return self._send(400, {"error": "bad id"})
            rc, o = block(pth.split("/")[2], bid)
            return self._send(200 if rc == 0 else 500, {"ok": rc == 0, "result": o})
        if pth != "/command": return self._send(404, {"error": "not found"})
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
    threading.Thread(target=collector_loop, daemon=True).start()
    srv.serve_forever()

if __name__ == "__main__": main()
