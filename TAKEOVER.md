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
