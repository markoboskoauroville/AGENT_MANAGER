# TAKEOVER

- Source: `app/main.swift` (SwiftUI, one file, `let VERSION = N`), `helper/collect.py` (bundled into Resources by `build.sh`), `icon/AppIcon.icns` (six letters AGE / MGR, from STAR_SWIFT/icons6, key `agentmgr`).
- Bundle id `community.auroville.agentmanager`. Star row `agentmgr` in STAR_SWIFT/rows.json (group Claude).
- Release: push to main, the workflow builds and marks vN Latest. Install: `gh release download --repo markoboskoauroville/AGENT_MANAGER --pattern app.zip`, `ditto -x -k`, to /Applications, `codesign -f -s "Mantra Apps"`.
- Tests: `AgentManager --shot out.png` (sample data, off screen), `--shot-live out.png` (real data), `--json`.
- Next: actions (stop an agent, go to a session via other_sessions.py front), a tiny local HTTP port, a live list of cloud sessions, Termux claude detection once Claude Code runs there.
- v15 (9.11.2026): `helper/mantra_master.py` = the command `mantra-master` (symlink in ~/.local/bin, bundled in Resources). The opening prompt is `master-prompt.txt` with `{sid}`; change it there. Test without opening anything: `mantra-master open --dry`.
- v16 (9.11.2026): blockers column (BlockerColumn/BlockerCard in app/main.swift, AX ids solve-<id>, send-<id>, done-<id>, answer-<id>); window min width 920. Next: the Android list with SOLVE through the phone door (endpoints exist).
- v18 (9.11.2026): three columns RUNNING | main | WHAT STOPPED ME; bottom status bar removed; UsageHeader at the top (SESSION 5 h and WEEK, big figure + thin bar, week orange, model/effort/RC/router line). RUNNING = busy sessions, idle sessions on reachable devices (not cloud), running agents and running plan tasks; gone when they stop. Columns padded 16. Window min width 1180.
- v19 (9.11.2026): RUNNING shows only busy sessions and running agents (no idle sessions, no plan-task rows); an unknown model shows no label.


## From the former README (9.11.2026)

# Agent Manager (CEO) (Mantra)

A Mac app (Swift, in the star, group Claude): one window with a table per machine, refreshed every 5 seconds, read-only first.

- **This Mac:** every running Claude Code session (name, folder, busy/idle, last prompt) and its background agents and tasks (from `/private/tmp/claude-*/<project>/<id>/tasks/*.output`: id, running if touched in the last 90 s, age, description from the agent's meta file; transcripts are never read).
- **chromium-vm** (ssh over Tailscale): the `chromium-vm-*` services up or down, Claude Code in tmux, vm-agent :8890, each worker's last log line.
- **Phones** (adb, deduplicated: USB and network are one phone): Pixel 7, emulator; is Claude Code (Termux) running, is the Claude app.
- **Cloud sessions:** what they pushed to the hub's INBOX (no live list exists yet).

`helper/collect.py` does the collecting with timeouts (a dead machine shows UNREACHABLE and never freezes the window). `AgentManager --json` (inside the .app, `Contents/MacOS/`) prints the same overview for other sessions; `python3 helper/collect.py --text` prints short lines.

First row: ON OFF, name, TOP, X (MANTRA_MANIFEST modules/swift-apps.md). Compiled only by GitHub Actions (`.github/workflows/build.yml`); the Mac downloads the release and signs it "Mantra Apps". No secrets here: hostnames only.

**OPEN MANTRA OPERATING SYSTEM** (top, AX id `openos`, v15): runs `mantra-master open` (helper/mantra_master.py): writes the hand-over `~/.mantra-os/master/STATE.md`, then opens a fresh Master session (Session Manager) in a new iTerm window on the MacBook screen, which loads the skill `master-session`, labels itself "Master" and re-arms its monitor. `mantra-master handoff` writes only the state; `whoami`, `monitor`, `cron`, `carry` serve the new master.

**WHAT STOPPED ME** (column right of the main interface, v16): one orange card per open blocker, newest first, with SOLVE / SEND / DONE. Fed by `mantra-block add|done|list|solve` (helper/mantra_block.py, linked as ~/.local/bin/mantra-block; store ~/.mantra-os/blockers.jsonl) plus a SecurityAgent window and plan tasks with status "blocked". Phone door: `GET /blockers`, `POST /blocker/solve|done`.
- v20 (9.11.2026): every blocker has a --check (explicit or default by kind); `mantra-block check` is started by every `list --all` the dashboard asks for (every 30 s per blocker), closes solved ones ("solved automatically"), restores the plan task, writes an UNBLOCKED message command; state in ~/.mantra-os/blockers-checks.json. Runs only while the app (or any caller of list --all) is alive.
- v21 (9.11.2026): stale cards archive themselves (tidy in mantra_block.py: task done/parked/gone, older than 3 h without check, duplicate per task+kind); archived (n) link in the column; `list --archived`.
- v22 (10.11.2026): phone door live. `server.py` keeps a background collector (overview every ~2 s, plan/command files watched every 0.4 s), `/plans` and the plans inside `/overview` are read fresh from the files, `GET /live?since=N` is a long poll (held up to 20 s, answers the moment anything changes; `ver`, `data_age` in the JSON), `/blockers` comes from the cache. Before: collect.py ~3 s + 4 s cache + 5 s phone poll + a blocker check per poll = 5 to 12 s late, and "served_at" was the time of the request, not of the data. The door still lives only while the Mac app runs (one app owns its engine).
