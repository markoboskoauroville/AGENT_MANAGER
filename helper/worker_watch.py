#!/usr/bin/env python3
"""worker_watch.py: heartbeat of a background worker, read locally from its transcript (zero credits, nothing sent anywhere).
Marko, 17.11.2026: every worker reports it is alive and what it is doing. Used by collect.py (id, last_event_age_s, current_action)."""
import json, os, re, sys, time

SECRET = re.compile(r"(sk-ant-[A-Za-z0-9_\-]{8,}|sk-[A-Za-z0-9_\-]{20,}|gsk_[A-Za-z0-9]{8,}|ghp_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{12,}|AIza[0-9A-Za-z_\-]{12,}|xox[bap]-[A-Za-z0-9\-]{8,}|AC[0-9a-f]{32}|[A-Fa-f0-9]{48,}|(?=[A-Za-z_+\-]*\d)(?=[0-9_+\-]*[A-Za-z])[A-Za-z0-9+_\-]{40,}={0,2})")


def mask(s):
    return SECRET.sub("[hidden]", s or "")


def short(p):
    return (p or "?").replace(os.path.expanduser("~"), "~").rsplit("/", 1)[-1]


def tool_words(name, inp):
    inp = inp if isinstance(inp, dict) else {}
    if name in ("Edit", "MultiEdit", "NotebookEdit"): return "editing " + short(inp.get("file_path") or inp.get("notebook_path"))
    if name == "Write": return "writing " + short(inp.get("file_path"))
    if name == "Read": return "reading " + short(inp.get("file_path"))
    if name == "Bash":
        d = (inp.get("description") or "").strip()
        c = " ".join((inp.get("command") or "").split())[:90]
        return "running: " + (c or d)
    if name in ("Grep", "Glob"): return "searching: " + str(inp.get("pattern", ""))[:60]
    if name == "SubagentHandback": return "handing in its report"
    if name in ("WebFetch", "WebSearch"): return "web: " + str(inp.get("url") or inp.get("query") or "")[:60]
    return "using " + str(name)


def last_sentence(t):
    t = " ".join((t or "").split())
    parts = re.split(r"(?<=[.!?])\s+", t)
    return (parts[-1] if parts else t)[:140]


def tail_events(path, nbytes=300000):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2); n = fh.tell(); fh.seek(max(0, n - nbytes))
            raw = fh.read().decode("utf8", "replace").split("\n")
    except OSError:
        return []
    out = []
    for l in raw[1:] if n > nbytes else raw:
        try: out.append(json.loads(l))
        except Exception: pass   # a partial or malformed line is skipped
    return out


def heartbeat(path):
    """{state: running|done, last_event_age_s, current_action} from the tail of the transcript."""
    try: mt = os.stat(path).st_mtime
    except OSError: return None
    action, done = "", False
    for e in reversed(tail_events(path)):
        if e.get("type") != "assistant": continue
        m = e.get("message") or {}
        c = m.get("content")
        if not isinstance(c, list): continue
        tu = [b for b in c if isinstance(b, dict) and b.get("type") == "tool_use"]
        tx = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip()]
        if tu:
            action = tool_words(tu[-1].get("name"), tu[-1].get("input")); done = tu[-1].get("name") == "SubagentHandback"
        elif tx:
            action = last_sentence(tx[-1]); done = m.get("stop_reason") == "end_turn"
        else:
            continue
        break
    return {"state": "done" if done else "running", "last_event_age_s": max(0, int(time.time() - mt)), "current_action": mask(action)}


if __name__ == "__main__":
    print(json.dumps(heartbeat(sys.argv[1])))
