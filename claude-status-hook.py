#!/usr/bin/env python3
"""Claude-Code-Hook für die AppVol-Notch.

Status: Datei pro Sitzung in ~/Library/Application Support/AppVol/claude/<session_id>.json
  state: working | waiting | done
  Aufruf für UserPromptSubmit, PostToolUse, Notification, Stop, SessionEnd (async).
Freigaben: PermissionRequest (nicht async). Nur wenn AppVol läuft und „Freigaben in der Notch“ an ist
  (Datei permissions/.alive ist frisch), legt der Hook eine Anfrage ab und wartet höchstens 60 s
  auf die Antwort aus der Notch. Ohne Antwort gibt er nichts aus – dann fragt Claude wie gewohnt.
Nutzung: mit Argument „statusline“ als statusLine-Befehl; merkt sich rate_limits in usage.json.
Fehler werden verschluckt: der Hook darf Claude nie blockieren.
"""
import json, os, secrets, signal, stat, sys, time
from pathlib import Path

# APPVOL_CLAUDE_DIR: anderer Ordner, z.B. zum Testen
DIR = Path(os.environ.get("APPVOL_CLAUDE_DIR") or Path.home() / "Library/Application Support/AppVol/claude")
PERM = DIR / "permissions"
WAIT = float(os.environ.get("APPVOL_PERMISSION_WAIT", "60"))
ALIVE_MAX_AGE = 15  # AppVol erneuert .alive alle paar Sekunden


def write_atomic(f, data):
    tmp = f.with_name(f.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False))
    os.replace(tmp, f)  # atomar, damit die Notch nie halbe Dateien liest


def app_listening():
    try:
        return time.time() - (PERM / ".alive").stat().st_mtime < ALIVE_MAX_AGE
    except OSError:
        return False


def private_dir_ok():
    """Ordner muss uns gehören und nur für uns les-/schreibbar sein."""
    st = os.lstat(PERM)
    return stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and st.st_mode & 0o077 == 0


def read_answer(f, rid):
    """Antwort nur annehmen, wenn sie eine eigene, private, normale Datei ist und zur Anfrage-ID passt."""
    try:
        st = os.lstat(f)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            return None
        d = json.loads(f.read_text())
    except (OSError, ValueError):
        return None
    if d.get("id") != rid or d.get("decision") not in ("allow", "deny"):
        return None
    return d["decision"]


def summarize(inp):
    if not isinstance(inp, dict):
        return ""
    for k in ("description", "command", "file_path", "path", "url", "pattern", "query", "prompt"):
        if isinstance(inp.get(k), str) and inp[k].strip():
            return " ".join(inp[k].split())[:200]
    return ""


def permission_request(data):
    if not app_listening() or not private_dir_ok():
        return
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))  # bei Abbruch durch Claude trotzdem aufräumen
    rid = secrets.token_hex(16)
    req, ans = PERM / f"{rid}.req.json", PERM / f"{rid}.answer"
    write_atomic(req, {"id": rid, "tool": str(data.get("tool_name", "")), "summary": summarize(data.get("tool_input")),
                       "cwd": data.get("cwd", ""), "session_id": data.get("session_id", ""), "created": time.time()})
    try:
        end = time.time() + WAIT
        decision = None
        while time.time() < end and decision is None:
            time.sleep(0.2)
            decision = read_answer(ans, rid)
            if decision is None and not app_listening():
                return  # AppVol beendet oder Funktion ausgeschaltet
        if decision is None:
            return  # keine Antwort: nichts ausgeben, Claude zeigt den normalen Dialog
        out = {"behavior": decision}  # bewusst ohne updatedPermissions: nur einmal erlauben
        if decision == "deny":
            out["message"] = "In der AppVol-Notch abgelehnt."
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": out}}))
    finally:
        for f in (req, ans):
            f.unlink(missing_ok=True)


def statusline(data):
    rl = data.get("rate_limits")
    keep = {}
    if isinstance(rl, dict):
        keep = {k: {"used_percentage": v.get("used_percentage"), "resets_at": v.get("resets_at")}
                for k, v in rl.items() if k in ("five_hour", "seven_day") and isinstance(v, dict)}
    if keep:
        DIR.mkdir(parents=True, exist_ok=True)
        write_atomic(DIR / "usage.json", {"rate_limits": keep, "updated": time.time()})
    parts = [f"{label} {round(keep[k]['used_percentage'])} %" for k, label in (("five_hour", "5h"), ("seven_day", "7T"))
             if isinstance(keep.get(k, {}).get("used_percentage"), (int, float))]
    print(" · ".join(parts))


def main():
    data = json.load(sys.stdin)
    if sys.argv[1:] == ["statusline"]:
        return statusline(data)
    event = data.get("hook_event_name", "")
    if event == "PermissionRequest":
        return permission_request(data)
    sid = str(data.get("session_id", "")).replace("/", "")
    if not sid:
        return
    f = DIR / f"{sid}.json"
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
    write_atomic(f, cur)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
