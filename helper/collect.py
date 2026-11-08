#!/usr/bin/env python3
"""collect.py: one JSON overview of every machine's Claude Code sessions, agents and services (Agent Manager (Mantra)).
Read-only. Every remote call has a timeout, so a dead machine shows as "unreachable" and never blocks the rest.
  collect.py            JSON on stdout
  collect.py --text     the same as short lines
No secrets, no addresses: hosts are names (chromium-vm, via ssh over the tailnet), phones are what adb lists."""
import glob, json, os, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

HOME = os.path.expanduser("~")
NOW = time.time()
ADB = next((p for p in (HOME + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb") if os.path.exists(p)), "adb")


def run(cmd, timeout=6):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except Exception as e:
        return 99, str(type(e).__name__)


def age(t):
    return max(0, int(NOW - t))


def files_of(sid):
    """Claude Code keeps a session's tasks in /private/tmp/claude-<uid>/<project>/<id>/tasks. After a resume that <id>
    is not the session id, so a dir counts for a session when it is named so, or when its agent links point into the
    session's transcript."""
    got = []
    for d in glob.glob("/private/tmp/claude-*/*/*/tasks"):
        fs = glob.glob(d + "/*.output")
        if d.split("/")[-2] == sid or any(os.path.islink(f) and sid in os.readlink(f) for f in fs):
            got += fs
    return got


def mac():
    out = {"name": "This Mac", "ok": True, "sessions": [], "other": []}
    sessions = []
    p = HOME + "/Developer/claude-code/tools/other_sessions.py"
    if os.path.exists(p):
        rc, o = run(["/usr/bin/python3", p, "json"], 8)
        try:
            sessions = json.loads(o)
        except Exception:
            sessions = []
    seen = {s.get("pid") for s in sessions}
    for s in sessions:
        sid = s.get("sid", "")
        tasks = []
        for f in files_of(sid):
            try:
                st = os.lstat(f)
                real = os.stat(f).st_mtime
            except OSError:
                continue
            tid = os.path.basename(f)[:-7]
            t = {"id": tid, "age": age(real), "running": age(real) < 90, "kind": "shell"}
            if os.path.islink(f):   # a background agent: its transcript stays unread, only its meta line
                t["kind"] = "agent"
                meta = os.path.realpath(f).replace(".jsonl", ".meta.json")
                try:
                    m = json.load(open(meta))
                    t["desc"] = m.get("description", "")
                    t["type"] = m.get("agentType", "")
                except Exception:
                    pass
            else:
                try:
                    with open(f, "rb") as fh:
                        t["desc"] = fh.readline(200).decode("utf8", "replace").strip()
                except OSError:
                    pass
            tasks.append(t)
        tasks.sort(key=lambda t: t["age"])
        out["sessions"].append({"name": s.get("name"), "sid": sid, "pid": s.get("pid"), "folder": s.get("cwd", "").replace(HOME, "~"),
                                "status": s.get("status"), "last": (s.get("last") or "")[:160], "tasks": tasks[:12],
                                "tasks_total": len(tasks), "tasks_running": sum(1 for t in tasks if t["running"])})
    rc, o = run(["/bin/ps", "-axo", "pid=,command="], 4)
    for line in o.splitlines():
        m = re.match(r"\s*(\d+)\s+(.*)", line)
        if m and re.search(r"(^|/)claude( |$)", m.group(2)) and int(m.group(1)) not in seen:
            out["other"].append({"pid": int(m.group(1)), "cmd": m.group(2)[:100]})
    return out


VM_SCRIPT = r'''
for u in $(systemctl list-units --no-legend --plain --all "chromium-vm*" | awk '{print $1}'); do
  echo "UNIT $u $(systemctl is-active $u) $(systemctl show -p Description --value $u | cut -c1-90)"; done
for d in ~/.config/chromium-vm/workers/*/; do n=$(basename $d); [ -f $d/worker.log ] && echo "WORKER $n $(stat -c %Y $d/worker.log) $(tail -n1 $d/worker.log | cut -c1-140)"; done
echo "CLAUDE $(pgrep -fc '/.local/bin/claude' || true)"
curl -s -m3 -o /dev/null -w "AGENT %{http_code}\n" http://$(tailscale ip -4 2>/dev/null | head -1):8890/ || echo "AGENT 0"
'''


def vm():
    out = {"name": "chromium-vm", "ok": False, "services": [], "workers": [], "claude": None, "note": ""}
    rc, o = run(["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=3", "ubuntu@chromium-vm", VM_SCRIPT], 14)
    if rc != 0 and not o:
        out["note"] = "unreachable (ssh over Tailscale)"
        return out
    out["ok"] = True
    for line in o.splitlines():
        p = line.split(" ", 3)
        if p[0] == "UNIT" and len(p) >= 3:
            rest = line.split(" ", 3)
            out["services"].append({"name": rest[1].replace("chromium-vm-", "").replace(".service", ""), "active": rest[2], "desc": rest[3] if len(rest) > 3 else ""})
        elif p[0] == "WORKER":
            q = line.split(" ", 3)
            out["workers"].append({"name": q[1], "age": age(int(q[2])), "last": q[3] if len(q) > 3 else ""})
        elif p[0] == "CLAUDE":
            out["claude"] = int(p[1]) > 0
        elif p[0] == "AGENT":
            out["vm_agent"] = p[1] == "200" or (p[1].isdigit() and int(p[1]) > 0)
    return out


def phones():
    out = {"name": "Phones", "ok": True, "devices": []}
    rc, o = run([ADB, "devices"], 6)
    devs = [l.split()[0] for l in o.splitlines()[1:] if l.strip().endswith("device")]

    def one(s):
        d = {"serial": s, "model": "", "claude_code": False, "claude_app": False}
        rc, m = run([ADB, "-s", s, "shell", "getprop ro.product.model; getprop ro.serialno"], 5)
        mm = m.split("\n")
        d["model"] = mm[0].strip()[:30] or "?"
        d["uid"] = mm[1].strip() if len(mm) > 1 else s
        d["via"] = "emulator" if s.startswith("emulator") else ("usb" if not re.match(r"^\d+\.\d+", s) else "network")
        if s.startswith("emulator"):
            d["model"] = "emulator " + d["model"]
        rc, ps = run([ADB, "-s", s, "shell", "ps -A -o NAME,ARGS 2>/dev/null || ps -A"], 6)
        for l in ps.splitlines():
            if "com.anthropic.claude" in l:
                d["claude_app"] = True
            elif re.search(r"(^|[ /])claude( |$)|claude-code|@anthropic-ai", l) and "ps -A" not in l:
                d["claude_code"] = True
        if rc != 0:
            d["note"] = "adb did not answer"
        return d
    with ThreadPoolExecutor(6) as ex:
        allv = list(ex.map(one, devs))
    seen, devs2 = {}, []
    for d in allv:   # one phone on USB and on the network is one phone
        if d["uid"] in seen:
            seen[d["uid"]]["via"] += "+" + d["via"]
            continue
        seen[d["uid"]] = d; devs2.append(d)
    for d in devs2:
        d["serial"] = d["uid"][:4] + "…" if d["via"] != "emulator" else "emulator"
        d.pop("uid", None)
    out["devices"] = devs2
    if not devs:
        out["ok"] = False
        out["note"] = "no phone on adb"
    return out


def cloud():
    out = {"name": "Cloud sessions", "ok": True, "items": [],
           "note": "from the hub's INBOX (messages they pushed); a live list of cloud sessions has no cheap source yet"}
    for f in sorted(glob.glob(HOME + "/Developer/claude-code/INBOX/*.md"), key=os.path.getmtime, reverse=True)[:8]:
        if os.path.basename(f) == "README.md":
            continue
        try:
            first = next((l.strip("# \n") for l in open(f, errors="replace") if l.strip()), "")
        except OSError:
            first = ""
        out["items"].append({"name": os.path.basename(f)[:-3], "age": age(os.path.getmtime(f)), "first": first[:120]})
    return out


def main():
    with ThreadPoolExecutor(4) as ex:
        fs = {k: ex.submit(f) for k, f in (("mac", mac), ("vm", vm), ("phones", phones), ("cloud", cloud))}
        res = {}
        for k, f in fs.items():
            try:
                res[k] = f.result(timeout=25)
            except Exception as e:
                res[k] = {"name": k, "ok": False, "note": "collector failed: " + type(e).__name__}
    res["time"] = time.strftime("%H:%M:%S")
    if "--text" in sys.argv:
        m = res["mac"]
        for s in m.get("sessions", []):
            print(f"mac  {s['name']}  {s['status']}  {s['folder']}  tasks {s['tasks_running']}/{s['tasks_total']}")
        v = res["vm"]
        print("vm  ", "up" if v["ok"] else v["note"], ", ".join(f"{x['name']}={x['active']}" for x in v["services"]))
        for w in v["workers"]:
            print(f"vm   worker {w['name']}: {w['last']}")
        for d in res["phones"].get("devices", []):
            print(f"phone {d['model']}: claude code {'RUNNING' if d['claude_code'] else 'no'}, claude app {'yes' if d['claude_app'] else 'no'}")
        for c in res["cloud"]["items"]:
            print(f"cloud {c['name']} ({c['age']}s ago)")
    else:
        print(json.dumps(res))


main()
