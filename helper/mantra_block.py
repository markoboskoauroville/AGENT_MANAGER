#!/usr/bin/env python3
"""mantra-block: what stopped a worker or the master on something only Marko can do (Agent Manager v16, 9.11.2026).
  mantra-block add --task <n> --who "<worker>" --kind keychain|captcha|hand-test|decision|question|device|login
                   --text "<one line: what Marko must do>" --where "<app:Name[|window title] | url:<link> | session:<sid or name> | phone[:serial]>" --hint "<one sentence: what to do there>" --check "<shell command, exit 0 = solved>" [--file <key file>] [--solve "<extra shell command>"] [--url <link>] [--plan <slug>]
  mantra-block done <id> [--answer "..."]     mantra-block list [--json] [--all]     mantra-block solve <id>
Store: ~/.mantra-os/blockers.jsonl (append only, the last line per id wins). The plan task is mirrored: status "blocked" + "blocker": <id>;
done puts the old status back. `list --json --all` adds what is found by itself: a SecurityAgent window (keychain) and plan tasks
with status "blocked" that have no record. The dashboard column WHAT STOPPED ME shows exactly this list."""
import argparse, glob, json, os, subprocess, sys, time

HOME = os.path.expanduser("~")
FILE = HOME + "/.mantra-os/blockers.jsonl"
PLANS = HOME + "/.mantra-os/plans"
KINDS = ["keychain", "captcha", "hand-test", "decision", "question", "device", "login"]

def now_iso(): return time.strftime("%Y-%m-%dT%H:%M:%S%z")

def read_all():
    d = {}
    try:
        for line in open(FILE):
            line = line.strip()
            if not line: continue
            try: r = json.loads(line)
            except Exception: continue
            if r.get("id"): d[r["id"]] = r
    except FileNotFoundError: pass
    return d

def append(r):
    os.makedirs(os.path.dirname(FILE), exist_ok=True)
    with open(FILE, "a") as f: f.write(json.dumps(r, ensure_ascii=False) + "\n")

def plan_files(): return sorted(glob.glob(PLANS + "/*.json"), key=os.path.getmtime, reverse=True)

def edit_plan(slug, n, fn):
    """fn(task) edits the task; the plan file is rewritten atomically. slug empty = the newest plan that has task n."""
    for f in plan_files():
        if slug and os.path.basename(f)[:-5] != slug: continue
        try: p = json.load(open(f))
        except Exception: continue
        for t in p.get("tasks", []):
            if t.get("n") == n:
                fn(t); p["updated"] = now_iso()
                open(f + ".tmp", "w").write(json.dumps(p, indent=1, ensure_ascii=False)); os.replace(f + ".tmp", f)
                return os.path.basename(f)[:-5]
    return None

def default_check(a):
    """a sensible check for kinds that have one: keychain = no SecurityAgent window; login/key with --file = the file exists and is not empty;
    device/phone = adb reachable and unlocked. Captcha and the rest need an explicit --check."""
    if a.kind == "keychain": return "builtin:no-securityagent"
    if a.kind == "login" and a.file: return "test -s %s" % json.dumps(os.path.expanduser(a.file))
    w = a.where or ""
    if a.kind == "device" and w.startswith("phone"):
        ser = w.partition(":")[2]; ad = "adb" + ((" -s " + ser) if ser else "")
        return '%s get-state 2>/dev/null | grep -q device && ! %s shell dumpsys window 2>/dev/null | grep -q "isStatusBarKeyguard=true"' % (ad, ad)
    return ""

CHK = HOME + "/.mantra-os/blockers-checks.json"; MARK = HOME + "/.mantra-os/.blockers-check-run"

def checks():
    try: return json.load(open(CHK))
    except Exception: return {}

