# LESSONS

1. (8.11.2026) The tasks folder id under /private/tmp/claude-501/<project>/ is not always the session id (after a resume it differs); agent task files are symlinks into the session's transcript, so a session is matched by the link target.
2. (8.11.2026) The Pixel shows three times in `adb devices` (USB, two network addresses); dedupe by ro.serialno.
3. Never load transcripts: an agent's description is in its `.meta.json`.
4. (8.11.2026, v2) Modes per session come from files, no extra hooks: `~/.cache/mantra-bar/<sessionId>.json` (the status line writes model, RC, context %, 5-hour and week %), `<sessionId>.router.json` (router mode gate/auto/off and the pick), `~/.cache/claude-usage.json` (account usage with reset times), the last 300 KB of the transcript (last main-thread model id, `effort`, the `mode` entry = permission mode; "normal" is shown as default), settings.json (default model, remoteControlAtStartup, router plugin), `~/.claude.json` (MCP server names only), the session file's `bridgeSessionId` (RC bridge).
5. Missing, shown as "unknown": fast mode (no file carries it per session; settings only if `fastMode` is set), the session's live model when the transcript tail has none, anything for Claude Code in Termux on the phones (not running now, and no state file is readable over adb without Termux's run-as), mantra-bar on a phone. A router in mode `off` is shown as BYPASSED (Marko, 5.11.2026: Opus on every prompt).
6. The statusline writes `<sessionId>` files only while that session's status line runs (every 60 s); a stale file means a stale value.
