# LESSONS

1. (8.11.2026) The tasks folder id under /private/tmp/claude-501/<project>/ is not always the session id (after a resume it differs); agent task files are symlinks into the session's transcript, so a session is matched by the link target.
2. (8.11.2026) The Pixel shows three times in `adb devices` (USB, two network addresses); dedupe by ro.serialno.
3. Never load transcripts: an agent's description is in its `.meta.json`.
