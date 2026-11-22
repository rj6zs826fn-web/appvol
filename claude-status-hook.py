#!/usr/bin/env python3
"""Claude-Code-Hook: schreibt den Status jeder Sitzung für die AppVol-Notch.

Datei pro Sitzung: ~/Library/Application Support/AppVol/claude/<session_id>.json
  state: working | waiting | done
Wird aus ~/.claude/settings.json für UserPromptSubmit, PostToolUse, Notification, Stop, SessionEnd aufgerufen.
Fehler werden verschluckt: ein Status-Hook darf Claude nie blockieren.
"""
import json, os, sys, time
from pathlib import Path

DIR = Path.home() / "Library/Application Support/AppVol/claude"


def main():
    data = json.load(sys.stdin)
    sid = str(data.get("session_id", "")).replace("/", "")
    if not sid:
        return
    f = DIR / f"{sid}.json"
    event = data.get("hook_event_name", "")
    if event == "SessionEnd":
        f.unlink(missing_ok=True)
        return
    try:
        cur = json.loads(f.read_text())
    except (OSError, ValueError):
        cur = {}

    if event == "UserPromptSubmit":
        cur.update(state="working", prompt=" ".join(str(data.get("prompt", "")).split())[:120], message="")
    elif event == "PostToolUse":
        if cur.get("state") == "working" and time.time() - cur.get("updated", 0) < 20:
            return  # nichts Neues – spart Schreibzugriffe bei vielen Werkzeugaufrufen
        cur.update(state="working", message="")
    elif event == "Notification":
        # idle_prompt kommt ~60 s nach Turn-Ende – dann bleibt „fertig“ stehen
        if data.get("notification_type") == "idle_prompt" and cur.get("state") == "done":
            return
        cur.update(state="waiting", message=str(data.get("message", ""))[:160])
    elif event == "Stop":
        cur.update(state="done")
    else:
        return

    cur.update(session_id=sid, cwd=data.get("cwd", cur.get("cwd", "")), updated=time.time())
    DIR.mkdir(parents=True, exist_ok=True)
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps(cur, ensure_ascii=False))
    os.replace(tmp, f)  # atomar, damit die Notch nie halbe Dateien liest


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
