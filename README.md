# Agent Manager (CEO) (Mantra)

A Mac app (Swift, in the star, group Claude): one window with a table per machine, refreshed every 5 seconds, read-only first.

- **This Mac:** every running Claude Code session (name, folder, busy/idle, last prompt) and its background agents and tasks (from `/private/tmp/claude-*/<project>/<id>/tasks/*.output`: id, running if touched in the last 90 s, age, description from the agent's meta file; transcripts are never read).
- **chromium-vm** (ssh over Tailscale): the `chromium-vm-*` services up or down, Claude Code in tmux, vm-agent :8890, each worker's last log line.
- **Phones** (adb, deduplicated: USB and network are one phone): Pixel 7, emulator; is Claude Code (Termux) running, is the Claude app.
- **Cloud sessions:** what they pushed to the hub's INBOX (no live list exists yet).

`helper/collect.py` does the collecting with timeouts (a dead machine shows UNREACHABLE and never freezes the window). `AgentManager --json` (inside the .app, `Contents/MacOS/`) prints the same overview for other sessions; `python3 helper/collect.py --text` prints short lines.

First row: ON OFF, name, TOP, X (MANTRA_MANIFEST modules/swift-apps.md). Compiled only by GitHub Actions (`.github/workflows/build.yml`); the Mac downloads the release and signs it "Mantra Apps". No secrets here: hostnames only.

**OPEN MANTRA OPERATING SYSTEM** (top, AX id `openos`, v15): runs `mantra-master open` (helper/mantra_master.py): writes the hand-over `~/.mantra-os/master/STATE.md`, then opens a fresh Master session (Session Manager) in a new iTerm window on the MacBook screen, which loads the skill `master-session`, labels itself "Master" and re-arms its monitor. `mantra-master handoff` writes only the state; `whoami`, `monitor`, `cron`, `carry` serve the new master.
