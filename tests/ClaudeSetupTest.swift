// Selftest für ClaudeSetup: Merge mit fremden Hooks und anderen Schlüsseln, Entfernen, statusLine, Antwortdatei.
// Läuft in build.sh: swiftc -parse-as-library App/ClaudeSetup.swift tests/ClaudeSetupTest.swift

import Foundation

@main
enum ClaudeSetupTest {
    static func check(_ ok: Bool, _ what: String) {
        if !ok { print("FEHLER: \(what)"); exit(1) }
    }

    static func json(_ s: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: s, options: .sortedKeys), encoding: .utf8)!
    }

    static func main() throws {
        let foreign: [String: Any] = ["type": "command", "command": "~/bin/fremd.sh"]
        let old: [String: Any] = ["type": "command", "command": "python3 -I \"$HOME/alt/claude-status-hook.py\"", "async": true]
        let sample: [String: Any] = [
            "theme": "dark",
            "enabledPlugins": ["x@y": true],
            "hooks": [
                "Stop": [["hooks": [foreign]]],
                "PostToolUse": [["matcher": "Bash", "hooks": [foreign, old]]],
                "Notification": [["hooks": [old]]],
                "PreToolUse": [["matcher": "Edit", "hooks": [foreign]]],
            ],
        ]

        // Einrichten: fremdes bleibt, alter eigener Eintrag wird ersetzt, alles genau einmal
        let added = ClaudeSetup.addingHooks(sample)
        check(ClaudeSetup.hooksInstalled(added), "nach Einrichten eingerichtet")
        check(!ClaudeSetup.hooksInstalled(sample), "Beispiel gilt nicht als eingerichtet")
        check(json(ClaudeSetup.addingHooks(added)) == json(added), "zweimal Einrichten ändert nichts")
        check(added["theme"] as? String == "dark" && added["enabledPlugins"] != nil, "andere Schlüssel bleiben")
        let h = added["hooks"] as! [String: Any]
        let cmds = { (e: String) in (h[e] as! [[String: Any]]).flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } } }
        check(cmds("Stop") == ["~/bin/fremd.sh", ClaudeSetup.command], "Stop: fremd + eigen")
        check(cmds("PostToolUse") == ["~/bin/fremd.sh", ClaudeSetup.command], "PostToolUse: alter Eintrag ersetzt")
        check(cmds("Notification") == [ClaudeSetup.command], "Notification: nur eigen, kein Duplikat")
        check(cmds("PreToolUse") == ["~/bin/fremd.sh"], "PreToolUse unberührt")
        let post = (h["PostToolUse"] as! [[String: Any]]).last!
        let entry = (post["hooks"] as! [[String: Any]])[0]
        check(post["matcher"] as? String == "*" && entry["async"] as? Bool == true && entry["timeout"] as? Int == 5, "PostToolUse matcher/async/timeout")
        let perm = ((h["PermissionRequest"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        check(perm["async"] == nil, "PermissionRequest nicht async")

        // Entfernen: nur eigene Einträge
        let removed = ClaudeSetup.removingHooks(added)
        let rh = removed["hooks"] as! [String: Any]
        check(Set(rh.keys) == ["Stop", "PostToolUse", "PreToolUse"], "leere Ereignisse entfernt, fremde bleiben")
        check(json(ClaudeSetup.removingHooks(["theme": "x"])) == json(["theme": "x"]), "Entfernen ohne hooks")
        check(ClaudeSetup.removingHooks(ClaudeSetup.addingHooks([:]))["hooks"] == nil, "leeres hooks-Objekt verschwindet")

        // statusLine: eigene setzen/entfernen, fremde nie überschreiben
        let sl = try ClaudeSetup.addingStatusLine(sample)
        check(ClaudeSetup.statusLineState(sl) == .ours, "statusLine gesetzt")
        check(ClaudeSetup.removingStatusLine(sl)["statusLine"] == nil, "statusLine entfernt")
        let mine: [String: Any] = ["statusLine": ["type": "command", "command": "~/sl.sh"]]
        check((try? ClaudeSetup.addingStatusLine(mine)) == nil, "fremde statusLine → Abbruch")
        check(ClaudeSetup.removingStatusLine(mine)["statusLine"] != nil, "fremde statusLine bleibt beim Entfernen")

        // Datei: Sicherung, atomar, ungültiges JSON bleibt unangetastet
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appvol-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try ClaudeSetup.write(sample, to: file)
        try ClaudeSetup.write(added, to: file)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        check(files.contains { $0.hasPrefix("settings.json.appvol-") && $0.hasSuffix(".bak") }, "Sicherungskopie angelegt")
        check(json(try ClaudeSetup.read(file)) == json(added), "zurückgelesen gleich")
        try Data("{kaputt".utf8).write(to: file)
        check((try? ClaudeSetup.read(file)) == nil, "ungültiges JSON → Fehler")

        // Antwortdatei: 600, an ID gebunden
        let id = String(repeating: "ab", count: 16)
        try ClaudeSetup.writeAnswer(dir: dir, id: id, allow: true)
        let ans = dir.appendingPathComponent("\(id).answer")
        let mode = (try FileManager.default.attributesOfItem(atPath: ans.path)[.posixPermissions] as! NSNumber).intValue
        check(mode == 0o600, "Antwort hat Rechte 600 (ist \(String(mode, radix: 8)))")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: ans)) as! [String: String]
        check(d == ["id": id, "decision": "allow"], "Antwortinhalt")
        check((try? ClaudeSetup.writeAnswer(dir: dir, id: "../x", allow: true)) == nil, "ungültige ID abgelehnt")

        print("claude-setup selftest ok")
    }
}