def run_check(cmd):
    if cmd == "builtin:no-securityagent": return not security_agent()
    try:
        return subprocess.run(["/bin/zsh", "-lc", cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15).returncode == 0
    except Exception: return False

def notify(r):
    """tell the waiting worker/master: a command file in the plan's queue, exactly as the dashboard writes it"""
    slug = r.get("plan") or (os.path.basename(plan_files()[0])[:-5] if plan_files() else "master")
    d = HOME + "/.mantra-os/commands/" + slug; os.makedirs(d, exist_ok=True)
    ms = int(time.time() * 1000)
    j = {"id": str(ms), "agent": r.get("who", ""), "task": r.get("task", 0), "action": "message",
         "text": "UNBLOCKED: %s (%s). Marko solved it, it was detected automatically; continue." % (r["id"], r.get("text", "")),
         "at": now_iso(), "state": "sent", "result": "", "via": "mantra-block"}
    open("%s/%d.json" % (d, ms), "w").write(json.dumps(j, indent=1, ensure_ascii=False))

OPEN_ST = ("running", "blocked", "waiting", "paused", "todo")

def task_status(plan, n):
    for f in plan_files():
        if plan and os.path.basename(f)[:-5] != plan: continue
        try: p = json.load(open(f))
        except Exception: continue
        for t in p.get("tasks", []):
            if t.get("n") == n: return t.get("status")
    return None

def tidy(say=False):
    """stale cards go away by themselves, into the hidden history (state "archived" + reason):
    task done / parked / gone = "task finished"; no check and older than 3 h with its task not running or blocked = "old";
    one card per (task, kind) = "duplicate". The plan-derived blocked cards follow the plan by themselves."""
    rs = [r for r in read_all().values() if r.get("state") == "open"]; rs.sort(key=lambda r: r.get("at", 0), reverse=True)
    seen = set(); n = 0
    for r in rs:
        why = ""; t = r.get("task") or 0
        stt = task_status(r.get("plan") or "", t) if t else None
        if t and stt is not None and stt not in OPEN_ST: why = "task finished (%s)" % stt
        elif t and stt is None and time.time() - r.get("at", 0) > 3 * 3600 and not r.get("check"): why = "old, task gone"
        elif not r.get("check") and time.time() - r.get("at", 0) > 3 * 3600 and stt not in ("running", "blocked"): why = "old"
        elif t and (t, r["kind"]) in seen: why = "duplicate"
        elif t: seen.add((t, r["kind"]))
        if why:
            r["state"] = "archived"; r["reason"] = why; r["archivedAt"] = now_iso(); append(r); n += 1
            if say: print("archived %s: %s" % (r["id"], why))
    return n

def cmd_check(a):
    tidy(True)
    """runs the check of every open blocker (at most every 30 s each); solved ones are closed, mirrored into the plan, and the worker is told"""
    st = checks(); n = 0
    for r in read_all().values():
        if r.get("state") != "open" or not r.get("check"): continue
        if not a.force and time.time() - st.get(r["id"], {}).get("at", 0) < 28: continue
        ok = run_check(r["check"]); st[r["id"]] = {"at": time.time(), "ok": ok}
        if ok:
            r["state"] = "done"; r["doneAt"] = now_iso(); r["solved"] = "solved automatically"; append(r); n += 1
            if r.get("task") and not any(x["state"] == "open" and x.get("task") == r["task"] and x.get("plan") == r.get("plan") for x in read_all().values()):
                restore(r.get("plan") or "", r["task"], r["id"])
            notify(r); print("solved automatically " + r["id"])
    open(CHK + ".tmp", "w").write(json.dumps(st)); os.replace(CHK + ".tmp", CHK)

def cmd_add(a):
    if a.kind not in KINDS: sys.exit("kind must be one of " + ", ".join(KINDS))
    bid = "b" + format(int(time.time() * 1000), "x")
    r = {"id": bid, "state": "open", "at": time.time(), "iso": now_iso(), "task": a.task, "who": a.who, "kind": a.kind,
         "text": a.text, "solve": a.solve or "", "url": a.url or "", "where": a.where or "", "hint": a.hint or "", "check": a.check or default_check(a), "file": a.file or "", "plan": ""}
    def mark(t):
        if t.get("status") != "blocked": t["prev"] = t.get("status", "running")
        t["status"] = "blocked"; t["blocker"] = bid
    if a.task:
        r["plan"] = edit_plan(a.plan or "", a.task, mark) or ""
    append(r); print(bid)

def restore(slug, n, bid):
    def fix(t):
        if t.get("blocker") in (bid, None) or str(bid).startswith("plan-"):
            t["status"] = t.pop("prev", None) or "running"; t.pop("blocker", None)
    edit_plan(slug, n, fix)

def cmd_done(a):
    if a.id.startswith("plan-"):
        slug, n = a.id[5:].rsplit("-", 1); restore(slug, int(n), a.id); print("done " + a.id); return
    d = read_all(); r = d.get(a.id)
    if not r: sys.exit("no such blocker " + a.id)
    r["state"] = "done"; r["doneAt"] = now_iso()
    if a.answer: r["answer"] = a.answer
    append(r)
    if r.get("task") and not any(x["state"] == "open" and x.get("task") == r["task"] and x.get("plan") == r.get("plan") for x in read_all().values()):
        restore(r.get("plan") or "", r["task"], a.id)
    print("done " + a.id)

def security_agent():
    js = ('ObjC.import("CoreGraphics");var a=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1,0)));'
          'a.filter(function(w){return w.kCGWindowOwnerName=="SecurityAgent"&&w.kCGWindowLayer>=0}).length')
    try:
        o = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True, timeout=6).stdout.strip()
        return int(o or 0) > 0
    except Exception: return False

