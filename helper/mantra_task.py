#!/usr/bin/env python3
"""mantra-task: update a task monitor plan from any session, worker or script (Agent Manager v27, 14.11.2026).
Marko, 14.11.2026: "I want to see check marks, to do list, speed of transferring, waiting for what, estimated time of finishing."
  mantra-task --plan <slug> step <n> "<step title>" todo|running|done|failed   (the step is added when the title is new)
  mantra-task --plan <slug> progress <n> <0-100> [--eta <seconds from now>] [--eta-at <ISO time>] [--speed "1.2 MB/s"] [--waiting "GitHub Actions build"]
  mantra-task --plan <slug> status <n> todo|running|paused|done|failed
  mantra-task --plan <slug> add "<title>" [--steps "one|two|three"] [--agent <id>]
  mantra-task --plan <slug> speed <n> "<text>"     mantra-task --plan <slug> waiting <n> "<text>"   (empty text clears)
  mantra-task new <slug> --project "<name>" --goal "<sentence>"     mantra-task --plan <slug> show
Plan file: ~/.mantra-os/plans/<slug>.json, rewritten atomically (.tmp, rename) under a lock. Format: MANTRA_MANIFEST
modules/claude-code-mantra-os.md 8a. Task fields written: steps[{title,status}], progress, eta (ISO), speed, waitingFor, started, updated."""
import argparse, fcntl, json, os, sys, time

PLANS = os.path.expanduser("~/.mantra-os/plans")
STATUS = ["todo", "running", "paused", "done", "failed"]
STEP = ["todo", "running", "done", "failed"]

def iso(t=None): return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(t))

def path(slug): return os.path.join(PLANS, slug + ".json")

def die(msg): print("mantra-task: " + msg, file=sys.stderr); sys.exit(1)

class Locked:
    def __init__(self, slug): self.slug = slug
    def __enter__(self):
        os.makedirs(PLANS, exist_ok=True)
        self.lk = open(os.path.join(PLANS, "." + self.slug + ".lock"), "w"); fcntl.flock(self.lk, fcntl.LOCK_EX)
        try: self.p = json.load(open(path(self.slug)))
        except FileNotFoundError: die("no plan " + self.slug + " (create it with: mantra-task new <slug> --project ... --goal ...)")
        return self.p
    def __exit__(self, et, ev, tb):
        if et is None:
            self.p["updated"] = iso()
            tmp = path(self.slug) + ".tmp"
            with open(tmp, "w") as f: json.dump(self.p, f, ensure_ascii=False, indent=1)
            os.replace(tmp, path(self.slug))
        fcntl.flock(self.lk, fcntl.LOCK_UN); self.lk.close()

def task_of(p, n):
    for t in p.setdefault("tasks", []):
        if t.get("n") == n: return t
    die("no task %d in the plan" % n)

def touch(t): t["updated"] = iso()

def set_status(t, s):
    if t.get("status") == s: return
    t["status"] = s
    if s == "running" and not t.get("started"): t["started"] = iso()
    if s == "done":
        t["doneAt"] = iso(); t["progress"] = 100; t.pop("eta", None); t.pop("waitingFor", None)
        for st in t.get("steps", []): st["status"] = "done" if st.get("status") != "failed" else "failed"
    if s == "failed": t.pop("eta", None)

def main():
    ap = argparse.ArgumentParser(prog="mantra-task", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", help="plan slug (file name without .json)")
    ap.add_argument("cmd", choices=["step", "progress", "status", "add", "speed", "waiting", "new", "show"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--eta", type=float); ap.add_argument("--eta-at"); ap.add_argument("--speed"); ap.add_argument("--waiting")
    ap.add_argument("--steps"); ap.add_argument("--agent", default=""); ap.add_argument("--project", default=""); ap.add_argument("--goal", default="")
    a = ap.parse_args()
    if a.cmd == "new":
        if not a.args: die("new <slug>")
        slug = a.args[0]
        if os.path.exists(path(slug)): print("exists: " + path(slug)); return
        os.makedirs(PLANS, exist_ok=True)
        with open(path(slug) + ".tmp", "w") as f: json.dump({"project": a.project, "session": a.project or slug, "goal": a.goal, "updated": iso(), "tasks": []}, f, ensure_ascii=False, indent=1)
        os.replace(path(slug) + ".tmp", path(slug)); print("created " + path(slug)); return
    if not a.plan: die("--plan <slug> is required")
    A = a.args
    if a.cmd == "show":
        print(json.dumps(json.load(open(path(a.plan))), ensure_ascii=False, indent=1)); return
    with Locked(a.plan) as p:
        if a.cmd == "add":
            if not A: die('add "<title>"')
            n = max([t.get("n", 0) for t in p.get("tasks", [])] + [0]) + 1
            t = {"n": n, "title": A[0], "agent": a.agent, "status": "todo", "checked": False, "report": "", "next": ""}
            if a.steps: t["steps"] = [{"title": s.strip(), "status": "todo"} for s in a.steps.split("|") if s.strip()]
            touch(t); p.setdefault("tasks", []).append(t); print("task %d added" % n); return
        if not A: die("task number missing")
        try: n = int(A[0])
        except ValueError: die("task number must be a whole number")
        t = task_of(p, n); touch(t)
        if a.cmd == "status":
            if len(A) < 2 or A[1] not in STATUS: die("status <n> " + "|".join(STATUS))
            set_status(t, A[1])
        elif a.cmd == "step":
            if len(A) < 3 or A[2] not in STEP: die('step <n> "<title>" ' + "|".join(STEP))
            steps = t.setdefault("steps", [])
            s = next((x for x in steps if x.get("title") == A[1]), None)
            if s is None: s = {"title": A[1], "status": "todo"}; steps.append(s)
            s["status"] = A[2]
            if A[2] == "running" and t.get("status") in (None, "todo"): set_status(t, "running")
            if A[2] == "failed": t["status"] = "failed"
            if "progress" not in t or t.get("autoProgress"):
                t["progress"] = round(100 * sum(1 for x in steps if x["status"] == "done") / len(steps)); t["autoProgress"] = True
        elif a.cmd == "progress":
            if len(A) < 2: die("progress <n> <0-100>")
            t["progress"] = max(0, min(100, int(float(A[1])))); t.pop("autoProgress", None)
            if t.get("status") in (None, "todo"): set_status(t, "running")
        elif a.cmd == "speed": t["speed"] = A[1] if len(A) > 1 else ""
        elif a.cmd == "waiting": t["waitingFor"] = A[1] if len(A) > 1 else ""
        if a.eta is not None: t["eta"] = iso(time.time() + a.eta)
        if a.eta_at: t["eta"] = a.eta_at
        if a.speed is not None: t["speed"] = a.speed
        if a.waiting is not None: t["waitingFor"] = a.waiting
        for k in ("speed", "waitingFor"):
            if t.get(k) == "": t.pop(k)
        print("ok task %d" % n)

if __name__ == "__main__": main()
