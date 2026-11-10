#!/usr/bin/env python3
"""api_money.py: what Claude Code would cost on the API, and what the $100 API credit has left (estimate).

  python3 api_money.py burn [--days 7]   last N days of Claude Code token use (all ~/.claude/projects/*/*.jsonl,
                                          subagents included), priced at the official per-token API rates
  python3 api_money.py status            writes and prints ~/.cache/claude-api-money.json for the Agent Manager:
                                          credit, spent (ledger of claude-api runs), today, days left at this rate

The real balance is only on platform.claude.com/settings/billing (Promotional credits). The Admin API that could
read cost is "unavailable for individual accounts", so everything here is an ESTIMATE. Prices: USD per MTok from
platform.claude.com/docs/en/about-claude/pricing, read 10.11.2026. No key is read by this file.
"""
import json, glob, os, sys, time, datetime
HOME = os.path.expanduser("~")
# model prefix -> (input, cache write 5m, cache write 1h, cache read, output)  USD / MTok
PRICE = [
    ("claude-fable-5-2", (8, 10, 16, 0.20, 40)), ("claude-fable-5-1", (10, 12.5, 20, 0.25, 50)),
    ("claude-fable-5", (10, 12.5, 20, 1.0, 50)), ("claude-mythos", (8, 10, 16, 0.20, 40)),
    ("claude-opus-5-5", (4, 5, 8, 0.20, 20)), ("claude-opus-5", (5, 6.25, 10, 0.50, 25)),
    ("claude-opus-4", (5, 6.25, 10, 0.50, 25)),
    ("claude-sonnet-5-5", (2, 2.5, 4, 0.10, 10)), ("claude-sonnet-5", (2, 2.5, 4, 0.20, 10)),
    ("claude-sonnet-4", (3, 3.75, 6, 0.30, 15)),
    ("claude-haiku-5-5", (0.10, 0.125, 0.20, 0.01, 0.50)), ("claude-haiku-4", (1, 1.25, 2, 0.10, 5)),
]
CREDIT = 100.0
LEDGER = HOME + "/.cache/claude-api-ledger.jsonl"   # one line per claude-api run: {"ts":..,"cost":..}
OUT = HOME + "/.cache/claude-api-money.json"

def price(model):
    for p, v in PRICE:
        if model.startswith(p): return v
    return None

def burn(days=7):
    since = time.time() - days * 86400
    seen, by = set(), {}
    for f in glob.glob(HOME + "/.claude/projects/**/*.jsonl", recursive=True):
        try:
            if os.path.getmtime(f) < since: continue
            for line in open(f, errors="ignore"):
                if '"usage"' not in line: continue
                try: d = json.loads(line)
                except Exception: continue
                m = d.get("message") or {}
                u, model = m.get("usage"), m.get("model", "")
                if not u or not model or model.startswith("<"): continue
                ts = d.get("timestamp", "")
                try: t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                except Exception: continue
                if t < since: continue
                key = (m.get("id"), d.get("requestId"))   # one API call is written once per content block
                if key in seen: continue
                seen.add(key)
                p = price(model)
                if not p: continue
                cc = u.get("cache_creation") or {}
                w1h = cc.get("ephemeral_1h_input_tokens", 0) or 0
                w5m = cc.get("ephemeral_5m_input_tokens", None)
                if w5m is None: w5m = (u.get("cache_creation_input_tokens", 0) or 0) - w1h
                tok = (u.get("input_tokens", 0) or 0, w5m, w1h, u.get("cache_read_input_tokens", 0) or 0,
                       u.get("output_tokens", 0) or 0)
                usd = sum(a * b for a, b in zip(tok, p)) / 1e6
                fam = model.split("-")[1] if "-" in model else model
                r = by.setdefault(model, {"family": fam, "calls": 0, "usd": 0.0, "tok": [0] * 5})
                r["calls"] += 1; r["usd"] += usd; r["tok"] = [a + b for a, b in zip(r["tok"], tok)]
        except Exception:
            continue
    return by

def ledger():
    rows = []
    try:
        for l in open(LEDGER):
            try: rows.append(json.loads(l))
            except Exception: pass
    except FileNotFoundError: pass
    return rows

def status():
    rows = ledger()
    today = datetime.date.today().isoformat()
    spent = sum(r.get("cost", 0) for r in rows)
    spent_today = sum(r.get("cost", 0) for r in rows if r.get("ts", "").startswith(today))
    first = min((r["ts"] for r in rows if r.get("ts")), default=None)
    d = max(1.0, (time.time() - datetime.datetime.fromisoformat(first).timestamp()) / 86400) if first else None
    rate = spent / d if d else None
    on = os.path.exists(HOME + "/.cache/claude-api-mode.on")
    # what the last 7 days of Claude Code (Max login) would cost on the API: cached 10 min, takes ~3 s
    eq = None
    try:
        old = json.load(open(OUT))
        if time.time() - old.get("eq_at", 0) < 600: eq = (old.get("max_equiv_per_day"), old["eq_at"])
    except Exception: pass
    if eq is None:
        by = burn(7); eq = (round(sum(r["usd"] for r in by.values()) / 7, 2), time.time())
    o = {"estimate": True, "credit": CREDIT, "spent": round(spent, 2), "left": round(CREDIT - spent, 2),
         "today": round(spent_today, 2), "per_day": round(rate, 2) if rate else None,
         "days_left": round((CREDIT - spent) / rate, 1) if rate else None, "runs": len(rows), "mode_on": on,
         "updated": time.strftime("%H:%M:%S"),
         "max_equiv_per_day": eq[0], "eq_at": eq[1],
         "note": "estimate from local run costs; real balance: platform.claude.com/settings/billing"}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(o, open(OUT + ".tmp", "w")); os.replace(OUT + ".tmp", OUT)
    return o

if __name__ == "__main__":
    a = sys.argv[1:] or ["status"]
    if a[0] == "burn":
        days = int(a[2]) if len(a) > 2 and a[1] == "--days" else 7
        by = burn(days); tot = sum(r["usd"] for r in by.values())
        fam = {}
        for m, r in sorted(by.items(), key=lambda x: -x[1]["usd"]):
            fam[r["family"]] = fam.get(r["family"], 0) + r["usd"]
            t = r["tok"]
            print(f"{m:28s} calls {r['calls']:6d}  in {t[0]/1e6:7.2f}M  w5m {t[1]/1e6:7.2f}M  w1h {t[2]/1e6:7.2f}M  "
                  f"read {t[3]/1e6:8.1f}M  out {t[4]/1e6:6.2f}M  = ${r['usd']:8.2f}")
        print("by family:", {k: round(v, 2) for k, v in fam.items()})
        print(f"TOTAL {days} d: ${tot:.2f}   per day ${tot/days:.2f}   $100 lasts {100/(tot/days):.1f} days" if tot else "no usage")
    else:
        print(json.dumps(status()))
