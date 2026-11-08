#!/usr/bin/env python3
"""ceo_labels.py: the CEO (Agent Manager) owns the "(label)" of every Claude Code session on this Mac.
The BASE name (MAC_SES9_08-NOV) stays as the SessionStart hook gives it. The label is the momentary truth: what the session does
RIGHT NOW, from its plan's focus task and its latest prompts, 1 to 3 words from ONE cheap Haiku call, only when that content changed
and at most every 30 s per session. It is applied through the mechanism the old hook uses: the topic file
~/.claude/session-names/topic/<sid>, which the UserPromptSubmit hook turns into the title at the session's next prompt.
A marker <sid>.ceo there makes session_topic.py stop its own Haiku step for that session.

  ceo_labels.py run                 one pass over every live Mac session (the app starts it detached every tick, one at a time)
  ceo_labels.py set <sid> <text>    a manual label (the RENAME field); stays until `auto`
  ceo_labels.py auto <sid>          back to the CEO's own label
State: ~/.mantra-os/labels/<sid>.json, log: ~/.mantra-os/labels/log.jsonl."""
import glob, hashlib, json, os, re, subprocess, sys, time

HOME = os.path.expanduser("~")
TOPIC = f"{HOME}/.claude/session-names/topic"
LAB = f"{HOME}/.mantra-os/labels"
MODEL = "claude-haiku-5-5"
MIN_GAP = 30


def jread(p):
    try:
        return json.load(open(p))
    except Exception:
        return {}


def log(sid, base, old, new, by):
    os.makedirs(LAB, exist_ok=True)
    with open(LAB + "/log.jsonl", "a") as f:
        f.write(json.dumps({"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "session": base, "sid": sid, "from": old, "to": new, "by": by}) + "\n")


def apply(sid, text):
    os.makedirs(TOPIC, exist_ok=True)
    open(f"{TOPIC}/{sid}", "w").write(text + "\n")
    open(f"{TOPIC}/{sid}.ceo", "w").write("ceo\n")


def sessions():
    p = HOME + "/Developer/claude-code/tools/other_sessions.py"
    try:
        r = subprocess.run(["/usr/bin/python3", p, "json"], capture_output=True, text=True, timeout=10)
        return json.loads(r.stdout)
    except Exception:
        return []


def focus_task(base):
    """the focus (else a running) task of the plan whose session starts with this base name"""
    for f in glob.glob(HOME + "/.mantra-os/plans/*.json"):
        p = jread(f)
        if base and base in (p.get("session") or "") + " " + os.path.basename(f):
            ts = p.get("tasks") or []
            t = next((t for t in ts if t.get("focus")), None) or next((t for t in ts if t.get("status") == "running"), None)
            if t:
                return (p.get("project") or "") + ": " + (t.get("title") or "")
    return ""


def last_prompts(s):
    import importlib.util
    try:
        sp = importlib.util.spec_from_file_location("st", HOME + "/.claude/mantra/session_topic.py")
        m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
        tr = next(iter(glob.glob(f"{HOME}/.claude/projects/*/{s['sid']}.jsonl")), "")
        return m.prompts(tr, 3) if tr else []
    except Exception:
        return [s.get("last") or ""]


def ask_haiku(focus, prompts, cur):
    q = ("What a Claude Code session is doing RIGHT NOW.\n"
         + (f"Plan task in focus: {focus}\n" if focus else "")
         + "Latest requests, oldest first:\n" + "\n".join(f"- {x[:260]}" for x in prompts if x)
         + f"\nCurrent label: {cur or 'none'}.\nAnswer with a label of 1 to 3 words naming the concrete work of this moment "
           "(for example: Santoshi site, CQ mixer, MPA teleprompter). Judge by the newest items, not the history. "
           "If the work is the same, repeat the current label exactly. Only the label, no quotes.")
    cwd = f"{HOME}/.claude/session-names/haiku"
    os.makedirs(cwd, exist_ok=True)
    try:
        r = subprocess.run(["claude", "-p", "--model", MODEL, "--setting-sources", "project", "--no-session-persistence", q],
                           cwd=cwd, capture_output=True, text=True, timeout=60, env=dict(os.environ, MANTRA_TOPIC_CHILD="1"))
    except Exception:
        return ""
    out = (r.stdout.strip().splitlines() or [""])[-1]
    out = re.sub(r"[^\w\-+. ]", "", out).strip()
    return out if out and len(out.split()) <= 3 and len(out) <= 32 else ""


def run():
    os.makedirs(LAB, exist_ok=True)
    lock = LAB + "/.run.lock"
    if os.path.exists(lock) and time.time() - os.path.getmtime(lock) < 120:
        return
    open(lock, "w").write(str(os.getpid()))
    try:
        for s in sessions():
            sid, base = s.get("sid"), s.get("base") or ""
            if not sid or not base:
                continue
            st = jread(f"{LAB}/{sid}.json")
            if st.get("by") == "manual":
                continue
            focus, ps = focus_task(base), last_prompts(s)
            h = hashlib.sha1((focus + "|" + (ps[-1] if ps else "")).encode()).hexdigest()[:12]
            if st.get("hash") == h or time.time() - st.get("ts", 0) < MIN_GAP:
                continue
            new = ask_haiku(focus, ps, st.get("label"))
            st2 = {"label": new or st.get("label"), "hash": h, "ts": time.time(), "by": "ceo", "base": base,
                   "at": time.strftime("%H:%M:%S")}
            if new and new != st.get("label"):
                apply(sid, new)
                log(sid, base, st.get("label"), new, "ceo")
            json.dump(st2, open(f"{LAB}/{sid}.json", "w"))
    finally:
        try:
            os.remove(lock)
        except OSError:
            pass


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["set"] and len(a) >= 3:
        sid, text = a[1], " ".join(a[2:]).strip()[:32]
        st = jread(f"{LAB}/{sid}.json")
        os.makedirs(LAB, exist_ok=True)
        apply(sid, text)
        log(sid, st.get("base", ""), st.get("label"), text, "manual")
        json.dump({"label": text, "hash": "", "ts": time.time(), "by": "manual", "base": st.get("base", ""), "at": time.strftime("%H:%M:%S")}, open(f"{LAB}/{sid}.json", "w"))
    elif a[:1] == ["auto"] and len(a) >= 2:
        st = jread(f"{LAB}/{a[1]}.json")
        st.update({"by": "ceo", "hash": "", "ts": 0})
        os.makedirs(LAB, exist_ok=True)
        json.dump(st, open(f"{LAB}/{a[1]}.json", "w"))
    else:
        run()