def archived():
    out = [r for r in read_all().values() if r.get("state") == "archived"]
    out.sort(key=lambda r: r.get("archivedAt", ""), reverse=True)
    return out[:20]

def open_list(auto):
    tidy()
    out = [r for r in read_all().values() if r.get("state") == "open"]
    if auto:
        if security_agent():
            out.append({"id": "auto-keychain", "state": "open", "at": time.time() - 30, "task": 0, "who": "macOS", "kind": "keychain", "auto": True,
                        "text": "A macOS password prompt (SecurityAgent, e.g. Chrome Safe Storage) is on screen: only you can answer it.",
                        "where": "app:SecurityAgent", "hint": "Type your login password and press Always Allow.", "solve": "", "url": ""})
        have = {(r.get("plan"), r.get("task")) for r in out}
        for f in plan_files()[:12]:
            try: p = json.load(open(f))
            except Exception: continue
            slug = os.path.basename(f)[:-5]
            for t in p.get("tasks", []):
                if t.get("status") == "blocked" and (slug, t.get("n")) not in have and not any(r.get("task") == t.get("n") and not r.get("plan") for r in out):
                    out.append({"id": "plan-%s-%s" % (slug, t.get("n")), "state": "open", "at": os.path.getmtime(f), "task": t.get("n"), "plan": slug,
                                "who": t.get("worker") or t.get("agent") or "plan", "kind": "question", "auto": True,
                                "text": t.get("next") or t.get("title") or "blocked", "solve": "", "url": "",
                                "where": ("session:" + p["session"]) if p.get("session") else "", "hint": "Answer in that session."})
    st = checks()
    for r in out:
        r["has_check"] = bool(r.get("check")); r["checked_at"] = st.get(r["id"], {}).get("at", 0)
        r.pop("check", None)
    out.sort(key=lambda r: r.get("at", 0), reverse=True)
    for r in out: r["age"] = max(0, int(time.time() - r.get("at", time.time())))
    return out

