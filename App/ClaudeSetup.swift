// Richtet die Claude-Hooks und die statusLine in ~/.claude/settings.json ein bzw. entfernt sie.
// Nur Foundation, damit tests/ClaudeSetupTest.swift die Logik ohne App prüfen kann.
// Regeln: Sicherungskopie vor jedem Schreiben, fremde Einträge bleiben, nichts doppelt, atomar schreiben.

import Foundation

enum ClaudeSetup {
    struct SetupError: LocalizedError { let errorDescription: String? }

    static let scriptName = "claude-status-hook.py"
    /// $HOME statt festem Pfad: Claude führt den Befehl in einer Shell aus, so passt er für jeden Nutzer.
    static let command = "python3 -I \"$HOME/Library/Application Support/AppVol/\(scriptName)\""
    static let statusLineCommand = command + " statusline"

    /// Ereignis, matcher, async, timeout (s). PermissionRequest wartet auf die Notch, darf also nicht async sein.
    static let events: [(name: String, matcher: String?, async: Bool, timeout: Int)] = [
        ("UserPromptSubmit", nil, true, 5),
        ("PostToolUse", "*", true, 5),
        ("Notification", nil, true, 5),
        ("Stop", nil, true, 5),
        ("SessionEnd", nil, true, 5),
        ("PermissionRequest", "*", false, 70),
    ]

    static var settingsURL: URL {
        ProcessInfo.processInfo.environment["APPVOL_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AppVol/\(scriptName)")
    }

    // ---------- reine Logik ----------

    /// Eigener Eintrag = ruft claude-status-hook.py auf, egal wo es liegt (auch alte, von Hand eingetragene Pfade).
    static func isOurs(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains(scriptName) ?? false
    }

    static func removingHooks(_ s: [String: Any]) -> [String: Any] {
        var s = s
        guard var hooks = s["hooks"] as? [String: Any] else { return s }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept: [Any] = groups.compactMap { g in
                guard var g = g as? [String: Any], let list = g["hooks"] as? [Any] else { return g }
                let rest = list.filter { !isOurs($0) }
                if rest.isEmpty && !list.isEmpty { return nil }  // Gruppe enthielt nur unsere Einträge
                g["hooks"] = rest
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        s["hooks"] = hooks.isEmpty ? nil : hooks
        return s
    }

    static func addingHooks(_ s: [String: Any]) -> [String: Any] {
        var s = removingHooks(s)  // erst alte/eigene Einträge raus, dann genau einmal neu
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        for e in events {
            var entry: [String: Any] = ["type": "command", "command": command, "timeout": e.timeout]
            if e.async { entry["async"] = true }
            var group: [String: Any] = ["hooks": [entry]]
            if let m = e.matcher { group["matcher"] = m }
            hooks[e.name] = (hooks[e.name] as? [Any] ?? []) + [group]
        }
        s["hooks"] = hooks
        return s
    }

    static func hooksInstalled(_ s: [String: Any]) -> Bool {
        let hooks = s["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { e in
            (hooks[e.name] as? [Any] ?? []).contains { (($0 as? [String: Any])?["hooks"] as? [Any] ?? []).contains(where: isOurs) }
        }
    }

    enum StatusLine { case none, ours, foreign }

    static func statusLineState(_ s: [String: Any]) -> StatusLine {
        guard let sl = s["statusLine"] else { return .none }
        return isOurs(sl) ? .ours : .foreign
    }

    static func addingStatusLine(_ s: [String: Any]) throws -> [String: Any] {
        if statusLineState(s) == .foreign {
            throw SetupError(errorDescription: "Du hast schon eine eigene statusLine – AppVol überschreibt sie nicht. Anleitung zum Kombinieren: README.")
        }
        var s = s
        s["statusLine"] = ["type": "command", "command": statusLineCommand]
        return s
    }

    static func removingStatusLine(_ s: [String: Any]) -> [String: Any] {
        var s = s
        if statusLineState(s) == .ours { s["statusLine"] = nil }
        return s
    }

    // ---------- Dateien ----------

    static func read(_ url: URL = settingsURL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }  // keine Datei = leere Einstellungen
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SetupError(errorDescription: "\(url.lastPathComponent) ist kein gültiges JSON – nichts geändert.")
        }
        return s
    }

    /// Sicherungskopie neben der Datei, dann atomar schreiben (Symlinks werden aufgelöst, nicht ersetzt).
    static func write(_ s: [String: Any], to url: URL = settingsURL) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        if fm.fileExists(atPath: target.path) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let backup = target.deletingLastPathComponent().appendingPathComponent("\(target.lastPathComponent).appvol-\(f.string(from: Date())).bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: target, to: backup)
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target, options: .atomic)
    }

    static func update(_ change: ([String: Any]) throws -> [String: Any]) throws {
        let s = try read()
        let new = try change(s)
        if NSDictionary(dictionary: new).isEqual(to: s) { return }  // nichts zu tun, keine Sicherung nötig
        try write(new)
    }

    /// Kopiert das Hook-Skript aus dem App-Bundle nach Application Support.
    static func installScript(from bundle: Bundle = .main) throws {
        guard let src = bundle.url(forResource: "claude-status-hook", withExtension: "py") else {
            throw SetupError(errorDescription: "claude-status-hook.py fehlt im App-Bundle – mit ./build.sh neu bauen.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = scriptURL.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        _ = try fm.replaceItemAt(scriptURL, withItemAt: tmp)
    }

    static func installHooks() throws { try installScript(); try update(addingHooks) }
    static func uninstallHooks() throws { try update(removingHooks) }
    static func installStatusLine() throws { try installScript(); try update(addingStatusLine) }
    static func uninstallStatusLine() throws { try update(removingStatusLine) }

    // ---------- Antworten auf Freigaben ----------

    static func isRequestId(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Schreibt die Antwort der Notch: nur für den Nutzer lesbar (600), an die Anfrage-ID gebunden, atomar.
    static func writeAnswer(dir: URL, id: String, allow: Bool) throws {
        guard isRequestId(id) else { throw SetupError(errorDescription: "ungültige Anfrage-ID") }
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "decision": allow ? "allow" : "deny"])
        let tmp = dir.appendingPathComponent("\(id).answer.tmp"), dst = dir.appendingPathComponent("\(id).answer")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SetupError(errorDescription: "Antwort konnte nicht geschrieben werden")
        }
        guard rename(tmp.path, dst.path) == 0 else { throw SetupError(errorDescription: "Antwort konnte nicht abgelegt werden") }
    }
}
