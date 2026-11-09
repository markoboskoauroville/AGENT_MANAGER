#!/usr/bin/env python3
"""mantra-master: hand the Master session (Session Manager) of Mantra OS over to a fresh chat, without the pile-up.

Marko, 9.11.2026: "'Open Mantra Operating System' from Agent Manager is exactly that: I open the session ready to
continue, but it's not piling up; it summarizes everything into one skill, and the new chat opens with the skill."

  mantra-master handoff [--plan P]   write ~/.mantra-os/master/STATE.md (<= 150 lines): open tasks, workers, what waits
                                     for Marko, spend week, monitors/crons to re-arm, links
  mantra-master open [--plan P]      handoff, then a NEW iTerm2 window on the MacBook screen (no activate) running
                                     claude --session-id <new uuid> "<master prompt>" in ~/Developer/claude-code,
                                     tab title "<SES name> (Master)", label "Master" written for the new id
                                     (--dry: write the files, compile the AppleScript, open nothing)
  mantra-master whoami               the session id and name this command runs in (walks up to ~/.claude/sessions)
  mantra-master monitor              the Agent Manager command Monitor line for THIS session's slug
  mantra-master cron                 the AUTO-RESUME cron (schedule + prompt) for THIS session's plan
  mantra-master carry [--plan P]     start THIS session's plan with the open tasks of the old one (numbers kept);
                                     the old plan gets "archived": true and "successor"

Skill: ~/.claude/skills/master-session/SKILL.md. Source: repo AGENT_MANAGER helper/mantra_master.py (public, no keys).
"""
import datetime, glob, json, os, re, subprocess, sys, time, uuid

HOME = os.path.expanduser("~")
MOS = HOME + "/.mantra-os"
PLANS = MOS + "/plans"
MASTER = MOS + "/master"
STATE = MASTER + "/STATE.md"
HUB = HOME + "/Developer/claude-code"
LABELS = HOME + "/Developer/AGENT_MANAGER/helper/ceo_labels.py"
OPEN_STATES = ("done",)


def jread(p):
    try:
        return json.load(open(p))
    except Exception:
        return {}


def base(name):
    return re.sub(r"\s*\([^)]*\)\s*$", "", name or "").strip()


def slug(n):
    out, dash = "", False
    for ch in (n or "").lower():
        if ch.isascii() and ch.isalnum():
            out += ch; dash = False
        elif not dash:
            out += "-"; dash = True
    return out.strip("-")


def whoami():
    """(sessionId, name) of the Claude Code session this process runs under, or ('', '')."""
    pid = os.getpid()
    for _ in range(14):
        f = f"{HOME}/.claude/sessions/{pid}.json"
        if os.path.exists(f):
            d = jread(f)
            return d.get("sessionId") or "", d.get("name") or ""
        try:
            pid = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout.strip())
        except Exception:
            break
        if pid <= 1:
            break
    return "", ""


def pick_plan(arg=None):
    if arg:
        return arg if os.path.exists(arg) else f"{PLANS}/{arg}.json"
    sid, name = whoami()
    if name:
        p = f"{PLANS}/{slug(base(name))}.json"
        if os.path.exists(p) and not jread(p).get("archived"):
            return p
    fs = [f for f in glob.glob(PLANS + "/*.json") if not jread(f).get("archived")]
    return max(fs, key=os.path.getmtime) if fs else ""


def short(s, n):
    s = re.sub(r"\s+", " ", str(s or "")).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def worker_of(t):
    return t.get("agent") or t.get("worker") or "-"


def sid_of_session(name):
    for f in glob.glob(f"{HOME}/.claude/sessions/*.json"):
        d = jread(f)
        if base(d.get("name")) == base(name):
            return d.get("sessionId") or ""
    return ""


def live_workers(sid, hours=6):
    """background agents of a session (task links into its transcript), touched in the last <hours>; never reads transcripts"""
    out = []
    if not sid:
        return out
    for d in glob.glob("/private/tmp/claude-*/*/*/tasks"):
        fs = glob.glob(d + "/*.output")
        if not (d.split("/")[-2] == sid or any(os.path.islink(f) and sid in os.readlink(f) for f in fs)):
            continue
        for f in fs:
            if not os.path.islink(f):
                continue
            try:
                age = time.time() - os.stat(f).st_mtime
            except OSError:
                continue
            if age > hours * 3600:
                continue
            m = jread(os.path.realpath(f).replace(".jsonl", ".meta.json"))
            out.append({"id": os.path.basename(f)[:-7], "age": int(age), "desc": m.get("description", ""), "model": m.get("model") or "?"})
    out.sort(key=lambda w: w["age"])
    return out


