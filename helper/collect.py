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


def jread(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}


def transcript_facts(sid):
    """model, effort and permission mode from the last 300 KB of the session's transcript (never the whole file)."""
    f = next(iter(glob.glob(f"{HOME}/.claude/projects/*/{sid}.jsonl")), None)
    r = {}
    if not f:
        return r
    try:
        with open(f, "rb") as fh:
            fh.seek(0, 2)
            n = fh.tell()
            fh.seek(max(0, n - 300000))
            lines = fh.read().decode("utf8", "replace").split("\n")[1:]
    except OSError:
        return r
    for l in lines:
        if '"type":"assistant"' not in l and '"type":"mode"' not in l:
            continue
        try:
            d = json.loads(l)
        except Exception:
            continue
        if d.get("type") == "mode":
            r["permission"] = d.get("mode")
        elif not d.get("isSidechain"):
            m = (d.get("message") or {}).get("model")
            if m and m != "<synthetic>":
                r["model_id"] = m
            if d.get("effort"):
                r["effort"] = d["effort"]
    return r


def settings_facts():
    st = jread(HOME + "/.claude/settings.json")
    ep = st.get("enabledPlugins") or {}
    return {"model": st.get("model"), "rc_at_startup": st.get("remoteControlAtStartup"),
            "router_plugin": ep.get("mantra-router@mantra-router"), "fast_mode": st.get("fastMode"),
            "effort_default": ((st.get("modelSettings") or {}).get("claude-fable-5") or {}).get("effortLevel") or st.get("effortLevel"),
            "usage": jread(HOME + "/.cache/claude-usage.json")}


def mcp_names(cwd):
    """names only of the MCP servers configured for the folder (values are never read out)."""
    j = jread(HOME + "/.claude.json")
    names = set((j.get("mcpServers") or {}).keys())
    names |= set((((j.get("projects") or {}).get(cwd) or {}).get("mcpServers") or {}).keys())
    return sorted(names)


