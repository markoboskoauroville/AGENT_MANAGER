#!/usr/bin/env python3
"""master_mark.py: the first Claude Code session of the day on this Mac is the Master, and it stays Master.
Marko, 10.11.2026: "That first session ran on Mac is always master session and it needs to have in the title master ...
the first session around these day, or session which I just cleared and continued."

Registry: ~/.mantra-os/master/current  = {"sid","pid","date","base","since"}   (`mantra-master whoami` prints it)
Marker  : ~/.claude/session-names/topic/<sid>.master  (+ topic/<sid> = "Master", <sid>.ceo): the topic auto-namers
          (session_topic.py Haiku step, ceo_labels.py run) skip a session with this marker.
Rules (SessionStart hook, source in the hook JSON):
  startup/resume, nobody is master today (current missing or another date)  -> this session becomes Master
  clear/compact, same claude process (pid) as the master                     -> the new sid inherits Master
  same sid as current (resume, button `mantra-master open` wrote it first)    -> stays Master (pid filled in)
  any other session                                                           -> labelled normally; told who the master is
Called as a hook (stdin JSON) it prints one context line; session_name.py imports mark() to put "(Master)" in the title.
Env for tests: MANTRA_HOME (root instead of ~), MANTRA_FAKE_PID."""
import datetime, json, os, subprocess, sys

HOME = os.environ.get("MANTRA_HOME") or os.path.expanduser("~")
CUR = f"{HOME}/.mantra-os/master/current"
TDIR = f"{HOME}/.claude/session-names/topic"
LAB = f"{HOME}/.mantra-os/labels"


def jread(p):
    try:
        return json.load(open(p))
    except Exception:
        return {}


def current():
    return jread(CUR)


def is_master(sid):
    return bool(sid) and os.path.exists(f"{TDIR}/{sid}.master")


def my_session():
    """(pid, session file dict) of the claude process this hook runs under"""
    if os.environ.get("MANTRA_FAKE_PID"):
        pid = int(os.environ["MANTRA_FAKE_PID"])
        return pid, {"kind": "interactive"}
    pid = os.getpid()
    for _ in range(12):
        f = os.path.expanduser(f"~/.claude/sessions/{pid}.json")
        if os.path.exists(f):
            return pid, jread(f)
        try:
            pid = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True, timeout=3).stdout.strip())
        except Exception:
            break
        if pid <= 1:
            break
    return 0, {}


def make(sid, pid, base=""):
    os.makedirs(TDIR, exist_ok=True)
    os.makedirs(os.path.dirname(CUR), exist_ok=True)
    os.makedirs(LAB, exist_ok=True)
    old = current().get("sid")
    if old and old != sid:   # the old id stops being the master (its marker goes, the new id carries it)
        for suf in (".master",):
            try:
                os.remove(f"{TDIR}/{old}{suf}")
            except OSError:
                pass
    open(f"{TDIR}/{sid}", "w").write("Master\n")
    open(f"{TDIR}/{sid}.ceo", "w").write("ceo\n")
    open(f"{TDIR}/{sid}.master", "w").write("master\n")
    json.dump({"label": "Master", "hash": "", "ts": 0, "by": "manual", "base": base, "at": ""}, open(f"{LAB}/{sid}.json", "w"))
    cur = {"sid": sid, "pid": pid, "date": datetime.date.today().isoformat(), "base": base,
           "since": current().get("since") if old == sid else datetime.datetime.now().isoformat(timespec="seconds")}
    open(CUR + ".tmp", "w").write(json.dumps(cur) + "\n")
    os.replace(CUR + ".tmp", CUR)


def register(sid, base=""):
    """for `mantra-master open`: the new session id is the master before it even starts"""
    make(sid, 0, base)


def mark(d):
    """d = SessionStart hook JSON. Returns True when this session is the Master (and records it)."""
    sid, src = d.get("session_id") or "", d.get("source") or "startup"
    if not sid or os.environ.get("MANTRA_TOPIC_CHILD"):
        return False
    pid, sf = my_session()
    cur = current()
    if cur.get("sid") == sid:
        make(sid, pid or cur.get("pid") or 0, cur.get("base", ""))
        return True
    if src in ("clear", "compact") and pid and cur.get("pid") == pid:
        make(sid, pid, cur.get("base", ""))
        return True
    if src in ("startup", "resume") and cur.get("date") != datetime.date.today().isoformat() \
            and sf.get("kind", "interactive") == "interactive" and (pid or os.environ.get("MANTRA_FAKE_PID")):
        make(sid, pid, "")
        return True
    return False


def hook():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    if mark(d):
        print("MASTER: this session is the Master session of this Mac (Mantra OS, skill master-session). Its title label is "
              "(Master) and stays so, also after /clear or /compact; the topic auto-namer skips it.")
    else:
        c = current()
        if c.get("sid") and not os.environ.get("MANTRA_TOPIC_CHILD"):
            print(f"Master session of this Mac: {c.get('base') or '?'} (sid {c['sid']}); this session is a normal one.")


if __name__ == "__main__":
    hook()
