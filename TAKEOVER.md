# TAKEOVER

- Source: `app/main.swift` (SwiftUI, one file, `let VERSION = N`), `helper/collect.py` (bundled into Resources by `build.sh`), `icon/AppIcon.icns` (six letters AGE / MGR, from STAR_SWIFT/icons6, key `agentmgr`).
- Bundle id `community.auroville.agentmanager`. Star row `agentmgr` in STAR_SWIFT/rows.json (group Claude).
- Release: push to main, the workflow builds and marks vN Latest. Install: `gh release download --repo markoboskoauroville/AGENT_MANAGER --pattern app.zip`, `ditto -x -k`, to /Applications, `codesign -f -s "Mantra Apps"`.
- Tests: `AgentManager --shot out.png` (sample data, off screen), `--shot-live out.png` (real data), `--json`.
- Next: actions (stop an agent, go to a session via other_sessions.py front), a tiny local HTTP port, a live list of cloud sessions, Termux claude detection once Claude Code runs there.
