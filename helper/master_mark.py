#!/usr/bin/env python3
"""master_mark.py: RETIRED 17.11.2026. Marko: "Please fix the bug which is, first session is always named master.
We don't have any more master session. The first session is named as any other session, please."
No session is ever marked or titled Master; the topic auto-namers treat every session alike.
Kept as a no-op so old callers (mantra_master.py, old hook lines) do not break."""


def mark(d):
    return False


def register(sid, base=""):
    return None


def hook():
    return


if __name__ == "__main__":
    hook()
