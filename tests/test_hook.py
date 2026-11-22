#!/usr/bin/env python3
"""Selftest für claude-status-hook.py: Freigaben (erlauben/ablehnen/ignorieren) und statusLine.
Aufruf: python3 -I tests/test_hook.py <pfad/zu/claude-status-hook.py>"""
import json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path

HOOK = sys.argv[1]
tmp = Path(tempfile.mkdtemp(prefix="appvol-hook-"))
perm = tmp / "permissions"
env = dict(os.environ, APPVOL_CLAUDE_DIR=str(tmp), APPVOL_PERMISSION_WAIT="1.5")
REQ = json.dumps({"hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/x/projekt",
                  "tool_name": "Bash", "tool_input": {"command": "rm -rf build", "description": "Build löschen"}})


def check(ok, what):
    if not ok:
        print("FEHLER:", what); sys.exit(1)


def run(stdin, *args):
    return subprocess.run([sys.executable, "-I", HOOK, *args], input=stdin, env=env, capture_output=True, text=True, timeout=10).stdout


def answered(content, mode):
    """Startet den Hook, wartet auf die Anfrage, legt eine Antwort ab und liefert seine Ausgabe."""
    p = subprocess.Popen([sys.executable, "-I", HOOK], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
    p.stdin.write(REQ); p.stdin.close()
    for _ in range(50):
        reqs = list(perm.glob("*.req.json"))
        if reqs: break
        time.sleep(0.05)
    check(reqs, "Anfrage wurde abgelegt")
    r = json.loads(reqs[0].read_text())
    check(r["tool"] == "Bash" and r["summary"] == "Build löschen" and len(r["id"]) == 32, "Anfrageinhalt")
    a = perm / f"{r['id']}.answer"
    fd = os.open(a, os.O_WRONLY | os.O_CREAT, mode); os.write(fd, json.dumps(content(r["id"])).encode()); os.close(fd)
    os.chmod(a, mode)
    out = p.stdout.read(); p.wait()
    check(not list(perm.iterdir()) or [f.name for f in perm.iterdir()] == [".alive"], "Anfrage und Antwort aufgeräumt")
    return out


# AppVol hört nicht zu (kein .alive): sofort nichts ausgeben
t = time.time()
check(run(REQ) == "" and time.time() - t < 2, "ohne AppVol keine Wartezeit")

perm.mkdir(mode=0o700); (perm / ".alive").touch()
out = json.loads(answered(lambda i: {"id": i, "decision": "allow"}, 0o600))
check(out["hookSpecificOutput"]["decision"] == {"behavior": "allow"}, "erlauben, ohne dauerhafte Regel")
out = json.loads(answered(lambda i: {"id": i, "decision": "deny"}, 0o600))
check(out["hookSpecificOutput"]["decision"]["behavior"] == "deny", "ablehnen")
check(answered(lambda i: {"id": i, "decision": "allow"}, 0o644) == "", "Antwort mit Rechten 644 ignoriert")
check(answered(lambda i: {"id": "0" * 32, "decision": "allow"}, 0o600) == "", "Antwort mit falscher ID ignoriert")
check(answered(lambda i: {"id": i, "decision": "always"}, 0o600) == "", "unbekannte Entscheidung ignoriert")
os.chmod(perm, 0o755)
check(run(REQ) == "" and not list(perm.glob("*.req.json")), "offener Ordner (755) → keine Anfrage")

# statusLine: rate_limits merken und kurz ausgeben
sl = {"rate_limits": {"five_hour": {"used_percentage": 42.4, "resets_at": 2000000000},
                      "seven_day": {"used_percentage": 12, "resets_at": 2000000000}}}
check(run(json.dumps(sl), "statusline").strip() == "5h 42 % · 7T 12 %", "statusLine-Ausgabe")
u = json.loads((tmp / "usage.json").read_text())
check(u["rate_limits"]["five_hour"]["used_percentage"] == 42.4, "usage.json geschrieben")
check(run("{}", "statusline").strip() == "", "ohne rate_limits leere Zeile")

# Status wie bisher
run(json.dumps({"hook_event_name": "Stop", "session_id": "s1", "cwd": "/x"}))
check(json.loads((tmp / "s1.json").read_text())["state"] == "done", "Status-Hook")
shutil.rmtree(tmp)
print("hook selftest ok")