def mac():
    out = {"name": "This Mac", "ok": True, "sessions": [], "other": [], "settings": settings_facts()}
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
        bar = jread(f"{HOME}/.cache/mantra-bar/{sid}.json")
        rt = jread(f"{HOME}/.cache/mantra-bar/{sid}.router.json")
        tf = transcript_facts(sid)
        sj = jread(f"{HOME}/.claude/sessions/{s.get('pid')}.json")
        modes = {"model": bar.get("model") or tf.get("model_id"), "model_id": tf.get("model_id"), "effort": tf.get("effort"),
                 "permission": tf.get("permission"), "rc": bar.get("rc") if "rc" in bar else (True if sj.get("bridgeSessionId") else None),
                 "router": rt.get("mode"), "router_pick": rt.get("pick"), "ctx": bar.get("ctx"),
                 "sp": bar.get("sp"), "sx": bar.get("sx"), "wp": bar.get("wp"), "wx": bar.get("wx"),
                 "mcp": mcp_names(s.get("cwd", "")), "fast": None, "version": sj.get("version")}
        out["sessions"].append({"modes": modes, "name": s.get("name"), "sid": sid, "pid": s.get("pid"), "folder": s.get("cwd", "").replace(HOME, "~"),
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
b=$(ls -t ~/.cache/mantra-bar/*.json 2>/dev/null | grep -v -E "router|skill|vox" | head -1); [ -n "$b" ] && echo "BAR $(cat $b)"
r=$(ls -t ~/.cache/mantra-bar/*.router.json 2>/dev/null | head -1); [ -n "$r" ] && echo "ROUTER $(cat $r)"
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
        elif p[0] in ("BAR", "ROUTER"):
            try:
                out[p[0].lower()] = json.loads(line.split(" ", 1)[1])
            except Exception:
                pass
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
        d["model"] = {"A142": "Nothing Phone"}.get(mm[0].strip(), mm[0].strip()[:30] or "?")
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


def plans():
    """~/.mantra-os/plans/<slug>.json written by the master session (MANTRA_MANIFEST modules/claude-code-mantra-os.md 8a),
    with the newest commands of ~/.mantra-os/commands/<slug>/ (their state: sent, done, failed)."""
    out = []
    for f in sorted(glob.glob(HOME + "/.mantra-os/plans/*.json"), key=os.path.getmtime, reverse=True)[:12]:
        p = jread(f)
        if not p:
            continue
        slug = os.path.basename(f)[:-5]
        p["slug"] = slug
        p["age"] = age(os.path.getmtime(f))
        cmds = []
        for c in sorted(glob.glob(f"{HOME}/.mantra-os/commands/{slug}/*.json"), key=os.path.getmtime, reverse=True)[:12]:
            j = jread(c)
            if j:
                cmds.append({k: j.get(k) for k in ("id", "agent", "task", "action", "text", "at", "state", "result")})
        p["commands"] = cmds
        out.append(p)
    return out


TS_CLI = next((p for p in ("/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale") if os.path.exists(p)), "tailscale")


def tailnet():
    """every device on the tailnet with online / offline (tailscale status --json). Addresses stay inside this process."""
    out = {"name": "Devices", "ok": False, "devices": [], "ips": {}}
    rc, o = run([TS_CLI, "status", "--json"], 8)
    try:
        d = json.loads(o)
    except Exception:
        out["note"] = "tailscale did not answer"
        return out
    out["ok"] = True
    for me, p in [(True, d.get("Self") or {})] + [(False, x) for x in (d.get("Peer") or {}).values()]:
        ls = p.get("LastSeen") or ""
        dev = {"name": p.get("HostName"), "os": p.get("OS"), "online": bool(p.get("Online")) or me, "self": me,
               "last_seen": "" if ls.startswith("0001") else ls}
        out["devices"].append(dev)
        ip = next((i for i in (p.get("TailscaleIPs") or []) if "." in i), None)
        if ip:
            out["ips"][p.get("HostName")] = ip
    return out


def open_port(ip, port, t=1.5):
    import socket
    try:
        with socket.create_connection((ip, port), timeout=t):
            return True
    except OSError:
        return False


def reach_phones(ts):
    """online android devices on the tailnet whose adb door (5555) is open get an `adb connect`, so phones that were not on adb show up."""
    for d in ts.get("devices", []):
        ip = ts["ips"].get(d["name"])
        if d.get("os") == "android" and d["online"] and ip and open_port(ip, 5555):
            run([ADB, "connect", ip + ":5555"], 5)


def sessions_file():
    j = jread(HOME + "/.mantra-os/sessions.json")
    return j if isinstance(j, dict) else {}


def merge_sessions(res):
    """The master's ~/.mantra-os/sessions.json (ListAgents, covers Remote Control and cloud sessions) merged with what this app probes
    itself. Dedupe by name; the freshest source wins, with 'as of'."""
    f = sessions_file()
    rows = {}
    asof = f.get("updated") or ""
    for r in f.get("sessions") or []:
        rows[r.get("name")] = {"name": r.get("name"), "kind": r.get("kind"), "state": r.get("state"), "device": r.get("device") or "unknown",
                               "source": "master list", "as_of": asof[11:19]}
    now = time.strftime("%H:%M:%S")
    for s in res["mac"].get("sessions", []):
        old = rows.get(s["name"]) or next((v for v in rows.values() if v["device"] == "Mac" and v["name"].split(" (")[0] == (s["name"] or "").split(" (")[0]), None)
        if old:
            rows.pop(old["name"], None)
        rows[s["name"]] = {"name": s["name"], "kind": (old or {}).get("kind") or "interactive", "state": s.get("status"), "device": "Mac",
                           "source": "probed", "as_of": now, "modes": s.get("modes"), "last": s.get("last")}
    live = lambda dev: any(v["device"] == dev and v["state"] in ("busy", "idle") for v in rows.values())
    vm = res["vm"]
    if vm.get("ok") and vm.get("claude") and not live("chromium-vm"):
        rows["chromium-vm Claude Code (tmux claude)"] = {"name": "chromium-vm Claude Code (tmux claude)", "kind": "interactive", "state": "running",
                                                          "device": "chromium-vm", "source": "probed", "as_of": now, "modes": {"model": (vm.get("bar") or {}).get("model")}}
    for d in res["phones"].get("devices", []):
        if d.get("claude_code"):
            rows["Claude Code on " + d["model"]] = {"name": "Claude Code on " + d["model"], "kind": "Termux", "state": "running", "device": d["model"], "source": "probed", "as_of": now}
    out = list(rows.values())
    tot = {}
    for r in out:
        t = tot.setdefault(r["device"], {})
        t[r["state"] or "unknown"] = t.get(r["state"] or "unknown", 0) + 1
    return {"source": f.get("source") or "no master list yet", "updated": asof, "rows": out, "totals": tot}


def slugify(n):
    return re.sub(r"[^a-z0-9]+", "-", (n or "").lower()).strip("-")


def retire():
    """~/.mantra-os/retire/<session-slug>.json written by the master (state checking|clean|blocked|retired, checks[]), plus the retire
    commands waiting in the queue (state sent|done|failed), keyed by session slug."""
    out = {"files": {}, "queued": {}, "master_slug": ""}
    for f in glob.glob(HOME + "/.mantra-os/retire/*.json"):
        j = jread(f)
        if j:
            out["files"][os.path.basename(f)[:-5]] = j
    for c in sorted(glob.glob(HOME + "/.mantra-os/commands/*/*.json"), key=os.path.getmtime):
        j = jread(c)
        if j.get("action") == "retire":
            out["queued"][slugify(j.get("session"))] = {"state": j.get("state"), "result": j.get("result")}
    pl = sorted(glob.glob(HOME + "/.mantra-os/plans/*.json"), key=os.path.getmtime, reverse=True)
    if pl:
        out["master_slug"] = os.path.basename(pl[0])[:-5]
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
    ts = tailnet()
    try:
        reach_phones(ts)
    except Exception:
        pass
    with ThreadPoolExecutor(4) as ex:
        fs = {k: ex.submit(f) for k, f in (("mac", mac), ("vm", vm), ("phones", phones), ("cloud", cloud))}
        res = {"plans": plans()}
        for k, f in fs.items():
            try:
                res[k] = f.result(timeout=25)
            except Exception as e:
                res[k] = {"name": k, "ok": False, "note": "collector failed: " + type(e).__name__}
    ts.pop("ips", None)
    res["tailnet"] = ts
    res["retire"] = retire()
    res["sessions_all"] = merge_sessions(res)
    res["time"] = time.strftime("%H:%M:%S")
    if "--text" in sys.argv:
        m = res["mac"]
        for s in m.get("sessions", []):
            mo = s["modes"]
            print(f"     model {mo['model']} effort {mo['effort']} perm {mo['permission']} rc {mo['rc']} router {mo['router']}->{mo['router_pick']} ctx {mo['ctx']}% 5h {mo['sp']}% week {mo['wp']}%")
            print(f"mac  {s['name']}  {s['status']}  {s['folder']}  tasks {s['tasks_running']}/{s['tasks_total']}")
        v = res["vm"]
        print("vm  ", "up" if v["ok"] else v["note"], ", ".join(f"{x['name']}={x['active']}" for x in v["services"]))
        for w in v["workers"]:
            print(f"vm   worker {w['name']}: {w['last']}")
        for d in res["phones"].get("devices", []):
            print(f"phone {d['model']}: claude code {'RUNNING' if d['claude_code'] else 'no'}, claude app {'yes' if d['claude_app'] else 'no'}")
        for d in res["tailnet"]["devices"]:
            print(f"net  {d['name']} ({d['os']}): {'online' if d['online'] else 'offline'}")
        for r in res["sessions_all"]["rows"]:
            print(f"sess {r['device']}: {r['name']} [{r['kind']}] {r['state']} ({r['source']})")
        for c in res["cloud"]["items"]:
            print(f"cloud {c['name']} ({c['age']}s ago)")
    else:
        print(json.dumps(res))


main()