def ago(s):
    return f"{s}s" if s < 90 else f"{s // 60}m" if s < 5400 else f"{s // 3600}h"


def handover_waiting(n=6):
    try:
        txt = open(HUB + "/HANDOVER.md").read()
    except OSError:
        return []
    m = re.search(r"^## Waiting for Marko\n(.*?)^## ", txt, re.S | re.M)
    items = [l[2:] for l in (m.group(1).splitlines() if m else []) if l.startswith("- ")]
    return [short(i.replace("**", ""), 170) for i in items[:n]]


def spend_week():
    try:
        r = subprocess.run([HOME + "/.local/bin/spend", "week"], capture_output=True, text=True, timeout=15)
        return [l for l in r.stdout.splitlines() if l.strip()][:10]
    except Exception:
        return ["(spend week did not answer)"]


def monitor_cmd(sl):
    return ("D=~/.mantra-os/commands/%s; mkdir -p $D; seen=\"\"; for f in $D/*.json; do [ -e \"$f\" ] && seen=\"$seen $f\"; done; "
            "while true; do for f in $D/*.json; do [ -e \"$f\" ] || continue; case \" $seen \" in *\" $f \"*) continue;; esac; "
            "if grep -Eq '\"state\"[[:space:]]*:[[:space:]]*\"sent\"' \"$f\"; then echo \"COMMAND $(basename $f): $(tr -d '\\n' < \"$f\" | cut -c1-300)\"; "
            "seen=\"$seen $f\"; fi; done; sleep 2; done") % sl


def cron_prompt(plan):
    return ("AUTO-RESUME check (Marko asked: after the usage limit lifts, continue automatically). Read %s. If any task is "
            "running/paused because work stopped at the usage limit, or a worker's report is pending, continue it now "
            "(re-message workers, finish the night shutdown steps when all are idle). If nothing is pending, answer with one "
            "short line and do nothing else." % plan)


def handoff(plan_arg=None):
    plan = pick_plan(plan_arg)
    p = jread(plan) if plan else {}
    tasks = p.get("tasks") or []
    open_t = [t for t in tasks if (t.get("status") or "todo") not in OPEN_STATES]
    old = p.get("session", "")
    old_sid = sid_of_session(old) or whoami()[0]
    workers = live_workers(old_sid)
    now = datetime.datetime.now().astimezone()
    L = [f"# Mantra OS: Master state, {now.day}.{now.month}.{now.year} {now:%H:%M}",
         "",
         f"From the master **{old or '?'}** (session `{old_sid or '?'}`), plan `{plan or 'none'}`.",
         f"Project: {short(p.get('project'), 120)}. Goal: {short(p.get('goal'), 160)}",
         "Read with the skill `master-session` (~/.claude/skills/master-session/SKILL.md). Then: label, monitor, cron, carry, report.",
         "",
         f"## Open tasks ({len(open_t)} of {len(tasks)})",
         "",
         "| n | status | worker | title | next |",
         "|---|---|---|---|---|"]
    order = {"running": 0, "in progress": 0, "blocked": 1, "paused": 1, "failed": 2, "todo": 3}
    for t in sorted(open_t, key=lambda t: (not t.get("focus"), order.get(t.get("status"), 4), t.get("n", 0)))[:30]:
        st = (t.get("status") or "todo") + (" FOCUS" if t.get("focus") else "")
        L.append(f"| {t.get('n')} | {st} | {short(worker_of(t), 22)} | {short(t.get('title'), 70)} | {short(t.get('next'), 80).replace('|', '/')} |")
    done = sorted([t for t in tasks if t.get("status") == "done" and t.get("doneAt")], key=lambda t: t["doneAt"], reverse=True)[:5]
    if done:
        L += ["", "Last done: " + "; ".join(f"{t.get('n')} {short(t.get('title'), 50)}" for t in done)]
    L += ["", "## Background workers of the old master (they do NOT move to the new session)", "",
          "Each line: re-spawn it from its plan task (fresh brief) if the work is unfinished, or `SendMessage` its id while the old session is alive.",
          ""]
    if workers:
        for w in workers[:15]:
            L.append(f"- `{w['id']}` ({w['model']}, last activity {ago(w['age'])} ago): {short(w['desc'], 90)}")
    else:
        L.append("- none seen in the last 6 hours (task links under /private/tmp/claude-*/…/tasks)")
    running = [t for t in open_t if t.get("status") in ("running", "in progress")]
    if running:
        L.append("- plan says running: " + ", ".join(f"{t.get('n')} ({short(worker_of(t), 20)})" for t in running))
    L += ["", "## Waiting for Marko", ""]
    k = 0
    for t in open_t:
        nx = t.get("next") or ""
        if t.get("status") in ("blocked", "paused") or re.search(r"\bMarko\b|WAITING", nx):
            k += 1
            L.append(f"{k}. task {t.get('n')}: {short(nx or t.get('title'), 150)}")
    for h in handover_waiting(6):
        k += 1
        L.append(f"{k}. (HANDOVER) {h}")
    L += ["", "## Money: spend week (gate `spend ask`, skill spend-guard)", "", "```"] + spend_week() + ["```",
          "Known limits: imgtoimg.ai paid credits (1K, output 1, never GPT Image, free VM Gemini test first); Claude Code week usage "
          "in the Agent Manager status bar; GitHub private-repo minutes stopped (spending limit 0)."]
    L += ["", "## Re-arm in the new master", "",
          "1. Label: `python3 ~/Developer/AGENT_MANAGER/helper/ceo_labels.py set <your session id> \"Master\"` (`mantra-master whoami` prints the id).",
          "2. Plan: `mantra-master carry` (your own plan file with these open tasks, numbers kept; the old plan is archived).",
          "3. Monitor (Agent Manager command queue, re-armed every 30 min, timeout_ms 1800000): command = `mantra-master monitor`'s output.",
          "4. Cron AUTO-RESUME: CronCreate cron `47 * * * *`, recurring, prompt = `mantra-master cron`'s output.",
          "5. Then tell Marko in a few lines where everything stands, speak it with `langsay en`, and wait.",
          "", "## Links", "",
          f"- plan `{plan}` · commands `~/.mantra-os/commands/{slug(base(old))}/` · this file `{STATE}`",
          "- rules: MANTRA_MANIFEST modules/claude-code-mantra-os.md, spending.md, close-the-session.md, many-sessions.md; SKILLS.md",
          "- hub: ~/Developer/claude-code/HANDOVER.md · Agent Manager: https://github.com/markoboskoauroville/AGENT_MANAGER",
          ""]
    L = L[:150]
    os.makedirs(MASTER, exist_ok=True)
    tmp = STATE + ".tmp"
    open(tmp, "w").write("\n".join(L) + "\n")
    os.replace(tmp, STATE)
    print(f"handoff: {STATE} ({len(L)} lines, {len(open_t)} open tasks, {len(workers)} workers)")
    return plan