def cmd_list(a):
    if a.archived: print(json.dumps(archived(), ensure_ascii=False)); return
    if a.all:   # the watcher: every list the dashboard asks for starts a check run when 28 s have passed
        try:
            if time.time() - os.path.getmtime(MARK) > 28: raise OSError
        except OSError:
            open(MARK, "w").write(""); subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "check"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    rs = open_list(a.all)
    if a.json: print(json.dumps(rs, ensure_ascii=False)); return
    if not rs: print("Nothing is waiting for you"); return
    for r in rs:
        print("%-14s %-9s task %-3s %-14s %4d min  %s" % (r["id"], r["kind"], r.get("task") or "-", (r.get("who") or "")[:14], r["age"] // 60, r["text"]))

def sh(cmd, t=40):
    return subprocess.run(["/bin/zsh", "-lc", cmd], capture_output=True, text=True, timeout=t)

def sid_for(name):
    """the session id of a Mac session whose name contains `name` (collect.py, no labeler)"""
    if len(name) == 36 and name.count("-") == 4: return name
    try:
        d = json.loads(subprocess.run([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "collect.py"), "--no-labels"],
                                      capture_output=True, text=True, timeout=40).stdout)
        for s in d["mac"]["sessions"]:
            if name.lower() in (s.get("name") or "").lower() or name.lower() == (s.get("base") or "").lower(): return s.get("sid")
    except Exception: pass
    return None

def present(r):
    """bring the real place to the front, where Marko acts; the hint is spoken. Never the BenQ: windows are moved to the MacBook screen."""
    w = r.get("where") or ""; kind, _, arg = w.partition(":"); out = []
    if kind == "app":
        name, _, title = arg.partition("|")
        sh("open -a %s" % json.dumps(name)); time.sleep(0.6)
        if name != "SecurityAgent":
            sh('macro win-snap %s center MacBook' % json.dumps(title or name)); out.append("window moved to the MacBook screen")
            sh('macro win-top %s' % json.dumps(title or name))
        out.append("front: " + name)
    elif kind == "url":
        sh("open %s" % json.dumps(arg)); out.append("opened " + arg)
    elif kind == "session":
        sid = sid_for(arg)
        p = sh("python3 ~/Developer/claude-code/tools/other_sessions.py front %s" % sid) if sid else None
        out.append("session tab in front" if p and p.returncode == 0 else "session tab not found: " + arg)
    elif kind == "phone":
        sh("pgrep -x scrcpy >/dev/null || (scrcpy %s >/dev/null 2>&1 &)" % (("-s " + arg) if arg else "")); time.sleep(1.5)
        sh('macro win-snap scrcpy center MacBook; macro win-top scrcpy'); out.append("phone screen in front")
    if r.get("url") and kind != "url": sh("open %s" % json.dumps(r["url"]))
    if r.get("solve"):
        p = sh(r["solve"], 120); out.append((p.stdout + p.stderr).strip()[-200:] or "solve ran")
    if r.get("hint"):
        subprocess.Popen(["/bin/zsh", "-lc", "langsay en %s" % json.dumps(r["hint"])], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return "; ".join(x for x in out if x) or "nothing to present: " + r["text"]

def cmd_solve(a):
    r = next((x for x in open_list(True) if x["id"] == a.id), None)
    if not r: sys.exit("no open blocker " + a.id)
    print(present(r))

def main():
    ap = argparse.ArgumentParser(prog="mantra-block"); sub = ap.add_subparsers(dest="c", required=True)
    s = sub.add_parser("add"); s.add_argument("--task", type=int, default=0); s.add_argument("--who", default="")
    s.add_argument("--kind", required=True); s.add_argument("--text", required=True); s.add_argument("--solve"); s.add_argument("--url"); s.add_argument("--plan"); s.add_argument("--check"); s.add_argument("--file"); s.add_argument("--where"); s.add_argument("--hint"); s.set_defaults(f=cmd_add)
    s = sub.add_parser("done"); s.add_argument("id"); s.add_argument("--answer"); s.set_defaults(f=cmd_done)
    s = sub.add_parser("list"); s.add_argument("--json", action="store_true"); s.add_argument("--all", action="store_true"); s.add_argument("--archived", action="store_true"); s.set_defaults(f=cmd_list)
    s = sub.add_parser("check"); s.add_argument("--force", action="store_true"); s.set_defaults(f=cmd_check)
    s = sub.add_parser("solve"); s.add_argument("id"); s.set_defaults(f=cmd_solve)
    a = ap.parse_args(); a.f(a)

if __name__ == "__main__": main()
