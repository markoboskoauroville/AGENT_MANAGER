#!/usr/bin/env python3
"""mantra-block: what stopped a worker or the master on something only Marko can do (Agent Manager v16, 9.11.2026).
  mantra-block add --task <n> --who "<worker>" --kind keychain|captcha|hand-test|decision|question|device|login
                   --text "<one line: what Marko must do>" [--solve "<shell command that presents it again>"] [--url <link>] [--plan <slug>]
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

def cmd_add(a):
    if a.kind not in KINDS: sys.exit("kind must be one of " + ", ".join(KINDS))
    bid = "b" + format(int(time.time() * 1000), "x")
    r = {"id": bid, "state": "open", "at": time.time(), "iso": now_iso(), "task": a.task, "who": a.who, "kind": a.kind,
         "text": a.text, "solve": a.solve or "", "url": a.url or "", "plan": ""}
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
        _, slug, n = a.id.split("-", 2); restore(slug, int(n), a.id); print("done " + a.id); return
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

def open_list(auto):
    out = [r for r in read_all().values() if r.get("state") == "open"]
    if auto:
        if security_agent():
            out.append({"id": "auto-keychain", "state": "open", "at": time.time() - 30, "task": 0, "who": "macOS", "kind": "keychain", "auto": True,
                        "text": "A macOS password prompt (SecurityAgent, e.g. Chrome Safe Storage) is on screen: only you can answer it.",
                        "solve": "osascript -e 'tell application \"SecurityAgent\" to activate'", "url": ""})
        have = {(r.get("plan"), r.get("task")) for r in out}
        for f in plan_files()[:12]:
            try: p = json.load(open(f))
            except Exception: continue
            slug = os.path.basename(f)[:-5]
            for t in p.get("tasks", []):
                if t.get("status") == "blocked" and (slug, t.get("n")) not in have and not any(r.get("task") == t.get("n") and not r.get("plan") for r in out):
                    out.append({"id": "plan-%s-%s" % (slug, t.get("n")), "state": "open", "at": os.path.getmtime(f), "task": t.get("n"), "plan": slug,
                                "who": t.get("worker") or t.get("agent") or "plan", "kind": "question", "auto": True,
                                "text": t.get("next") or t.get("title") or "blocked", "solve": "", "url": ""})
    out.sort(key=lambda r: r.get("at", 0), reverse=True)
    for r in out: r["age"] = max(0, int(time.time() - r.get("at", time.time())))
    return out

def cmd_list(a):
    rs = open_list(a.all)
    if a.json: print(json.dumps(rs, ensure_ascii=False)); return
    if not rs: print("Nothing is waiting for you"); return
    for r in rs:
        print("%-14s %-9s task %-3s %-14s %4d min  %s" % (r["id"], r["kind"], r.get("task") or "-", (r.get("who") or "")[:14], r["age"] // 60, r["text"]))

def cmd_solve(a):
    r = next((x for x in open_list(True) if x["id"] == a.id), None)
    if not r: sys.exit("no open blocker " + a.id)
    if r.get("solve"):
        p = subprocess.run(["/bin/zsh", "-lc", r["solve"]], capture_output=True, text=True, timeout=120)
        print((p.stdout + p.stderr).strip()[-300:] or "solve ran"); sys.exit(0 if p.returncode == 0 else 1)
    if r.get("url"):
        subprocess.run(["/usr/bin/open", r["url"]]); print("opened " + r["url"]); return
    print("nothing to present: " + r["text"])

def main():
    ap = argparse.ArgumentParser(prog="mantra-block"); sub = ap.add_subparsers(dest="c", required=True)
    s = sub.add_parser("add"); s.add_argument("--task", type=int, default=0); s.add_argument("--who", default="")
    s.add_argument("--kind", required=True); s.add_argument("--text", required=True); s.add_argument("--solve"); s.add_argument("--url"); s.add_argument("--plan"); s.set_defaults(f=cmd_add)
    s = sub.add_parser("done"); s.add_argument("id"); s.add_argument("--answer"); s.set_defaults(f=cmd_done)
    s = sub.add_parser("list"); s.add_argument("--json", action="store_true"); s.add_argument("--all", action="store_true"); s.set_defaults(f=cmd_list)
    s = sub.add_parser("solve"); s.add_argument("id"); s.set_defaults(f=cmd_solve)
    a = ap.parse_args(); a.f(a)

if __name__ == "__main__": main()