def macbook_bounds():
    """iTerm bounds {l,t,r,b} on the built-in screen (top-left origin), or None"""
    js = ('ObjC.import("AppKit");var s=$.NSScreen.screens,o=[];for(var i=0;i<s.count;i++){var x=s.objectAtIndex(i),f=x.frame;'
          'o.push(x.localizedName.js+"|"+f.origin.x+"|"+f.origin.y+"|"+f.size.width+"|"+f.size.height)};o.join("\\n")')
    try:
        r = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True, timeout=10)
        rows = [l.split("|") for l in r.stdout.strip().splitlines()]
        main_h = float(rows[0][4])
        for name, x, y, w, h in rows:
            if "Built-in" in name:
                x, y, w, h = float(x), float(y), float(w), float(h)
                top = main_h - (y + h)
                return [int(x + 40), int(top + 60), int(x + w - 40), int(top + h - 40)]
    except Exception:
        pass
    return None


def next_ses_name():
    d = datetime.date.today()
    try:
        n = int(open(f"{HOME}/.claude/session-names/MAC_{d.isoformat()}.count").read().strip() or 0) + 1
    except Exception:
        n = 1
    return f"MAC_SES{n}_{d.day:02d}-{d.strftime('%b').upper()}"


def open_master(plan_arg=None, dry=False):
    handoff(plan_arg)
    sid = str(uuid.uuid4())
    prompt = ("You are the Master session (Session Manager) of Mantra OS. Your session id is %s. Load the skill master-session, "
              "read ~/.mantra-os/master/STATE.md, set your label to Master (python3 ~/Developer/AGENT_MANAGER/helper/ceo_labels.py "
              "set %s \"Master\"), re-arm the Agent Manager command Monitor, then tell Marko in a few lines where everything "
              "stands and wait.") % (sid, sid)
    for f in (os.path.dirname(os.path.realpath(__file__)) + "/../master-prompt.txt", os.path.dirname(os.path.realpath(__file__)) + "/master-prompt.txt"):
        if os.path.exists(f) and "{sid}" in open(f).read():   # the one place to change the opening prompt (repo AGENT_MANAGER)
            prompt = open(f).read().strip().replace("{sid}", sid)
            break
    os.makedirs(MASTER, exist_ok=True)
    sfx = ".dry" if dry else ""
    open(MASTER + f"/prompt{sfx}.txt", "w").write(prompt + "\n")
    sh = MASTER + f"/start-master{sfx}.sh"
    open(sh, "w").write("#!/bin/zsh -l\ncd ~/Developer/claude-code\nexec claude --session-id %s \"$(cat %s/prompt%s.txt)\"\n" % (sid, MASTER, sfx))
    os.chmod(sh, 0o755)
    try:   # the label is written before the session starts; its first prompt turns it into "<BASE> (Master)"
        if not dry:
            subprocess.run(["/usr/bin/python3", LABELS, "set", sid, "Master"], capture_output=True, timeout=10)
    except Exception:
        pass
    title = next_ses_name() + " (Master)"
    b = macbook_bounds()
    front = subprocess.run(["osascript", "-l", "JavaScript", "-e",   # NSWorkspace: no Automation prompt for System Events
                            'ObjC.import("AppKit");$.NSWorkspace.sharedWorkspace.frontmostApplication.localizedName.js'],
                           capture_output=True, text=True).stdout.strip()
    keep = front.startswith("iTerm")   # iTerm in front: give its old window the focus back afterwards
    asc = ['tell application "iTerm"']
    if keep:
        asc.append("set oldW to current window")
    asc.append('set w to (create window with default profile command "%s")' % sh)
    if b:
        asc.append("set bounds of w to {%d, %d, %d, %d}" % tuple(b))
    asc.append('tell current session of w to set name to "%s"' % title)
    if keep:
        asc.append("try\nselect oldW\nend try")
    asc.append("end tell")
    if dry:   # compile only: nothing opens, nothing is labelled
        c = subprocess.run(["osacompile", "-o", "/dev/null", "-e", "\n".join(asc)], capture_output=True, text=True)
        print("\n".join(asc)); print("dry: AppleScript " + ("compiles" if c.returncode == 0 else "error: " + c.stderr.strip()))
        return
    r = subprocess.run(["osascript", "-e", "\n".join(asc)], capture_output=True, text=True, timeout=30)
    if r.returncode:
        print("open: iTerm did not open: " + short(r.stderr, 160))
        sys.exit(1)
    open(MASTER + "/last-open.json", "w").write(json.dumps({"sid": sid, "title": title, "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                                                             "screen": "MacBook" if b else "default"}) + "\n")
    print(f"open: master session {title} started in a new iTerm window ({'MacBook screen' if b else 'default screen'}), id {sid}")


def carry(plan_arg=None):
    sid, name = whoami()
    if not name:
        sys.exit("carry: run it inside the new master session (no session name found)")
    new = f"{PLANS}/{slug(base(name))}.json"
    old = pick_plan(plan_arg) if plan_arg else max([f for f in glob.glob(PLANS + "/*.json") if f != new and not jread(f).get("archived")],
                                                    key=os.path.getmtime, default="")
    if not old or old == new:
        sys.exit("carry: no old plan to carry")
    o = jread(old)
    keep = [t for t in (o.get("tasks") or []) if (t.get("status") or "todo") not in OPEN_STATES]
    n = jread(new) or {"project": o.get("project", ""), "session": base(name), "goal": o.get("goal", ""), "tasks": []}
    have = {t.get("n") for t in n.get("tasks", [])}
    n["tasks"] = n.get("tasks", []) + [dict(t, carriedFrom=o.get("session", "")) for t in keep if t.get("n") not in have]
    n["updated"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    for path, d in ((new, n), (old, dict(o, archived=True, successor=base(name), updated=n["updated"]))):
        open(path + ".tmp", "w").write(json.dumps(d, indent=1, ensure_ascii=False))
        os.replace(path + ".tmp", path)
    print(f"carry: {len(keep)} open tasks -> {new}; {old} archived")


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else "help"
    plan = a[a.index("--plan") + 1] if "--plan" in a and a.index("--plan") + 1 < len(a) else None
    if cmd == "handoff":
        handoff(plan)
    elif cmd == "open":
        open_master(plan, dry="--dry" in a)
    elif cmd == "whoami":
        sid, name = whoami()
        print(f"{sid} {name}".strip() or "not inside a Claude Code session")
    elif cmd == "monitor":
        print(monitor_cmd(slug(base(whoami()[1])) or "master"))
    elif cmd == "cron":
        print("cron: 47 * * * *  (recurring)\nprompt: " + cron_prompt(pick_plan(plan) or PLANS + "/<your slug>.json"))
    elif cmd == "carry":
        carry(plan)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
